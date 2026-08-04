import SwiftUI
import WebKit

/// Animated flux ribbon background extracted from the CORTEX homepage.
///
/// Wraps the bundled `flux.html` in a `WKWebView`. The HTML is a self-contained
/// canvas animation; Swift only has to load it and tell it when to pause or
/// which theme to use.
struct FluxBackground: NSViewRepresentable {

    /// The veil, in points, handed to the page rather than applied over it.
    ///
    /// A SwiftUI `.blur` over this view is a full-window offscreen render pass
    /// per frame, on a surface that is redrawing continuously — the most
    /// expensive possible place to put it. The animation blurs itself instead.
    var blur: CGFloat = 0

    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> WKWebView {
        // The same boundaries the artifact previews get, for an asset that
        // currently needs none of them.
        //
        // `flux.html` is bundled and self-contained — no fetch, no WebSocket,
        // no remote `src` — so there is nothing here to block today. That's
        // exactly why it's worth doing: this is a background surface that runs
        // JavaScript continuously and that nobody would think to re-audit if the
        // asset were ever swapped for one that pulls a shader from a CDN. The
        // rule list allows `file:`, so the animation is unaffected.
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator

        // Loaded whether or not the rules compiled, unlike a preview: this
        // markup ships inside the app, so the blocklist is defence in depth
        // rather than the only thing standing between you and it, and a window
        // with no background is a worse answer than an unfiltered animation.
        WebPreview.installBlocklist(on: view, loopback: .none) { _ in
            guard let url = Bundle.main.url(forResource: "flux", withExtension: "html",
                                            subdirectory: "Flux") else { return }
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        context.coordinator.observe(view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.applyTheme(to: view, colorScheme: colorScheme)
        context.coordinator.applyBlur(to: view, radius: blur)
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
        private weak var view: WKWebView?
        private var observers: [NSObjectProtocol] = []
        /// What was asked for, and what the page has actually been told.
        ///
        /// `updateNSView` runs for reasons that have nothing to do with the
        /// veil, and evaluating JavaScript to restate an unchanged number is a
        /// round trip into the web process for nothing. The pair also covers the
        /// slider being moved before the page has finished loading.
        private var blur: CGFloat = 0
        private var sent: CGFloat = -1

        init(colorScheme: ColorScheme) {
            self.colorScheme = colorScheme
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }

        /// Stop animating when nobody can see it.
        ///
        /// This is a perpetually-running canvas with a live gaussian blur over
        /// it, composited across the whole window — and it kept running while
        /// the app sat in the background, or behind another window, burning GPU
        /// to draw something nobody was looking at. `setFluxPaused` existed and
        /// was only ever called on teardown.
        ///
        /// Occlusion covers the covered-window case; resigning active covers
        /// the visible-but-not-yours case, where the desktop is still showing
        /// the animation but it has stopped being worth a frame budget.
        func observe(_ view: WKWebView) {
            self.view = view
            let centre = NotificationCenter.default
            for name: Notification.Name in [NSApplication.didResignActiveNotification,
                                            NSApplication.didBecomeActiveNotification,
                                            NSWindow.didChangeOcclusionStateNotification] {
                observers.append(centre.addObserver(forName: name, object: nil,
                                                    queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updatePaused() }
                })
            }
        }

        @MainActor
        private func updatePaused() {
            guard let view else { return }
            let visible = view.window?.occlusionState.contains(.visible) ?? false
            let paused = !NSApp.isActive || !visible
            view.evaluateJavaScript(
                "window.setFluxPaused && window.setFluxPaused(\(paused))",
                completionHandler: nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            didLoad = true
            applyTheme(to: webView, colorScheme: colorScheme)
            // The page starts sharp, so whatever was asked for before it loaded
            // has to be restated now that there's something to ask.
            sent = -1
            applyBlur(to: webView, radius: blur)
        }

        func applyBlur(to view: WKWebView, radius: CGFloat) {
            blur = radius
            guard didLoad, abs(radius - sent) > 0.01 else { return }
            sent = radius
            view.evaluateJavaScript(
                "window.setFluxBlur && window.setFluxBlur(\(radius))",
                completionHandler: nil)
        }

        func applyTheme(to view: WKWebView, colorScheme: ColorScheme) {
            self.colorScheme = colorScheme
            guard didLoad else { return }
            let theme = colorScheme == .dark ? "dark" : "light"
            view.evaluateJavaScript("window.setFluxTheme && window.setFluxTheme('\(theme)')", completionHandler: nil)
        }
    }
}
