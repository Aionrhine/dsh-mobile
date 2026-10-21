import SwiftUI
import UIKit
import WebKit

/// Everything needed to draw one ```dsh-ui fence.
struct GenuiRenderPlan {
    /// `dsh-genui` artifact, ready for the standalone runtime.
    let artifactJSON: String
    /// Engine bundles that must be loaded before mounting, e.g. `mermaid`.
    let assets: [String]
}

/// Turns the body of a ```dsh-ui fence into a render plan.
enum GenuiArtifact {
    static let fenceLanguage = "dsh-ui"

    static func matchesFence(_ language: String?) -> Bool {
        language?.trimmingCharacters(in: .whitespaces).lowercased() == fenceLanguage
    }

    /// Returns `nil` when the fence body is not a JSON object, which lets the
    /// message keep rendering as a plain code block instead of an empty box.
    static func plan(fromFence source: String, isDark: Bool) -> GenuiRenderPlan? {
        guard let data = source.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              object is [String: Any]
        else { return nil }

        let locale = Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh" : "en"
        let artifact: [String: Any] = [
            "format": "dsh-genui",
            "version": 1,
            "spec": object,
            "presentation": [
                "locale": locale,
                "theme": isDark ? "dark" : "light",
            ],
        ]
        guard let encoded = try? JSONSerialization.data(withJSONObject: artifact),
              let json = String(data: encoded, encoding: .utf8)
        else { return nil }

        return GenuiRenderPlan(artifactJSON: json, assets: requiredAssets(in: object))
    }

    /// Engine bundles the spec needs. The standalone runtime only reads engines
    /// that were loaded beforehand, so this has to be decided up front.
    private static func requiredAssets(in object: Any) -> [String] {
        var types: Set<String> = []
        var usesRawOption = false
        collectComponentTypes(object, types: &types, usesRawOption: &usesRawOption)

        var assets: [String] = []
        if types.contains("mermaid") { assets.append("mermaid") }
        if types.contains("scene3d") { assets.append("three") }
        // The runtime picks `echarts-core` for the built-in presets and
        // `echarts-full` when a raw `option` is present, and the two bundles
        // register different keys, so both have to be copied whenever any chart
        // component appears. Copying only one leaves the other set of charts
        // failing inside the card.
        if types.contains("echart") || types.contains("chart") || usesRawOption {
            assets.append(contentsOf: ["echarts-core", "echarts-full"])
        }
        return assets
    }

    private static func collectComponentTypes(
        _ value: Any,
        types: inout Set<String>,
        usesRawOption: inout Bool
    ) {
        if let dictionary = value as? [String: Any] {
            if let type = dictionary["type"] as? String {
                types.insert(type.lowercased())
            }
            if dictionary["option"] != nil {
                usesRawOption = true
            }
            for nested in dictionary.values {
                collectComponentTypes(nested, types: &types, usesRawOption: &usesRawOption)
            }
        } else if let array = value as? [Any] {
            for nested in array {
                collectComponentTypes(nested, types: &types, usesRawOption: &usesRawOption)
            }
        }
    }
}

/// One rendered fence: a shell that grows once the web view reports its content
/// height, so the row never clips a long table or chart. When the runtime cannot
/// mount the spec, the fence falls back to its own source instead of a blank box.
///
/// The web view is created on first tap rather than on appear: each fence is a
/// separate WebContent process holding the multi-megabyte runtime, and mounting
/// a conversation's worth of them at once is what gets the app killed.
struct GenuiBlockContainer: View {
    let plan: GenuiRenderPlan
    /// Raw fence body, kept so a failed mount still shows something readable.
    let source: String

    @State private var height: CGFloat = 180
    @State private var failure: String?
    @State private var isMounted = false

    var body: some View {
        Group {
            if let failure {
                failureView(failure)
            } else if isMounted {
                GenuiBlockWebView(plan: plan, height: $height, failure: $failure)
                    .frame(height: max(height, 64))
                    // The runtime reads the presentation theme once, at mount
                    // time, so a theme switch needs a fresh document rather than
                    // a style tweak.
                    .id(plan.artifactJSON)
            } else {
                mountButton
            }
        }
        // A recycled row must not inherit the previous fence's state.
        .onChange(of: plan.artifactJSON) { _, _ in
            failure = nil
            height = 180
            isMounted = false
        }
    }

