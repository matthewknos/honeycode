import SwiftUI
import WebKit

/// Animated flux ribbon background extracted from the CORTEX homepage.
///
/// Wraps the bundled `flux.html` in a `WKWebView`. The HTML is a self-contained
/// canvas animation; Swift only has to load it and tell it when to pause or
/// which theme to use.
struct FluxBackground: NSViewRepresentable {

    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.navigationDelegate = context.coordinator

        // Load once; the coordinator applies the theme once loading finishes.
        if let url = Bundle.main.url(forResource: "flux", withExtension: "html", subdirectory: "Flux") {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.applyTheme(to: view, colorScheme: colorScheme)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(colorScheme: colorScheme)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.evaluateJavaScript("window.setFluxPaused && window.setFluxPaused(true)", completionHandler: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private var colorScheme: ColorScheme
        private var didLoad = false

        init(colorScheme: ColorScheme) {
            self.colorScheme = colorScheme
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            didLoad = true
            applyTheme(to: webView, colorScheme: colorScheme)
        }

        func applyTheme(to view: WKWebView, colorScheme: ColorScheme) {
            self.colorScheme = colorScheme
            guard didLoad else { return }
            let theme = colorScheme == .dark ? "dark" : "light"
            view.evaluateJavaScript("window.setFluxTheme && window.setFluxTheme('\(theme)')", completionHandler: nil)
        }
    }
}
