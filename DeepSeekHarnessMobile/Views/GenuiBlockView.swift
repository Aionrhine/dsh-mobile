import SwiftUI
import WebKit

/// Builds the `dsh-genui` artifact that GenUI's standalone runtime mounts, from
/// the body of one ```dsh-ui fence.
enum GenuiArtifact {
    static let fenceLanguage = "dsh-ui"

    static func matchesFence(_ language: String?) -> Bool {
        language?.trimmingCharacters(in: .whitespaces).lowercased() == fenceLanguage
    }

    /// Returns `nil` when the fence body is not a JSON object, which lets the
    /// message keep rendering as a plain code block instead of an empty box.
    static func json(fromFence source: String, isDark: Bool) -> String? {
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
        guard let encoded = try? JSONSerialization.data(withJSONObject: artifact) else { return nil }
        return String(data: encoded, encoding: .utf8)
    }
}

/// One rendered fence: a shell that grows once the web view reports its content
/// height, so the row never clips a long table or chart.
struct GenuiBlockContainer: View {
    let artifactJSON: String

    @State private var height: CGFloat = 180

    var body: some View {
        GenuiBlockWebView(artifactJSON: artifactJSON, height: $height)
            .frame(height: max(height, 64))
            // The runtime reads the presentation theme once, at mount time, so a
            // theme switch needs a fresh document rather than a style tweak.
            .id(artifactJSON)
    }
}

/// Hosts GenUI's standalone bundle in a WKWebView.
///
/// The runtime, theme sheet, and page are copied out of the app bundle once per
/// launch: `loadFileURL(_:allowingReadAccessTo:)` grants read access to a single
/// root, so all four files have to live together.
private struct GenuiBlockWebView: UIViewRepresentable {
    let artifactJSON: String
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(height: $height, artifactJSON: artifactJSON)
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
        private let artifactJSON: String

        init(height: Binding<CGFloat>, artifactJSON: String) {
            self.height = height
            self.artifactJSON = artifactJSON
        }

        func loadPage(in webView: WKWebView) {
            guard let directory = GenuiRuntime.prepare(),
                  let page = GenuiRuntime.pageURL(in: directory)
            else { return }
            webView.loadFileURL(page, allowingReadAccessTo: directory)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // The artifact is valid JSON, therefore valid JavaScript.
            webView.evaluateJavaScript("window.__mountGenui(\(artifactJSON))") { _, _ in }
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

    static func prepare() -> URL? {
        if let preparedDirectory { return preparedDirectory }

        let fileManager = FileManager.default
        guard let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = caches.appendingPathComponent("GenUI", isDirectory: true)

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            for (name, ext) in [("genui", "html"), ("standalone-runtime", "js"), ("theme", "css")] {
                guard let source = Bundle.main.url(forResource: name, withExtension: ext) else { return nil }
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
