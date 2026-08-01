import SwiftUI
import WebKit

/// A sandboxed web view for agent-produced HTML.
///
/// Previewing generated markup means running its JavaScript inside the app, so
/// the boundaries are set deliberately rather than left at the framework's
/// defaults:
///
/// - **Null origin.** Loaded with `baseURL: nil`, so the page has no origin —
///   no `file://` reach into your machine, no storage, no same-origin anything.
/// - **No external network.** A content rule blocks every request, then
///   re-allows loopback. A page talking to a dev server already running on your
///   machine isn't exfiltration; a page talking to someone else's server is.
/// - **Links leave.** Clicking a link opens your real browser instead of
///   navigating inside the card, so a preview can't quietly become a browser.
/// - **Non-persistent store.** Nothing it sets outlives the view.
///
/// Deliberately built to serve a live URL as well as a string, because a
/// localhost preview is the same component pointed somewhere else.
struct WebPreview: NSViewRepresentable {
    enum Source: Equatable {
        case html(String)
        case url(URL)
    }

    let source: Source
    /// Lets a toolbar drive the view — back, forward, reload — without the
    /// panel needing to know it's a `WKWebView`.
    var controller: WebController?
    /// Inline previews don't scroll — a page that captures the wheel halfway
    /// down a transcript is worse than one you have to expand.
    var scrolls = false
    /// The tallest the card is willing to be. A page taller than this is zoomed
    /// out to fit rather than cropped: a preview that shows the top third of a
    /// dashboard and cuts off mid-card isn't previewing it.
    var fitting: CGFloat?
    /// Reported back so the card can size itself to the content.
    var onHeight: ((CGFloat) -> Void)?

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        controller?.attach(view)
        view.setValue(false, forKey: "drawsBackground")
        view.enclosingScrollView?.hasVerticalScroller = scrolls

        Self.installBlocklist(on: view) { load(view, context: context) }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loaded != source else { return }
        load(view, context: context)
    }

    private func load(_ view: WKWebView, context: Context) {
        context.coordinator.loaded = source
        context.coordinator.controller = controller
        context.coordinator.scrolls = scrolls
        context.coordinator.fitting = fitting
        context.coordinator.onHeight = onHeight
        switch source {
        case .html(let markup):
            view.loadHTMLString(markup, baseURL: nil)
        case .url(let url):
            view.load(URLRequest(url: url))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Block everything, then punch a hole for loopback.
    ///
    /// Ordering matters: `ignore-previous-rules` has to come after the block or
    /// it cancels it, which would silently produce an unrestricted web view
    /// that looked identical from the outside.
    private static func installBlocklist(on view: WKWebView,
                                         then finish: @escaping () -> Void) {
        let rules = """
        [
          {"trigger":{"url-filter":".*"},"action":{"type":"block"}},
          {"trigger":{"url-filter":"^https?://(localhost|127\\\\.0\\\\.0\\\\.1|\\\\[::1\\\\])"},
           "action":{"type":"ignore-previous-rules"}}
        ]
        """
        WKContentRuleListStore.default()?.compileContentRuleList(
            forIdentifier: "honeycode-sandbox", encodedContentRuleList: rules
        ) { list, _ in
            if let list { view.configuration.userContentController.add(list) }
            finish()
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: Source?
        var controller: WebController?
        var scrolls = false
        var fitting: CGFloat?
        var onHeight: ((CGFloat) -> Void)?

        func webView(_ webView: WKWebView,
                     decidePolicyFor action: WKNavigationAction) async
        -> WKNavigationActionPolicy {
            // The initial load is `.other`; anything the user clicked leaves.
            guard action.navigationType == .linkActivated,
                  let url = action.request.url else { return .allow }
            NSWorkspace.shared.open(url)
            return .cancel
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation nav: WKNavigation!) {
            controller?.update(from: webView, loading: true)
        }

        func webView(_ webView: WKWebView, didFail nav: WKNavigation!, withError error: Error) {
            controller?.update(from: webView, loading: false)
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation nav: WKNavigation!, withError error: Error) {
            controller?.update(from: webView, loading: false)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            controller?.update(from: webView, loading: false)
            if !scrolls {
                webView.evaluateJavaScript(
                    "document.documentElement.style.overflow='hidden'")
            }
            // Measured rather than assumed: a 40pt banner in a 320pt card is
            // mostly empty white, and a long page in one is a keyhole.
            webView.evaluateJavaScript("document.body.scrollHeight") { value, _ in
                guard let height = value as? CGFloat, height > 0 else { return }
                guard let fitting = self.fitting, height > fitting else {
                    webView.pageZoom = 1
                    self.onHeight?(height)
                    return
                }
                // Shrink to fit rather than crop. Floored, because past a point
                // the page is legible only in the expanded view anyway and
                // scaling further just makes a grey smudge.
                let zoom = max(fitting / height, 0.35)
                webView.pageZoom = zoom
                self.onHeight?(min(height * zoom, fitting))
            }
        }
    }
}

/// A handle on a live web view, for a toolbar to drive.
@MainActor
final class WebController: ObservableObject {
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    /// Where it actually is, which is not always where you sent it — a
    /// redirect, or a link you followed.
    @Published private(set) var currentURL: URL?

    private weak var view: WKWebView?

    func attach(_ view: WKWebView) { self.view = view }

    func update(from view: WKWebView, loading: Bool) {
        canGoBack = view.canGoBack
        canGoForward = view.canGoForward
        isLoading = loading
        currentURL = view.url
    }

    func back() { view?.goBack() }
    func forward() { view?.goForward() }
    func reload() { view?.reload() }
    func load(_ url: URL) { view?.load(URLRequest(url: url)) }
}
