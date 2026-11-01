import SwiftUI
import UIKit
import WebKit

final class AppModel: ObservableObject {
    @Published var pageURL: URL?
    @Published var startupError: String?

    let bridge = WebBridge()
    private var server: StaticServer?

    init() {
        AgentEngine.shared.bridge = bridge
        AgentEngine.shared.start()
        guard let root = Bundle.main.url(forResource: "ui", withExtension: nil) else {
            startupError = "В сборку не попала папка ui."
            return
        }
        let s = StaticServer(root: root)
        do {
            let port = try s.start()
            server = s
            pageURL = URL(string: "http://127.0.0.1:\(port)/index.html")
        } catch {
            startupError = error.localizedDescription
        }
    }

    deinit {
        server?.stop()
    }
}

struct ContentView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        ZStack {
            Color(red: 0x13 / 255.0, green: 0x10 / 255.0, blue: 0x10 / 255.0)
                .ignoresSafeArea()

            if let url = model.pageURL {
                WebView(url: url, bridge: model.bridge)
                    .ignoresSafeArea()
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 42))
                        .foregroundColor(.orange)
                    Text("OpenCode Mobile")
                        .font(.title2.bold())
                    Text(model.startupError ?? "Не удалось запустить интерфейс")
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 28)
                }
            }
        }
    }
}

struct WebView: UIViewRepresentable {
    let url: URL
    let bridge: WebBridge

    func makeCoordinator() -> Coordinator { Coordinator(initialURL: url) }

    func makeUIView(context: Context) -> WKWebView {
        let conf = WKWebViewConfiguration()
        conf.defaultWebpagePreferences.allowsContentJavaScript = true
        conf.websiteDataStore = .default()
        conf.allowsInlineMediaPlayback = true
        conf.mediaTypesRequiringUserActionForPlayback = []

        let web = WKWebView(frame: .zero, configuration: conf)
        web.uiDelegate = bridge
        web.navigationDelegate = context.coordinator
        web.isOpaque = false
        web.backgroundColor = UIColor(red: 0x13 / 255.0, green: 0x10 / 255.0, blue: 0x10 / 255.0, alpha: 1)
        web.scrollView.backgroundColor = web.backgroundColor
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.keyboardDismissMode = .interactive
        web.allowsBackForwardNavigationGestures = false
        web.allowsLinkPreview = false
        bridge.webView = web
        web.load(URLRequest(url: url))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        if web.url == nil {
            web.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let initialURL: URL
        init(initialURL: URL) { self.initialURL = initialURL }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let target = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            let host = target.host ?? ""
            if host == "127.0.0.1" || host == "localhost" {
                decisionHandler(.allow)
                return
            }
            if target.scheme == "http" || target.scheme == "https" || target.scheme == "tg" {
                UIApplication.shared.open(target, options: [:], completionHandler: nil)
            }
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            // A localhost page can race the listener on very slow devices; retry once.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if webView.url == nil {
                    webView.load(URLRequest(url: self.initialURL))
                }
            }
        }
    }
}