    private var mountButton: some View {
        Button {
            isMounted = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.grid.2x2")
                VStack(alignment: .leading, spacing: 1) {
                    Text(String(localized: "genui.mount", defaultValue: "点按渲染 GenUI 组件"))
                        .font(.subheadline)
                    Text(String(localized: "genui.mount.hint", defaultValue: "不自动加载，避免一次打开过多占用内存"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func failureView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(String(localized: "genui.failed", defaultValue: "GenUI 渲染失败"))
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(source)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }

            Text(message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Hosts GenUI's standalone bundle in a WKWebView.
///
/// The runtime, theme sheet, page, and engine bundles are copied out of the app
/// bundle once per launch: `loadFileURL(_:allowingReadAccessTo:)` grants read
/// access to a single root, so every file has to live together.
private struct GenuiBlockWebView: UIViewRepresentable {
    let plan: GenuiRenderPlan
    @Binding var height: CGFloat
    @Binding var failure: String?

    func makeCoordinator() -> Coordinator {
        Coordinator(height: $height, failure: $failure, plan: plan)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "genuiHeight")
        configuration.userContentController.add(context.coordinator, name: "genuiFailure")
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.navigationDelegate = context.coordinator
        context.coordinator.loadPage(in: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: "genuiHeight")
        controller.removeScriptMessageHandler(forName: "genuiFailure")
        // Drop the delegate first: `stopLoading()` reports -999 to it, and a
        // recycled row must not inherit a failure from its previous fence.
        webView.navigationDelegate = nil
        webView.stopLoading()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private let height: Binding<CGFloat>
        private let failure: Binding<String?>
        private let plan: GenuiRenderPlan

        init(height: Binding<CGFloat>, failure: Binding<String?>, plan: GenuiRenderPlan) {
            self.height = height
            self.failure = failure
            self.plan = plan
        }

        func loadPage(in webView: WKWebView) {
            guard let directory = GenuiRuntime.prepare(assets: plan.assets),
                  let page = GenuiRuntime.pageURL(in: directory)
            else {
                fail(String(localized: "genui.failed.resources", defaultValue: "渲染资源缺失"))
                return
            }
            webView.loadFileURL(page, allowingReadAccessTo: directory)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Both arguments are valid JSON, therefore valid JavaScript.
            let assets = plan.assets.map { "\"\($0)\"" }.joined(separator: ",")
            let script = "window.__mountGenuiWithAssets(\(plan.artifactJSON), [\(assets)])"
            webView.evaluateJavaScript(script) { _, _ in }
        }

        /// Links inside a card belong to the reader, not to the 180 pt frame:
        /// hand the schemes we can actually service to the system, keep in-page
        /// anchors in place, and never navigate the embedded view elsewhere.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url
            else {
                decisionHandler(.allow)
                return
            }
            if url.isFileURL {
                decisionHandler(.allow)
                return
            }
            let scheme = url.scheme?.lowercased() ?? ""
            if ["http", "https", "mailto", "tel"].contains(scheme) {
                UIApplication.shared.open(url)
            }
            decisionHandler(.cancel)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            // `stopLoading()` and a cancelled redirect both surface as -999; they
            // mean the load was torn down on purpose, not that the fence broke.
            let nsError = error as NSError
            guard nsError.code != NSURLErrorCancelled else { return }
            fail(nsError.localizedDescription)
        }

        /// WebKit kills an embedded process under memory pressure; without this
        /// the card would sit as an empty frame with no explanation.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            fail(String(localized: "genui.failed.process", defaultValue: "渲染进程已被系统回收"))
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            switch message.name {
            case "genuiHeight":
                guard let value = message.body as? NSNumber else { return }
                let reported = CGFloat(truncating: value)
                guard reported.isFinite, reported > 0 else { return }
                DispatchQueue.main.async {
                    guard abs(self.height.wrappedValue - reported) > 0.5 else { return }
                    self.height.wrappedValue = reported
                }
            case "genuiFailure":
                let text = (message.body as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                fail(text.isEmpty ? String(localized: "genui.failed.unknown", defaultValue: "未知错误") : text)
            default:
                break
            }
        }

        private func fail(_ message: String) {
            DispatchQueue.main.async {
                guard self.failure.wrappedValue == nil else { return }
                self.failure.wrappedValue = message
            }
        }
    }
}

/// Copies the GenUI web runtime out of the app bundle into a writable folder.
///
/// Base files are refreshed once per launch; engine bundles are added the first
/// time any fence asks for them, because neighbouring messages routinely need
/// different engines and a single early return would leave the later ones blank.
enum GenuiRuntime {
    /// Serializes every copy, so the launch-time warm-up and a fence's first
    /// mount can never write the same bundle at the same time.
    private static let queue = DispatchQueue(label: "genui.runtime", qos: .utility)
    private static var preparedDirectory: URL?
    private static var copiedFiles: Set<String> = []

    /// Copies every bundle the standalone runtime can ask for, off the main
    /// thread: the engines are several megabytes and must not be read while the
    /// conversation is scrolling.
    static func warmUp() {
        queue.async {
            _ = prepareLocked(assets: ["mermaid", "three", "echarts-core", "echarts-full"])
        }
    }

    static func prepare(assets: [String]) -> URL? {
        queue.sync { prepareLocked(assets: assets) }
    }

    private static func prepareLocked(assets: [String]) -> URL? {
        let fileManager = FileManager.default
        guard let directory = directoryForWrites(fileManager) else { return nil }

        var names: [(String, String)] = [
            ("genui", "html"),
            ("standalone-runtime", "js"),
            ("theme", "css"),
        ]
        names.append(contentsOf: assets.map { ($0, "js") })

        for (name, ext) in names {
            guard let source = Bundle.main.url(forResource: name, withExtension: ext) else { continue }
            let filename = source.lastPathComponent
            let destination = directory.appendingPathComponent(filename)
            if copiedFiles.contains(filename), fileManager.fileExists(atPath: destination.path) {
                continue
            }
            do {
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.copyItem(at: source, to: destination)
                copiedFiles.insert(filename)
            } catch {
                // One missing engine only costs that engine's fence, which the
                // runtime reports through `genuiFailure`.
                continue
            }
        }

        return directory
    }

    private static func directoryForWrites(_ fileManager: FileManager) -> URL? {
        if let preparedDirectory { return preparedDirectory }
        guard let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = caches.appendingPathComponent("GenUI", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        preparedDirectory = directory
        return directory
    }

    static func pageURL(in directory: URL) -> URL? {
        let page = directory.appendingPathComponent("genui.html")
        return FileManager.default.fileExists(atPath: page.path) ? page : nil
    }
}
