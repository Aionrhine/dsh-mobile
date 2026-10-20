import SwiftUI
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
        if types.contains("echart") || usesRawOption { assets.append("echarts-full") }
        if types.contains("chart") { assets.append("echarts-core") }
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
/// height, so the row never clips a long table or chart.
struct GenuiBlockContainer: View {
    let plan: GenuiRenderPlan

    @State private var height: CGFloat = 180

    var body: some View {
        GenuiBlockWebView(plan: plan, height: $height)
            .frame(height: max(height, 64))
            // The runtime reads the presentation theme once, at mount time, so a
            // theme switch needs a fresh document rather than a style tweak.
            .id(plan.artifactJSON)
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

    func makeCoordinator() -> Coordinator {
        Coordinator(height: $height, plan: plan)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "genuiHeight")
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
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "genuiHeight")
        webView.stopLoading()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private let height: Binding<CGFloat>
        private let plan: GenuiRenderPlan

        init(height: Binding<CGFloat>, plan: GenuiRenderPlan) {
            self.height = height
            self.plan = plan
        }

        func loadPage(in webView: WKWebView) {
            guard let directory = GenuiRuntime.prepare(assets: plan.assets),
                  let page = GenuiRuntime.pageURL(in: directory)
            else { return }
            webView.loadFileURL(page, allowingReadAccessTo: directory)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Both arguments are valid JSON, therefore valid JavaScript.
            let assets = plan.assets.map { "\"\($0)\"" }.joined(separator: ",")
            let script = "window.__mountGenuiWithAssets(\(plan.artifactJSON), [\(assets)])"
            webView.evaluateJavaScript(script) { _, _ in }
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "genuiHeight", let value = message.body as? NSNumber else { return }
            let reported = CGFloat(truncating: value)
            guard reported.isFinite, reported > 0 else { return }
            DispatchQueue.main.async {
                guard abs(self.height.wrappedValue - reported) > 0.5 else { return }
                self.height.wrappedValue = reported
            }
        }
    }
}

/// Copies the GenUI web runtime out of the app bundle into a writable folder.
private enum GenuiRuntime {
    private static var preparedDirectory: URL?

    static func prepare(assets: [String]) -> URL? {
        if let preparedDirectory { return preparedDirectory }

        let fileManager = FileManager.default
        guard let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = caches.appendingPathComponent("GenUI", isDirectory: true)

        var names: [(String, String)] = [
            ("genui", "html"),
            ("standalone-runtime", "js"),
            ("theme", "css"),
        ]
        names.append(contentsOf: assets.map { ($0, "js") })

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            for (name, ext) in names {
                guard let source = Bundle.main.url(forResource: name, withExtension: ext) else { continue }
                let destination = directory.appendingPathComponent(source.lastPathComponent)
                // Always overwrite: a new build must not keep serving last
                // version's runtime.
                try? fileManager.removeItem(at: destination)
                try fileManager.copyItem(at: source, to: destination)
            }
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
