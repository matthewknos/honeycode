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
        /// A file on disk, loaded as itself.
        ///
        /// The one source that gives up the null origin, and deliberately: a
        /// page you can *reload* is the whole point of pointing the panel at a
        /// file, and a string loaded from nowhere has nothing to reload. What
        /// replaces the null origin is a narrower grant — read access to the
        /// file's own folder and nothing above it — plus the same blocklist,
        /// which still stops the page reaching anything but loopback. WebKit
        /// refuses `fetch` between file URLs by default, so "it can see its own
        /// folder" doesn't become "it can read its own folder and phone home".
        case file(URL)
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
    /// Your zoom, on top of whatever the fit worked out.
    ///
    /// Two factors rather than one, multiplied at the last moment. The fit is
    /// the view's opinion about the page and yours is an opinion about the fit —
    /// collapsing them into a single number means the next re-fit silently
    /// discards what you set.
    var zoom: CGFloat = 1
    /// Reported back so the card can size itself to the content.
    var onHeight: ((CGFloat) -> Void)?

    /// This session's dev server port, if it has announced one.
    ///
    /// Set once on the session's subtree rather than passed through seven call
    /// sites, most of which are transcript rows several levels below anything
    /// that knows what a session is.
    @Environment(\.devServerPort) private var devServerPort

    /// Which part of loopback this particular source is trusted with.
    ///
    /// The old grant was all of 127.0.0.1 on every port, justified by "a page
    /// talking to a dev server already running on your machine isn't
    /// exfiltration". That's true of the dev server and not of everything else
    /// listening locally — Ollama, Jupyter (which executes code), Docker's API
    /// if it's on TCP, another project's admin panel. A null-origin page can't
    /// read most cross-origin responses, but it can issue state-changing
    /// requests to services that have no CSRF protection because they assumed
    /// only you could reach them.
    ///
    /// So the grant is narrowed to the thing the rationale actually names. A
    /// URL you navigated to keeps the run of loopback: you chose it, and the
    /// panel exists to browse local servers.
    private var loopback: Loopback {
        switch source {
        case .url:            return .all
        case .html, .file:    return devServerPort.map(Loopback.port) ?? Loopback.none
        }
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        controller?.attach(view)
        view.setValue(false, forKey: "drawsBackground")
        view.enclosingScrollView?.hasVerticalScroller = scrolls

        context.coordinator.loopback = loopback
        Self.installBlocklist(on: view, loopback: loopback) { sandboxed in
            context.coordinator.sandboxed = sandboxed
            guard sandboxed else { return }
            load(view, context: context)
        }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        // The dev server announces itself part-way through a turn, so the
        // policy this view was built under can be out of date by the time it
        // has something to show. Rebuilt in place rather than left stale: the
        // list is swapped and the source re-loaded under it.
        if context.coordinator.loopback != loopback {
            context.coordinator.loopback = loopback
            context.coordinator.loaded = nil
            view.configuration.userContentController.removeAllContentRuleLists()
            Self.installBlocklist(on: view, loopback: loopback) { sandboxed in
                context.coordinator.sandboxed = sandboxed
                guard sandboxed else { return }
                load(view, context: context)
            }
            return
        }
        guard context.coordinator.sandboxed else { return }
        if context.coordinator.zoom != zoom {
            context.coordinator.zoom = zoom
            // Applied without reloading. A reload to change zoom would throw
            // away scroll position, form state and anything you'd clicked,
            // which is a lot to lose for a 10% step.
            view.pageZoom = context.coordinator.fit * zoom
            context.coordinator.reportHeight(of: view)
        }
        guard context.coordinator.loaded != source else { return }
        load(view, context: context)
    }

    private func load(_ view: WKWebView, context: Context) {
        context.coordinator.loaded = source
        context.coordinator.controller = controller
        context.coordinator.scrolls = scrolls
        context.coordinator.fitting = fitting
        context.coordinator.zoom = zoom
        context.coordinator.onHeight = onHeight
        switch source {
        case .html(let markup):
            view.loadHTMLString(markup, baseURL: nil)
        case .url(let url):
            view.load(URLRequest(url: url))
        case .file(let url):
            // The folder, not the file, so a page can find the stylesheet and
            // the images sitting next to it. A file-only grant renders most
            // real pages as unstyled text.
            // Artifacts get the whole of Honeycode's support folder, not just
            // the one they live in.
            //
            // An artifact is written to `Artifacts/`, and the assets it wants
            // are usually somewhere else under the same roof — a logo in a
            // skill's `assets/` folder, most obviously. With the grant scoped
            // to the document's own directory WebKit denied every one of them,
            // and a deck that was correct in every other respect rendered with
            // a broken-image square where the logo went.
            //
            // The boundary is Honeycode's folder, not the home directory, and
            // the reasoning for stopping there is worth stating: the *page*
            // gains nothing its author didn't have. The agent that wrote it
            // runs with permissions skipped and could already read any of
            // this. The thing that actually matters — that agent-written
            // markup can't phone home — is the block list, which this doesn't
            // touch, and `allowFileAccessFromFileURLs` stays off, so scripts
            // can't read other files either. Sub-resources, and that's all.
            view.loadFileURL(url, allowingReadAccessTo: readScope(for: url))
        }
    }

    /// How much of the disk a file preview may read.
    ///
    /// Honeycode's support folder for anything inside it; otherwise the
    /// document's own directory, unchanged — a file you opened from your own
    /// checkout gets its siblings and nothing more, which is what a preview of
    /// someone else's page should have.
    private func readScope(for url: URL) -> URL {
        let root = Support.folder.standardizedFileURL
        let file = url.standardizedFileURL
        // Compared as path components, not as a string prefix: `/…/Honeycode`
        // is a string prefix of `/…/Honeycode Backups`, and read access is not
        // a thing to get wrong by one character.
        let inside = zip(root.pathComponents, file.pathComponents).allSatisfy(==)
            && file.pathComponents.count > root.pathComponents.count
        return inside ? root : url.deletingLastPathComponent()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Block everything, then punch a hole for loopback.
    ///
    /// Ordering matters: `ignore-previous-rules` has to come after the block or
    /// it cancels it, which would silently produce an unrestricted web view
    /// that looked identical from the outside.
    ///
    /// One rule per host, because WebKit's content-blocker regex engine is not
    /// the regex you know: it rejects disjunction outright — `(a|b)` is
    /// "Disjunctions are not supported yet" — and a single unparseable rule
    /// fails the *whole* list, leaving `compileContentRuleList` to hand back
    /// nil. Which is precisely the silent unrestricted web view the paragraph
    /// above is about, and which is what this actually did until it was
    /// compiled in a test and the error read.
    ///
    /// Each host anchor has to run to the `/` that ends the authority, and
    /// nothing shorter.
    ///
    /// `^https?://localhost` alone also matches `localhost.evil.example`, which
    /// is why there was a terminator at all. But `[:/]` is not a strong enough
    /// one, and this was demonstrated rather than argued: with a rule list of
    /// block-everything plus `^https?://localhost[:/]`, a page loaded at a null
    /// origin fetched `http://localhost:80@127.0.0.1:8931/` and the request
    /// arrived. `localhost` is the *username* there, `80` the password, and the
    /// real host is whatever follows the `@` — so the rule fired
    /// `ignore-previous-rules` for a request to an arbitrary external server.
    /// An `<img>` and an `<iframe>` both did it; `LOCALHOST:80@` did it too,
    /// since url-filter is case-insensitive. (`fetch()` can't be used to test
    /// this — it rejects a URL carrying credentials before making a request —
    /// which is probably why it went unnoticed.)
    ///
    /// Requiring the `/` closes it: after `localhost` the next character must be
    /// `/`, or `:` then digits then `/`. Userinfo puts an `@` where the `/` has
    /// to be, so it can't match. Two rules per host rather than one optional
    /// group, because WebKit's content-blocker engine is not the regex you know
    /// — it rejects disjunction outright (`(a|b)` is "Disjunctions are not
    /// supported yet"), and one unparseable rule fails the *whole* list, leaving
    /// `compileContentRuleList` to hand back nil.
    ///
    /// The trailing `/` is safe to require because rules match the canonical
    /// URL, and canonicalisation gives a bare authority an empty path.
    private static let loopbackHosts = ["localhost", "127\\\\.0\\\\.0\\\\.1", "\\\\[::1\\\\]"]

    /// How much of loopback a preview may reach. See `Loopback` for why this
    /// isn't simply "all of it".
    enum Loopback: Equatable {
        /// Everything on 127.0.0.1, for a page you navigated to yourself.
        case all
        /// One port — this session's dev server.
        case port(Int)
        /// Nothing. Agent-written markup with no dev server to talk to has no
        /// business on loopback at all.
        case none

        var identifier: String {
            switch self {
            case .all:            return "all"
            case .port(let port): return "port-\(port)"
            case .none:           return "none"
            }
        }
    }

    static func installBlocklist(on view: WKWebView, loopback: Loopback,
                                 then finish: @escaping (_ sandboxed: Bool) -> Void) {
        var allow: [String] = []
        switch loopback {
        case .all:
            for host in loopbackHosts {
                allow.append("^https?://\(host)/")
                allow.append("^https?://\(host):[0-9]+/")
            }
        case .port(let port):
            for host in loopbackHosts {
                allow.append("^https?://\(host):\(port)/")
                // Port 80 is elided from a canonical http URL, so without this
                // a dev server on 80 would be blocked by its own allowance.
                if port == 80 { allow.append("^https?://\(host)/") }
            }
        case .none:
            break
        }
        // `file:` is re-allowed as well as loopback. The block rule matches
        // every URL including the document itself, so without this a page
        // loaded from disk is blocked before it renders — and the grant is
        // already bounded by `allowingReadAccessTo`, which the rule list can't
        // widen.
        allow.append("^file://")

        // Ordering matters: `ignore-previous-rules` has to come after the block
        // or it cancels it, which would silently produce an unrestricted web
        // view that looked identical from the outside.
        let rules = "[\n"
            + ([#"{"trigger":{"url-filter":".*"},"action":{"type":"block"}}"#]
               + allow.map {
                   #"{"trigger":{"url-filter":"\#($0)"},"action":{"type":"ignore-previous-rules"}}"#
               }).joined(separator: ",\n")
            + "\n]"

        WKContentRuleListStore.default()?.compileContentRuleList(
            forIdentifier: "honeycode-sandbox-2-\(loopback.identifier)",
            encodedContentRuleList: rules
        ) { list, error in
            guard let list else {
                // Fail closed, and closed means *nothing loads*.
                //
                // Disabling JavaScript was the previous answer and it does take
                // effect — `webView.configuration` hands back a copy, but the
                // copy shares the same `WKWebpagePreferences` object, so the
                // flag reaches the live view (checked, not assumed: a page
                // whose only script fired a beacon didn't fire it). It just
                // isn't sufficient. A page with no script at all can still
                // carry `<img src="https://…/?stolen">`, and the markup was
                // written by the agent that has already read your files — so
                // "no JavaScript" leaves the exfiltration path it was meant to
                // close. Without a rule list there is no safe way to show
                // agent-written markup, so it isn't shown.
                view.configuration.defaultWebpagePreferences.allowsContentJavaScript = false
                NSLog("Honeycode: preview sandbox rules failed to compile (%@); "
                      + "this preview will not load.",
                      error?.localizedDescription ?? "no reason given")
                finish(false)
                return
            }
            view.configuration.userContentController.add(list)
            finish(true)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        /// Whether the rule list actually installed. Nothing loads until it has.
        var sandboxed = false
        var loopback: Loopback = .none
        var loaded: Source?
        var controller: WebController?
        var scrolls = false
        var fitting: CGFloat?
        var zoom: CGFloat = 1
        /// What the fit-to-height pass decided, kept so a zoom change can be
        /// applied against it without re-measuring the page.
        var fit: CGFloat = 1
        var onHeight: ((CGFloat) -> Void)?

        func webView(_ webView: WKWebView,
                     decidePolicyFor action: WKNavigationAction) async
        -> WKNavigationActionPolicy {
            // The initial load is `.other`; anything the user clicked leaves.
            guard action.navigationType == .linkActivated,
                  let url = action.request.url else { return .allow }
            // Only the web schemes leave. Handing an arbitrary URL to
            // `NSWorkspace` means handing it to Launch Services, and the markup
            // around the link was written by the agent: `<a
            // href="file:///…/results.command">Click for results</a>` reads as
            // a link and behaves as a double-click on an executable. Cancelled
            // rather than opened, and cancelled rather than navigated — a
            // preview that follows a link stops being a preview.
            guard let scheme = url.scheme?.lowercased(),
                  ["http", "https", "mailto"].contains(scheme) else { return .cancel }
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
            reportHeight(of: webView)
        }

        /// Measure the page, decide the fit, apply both factors.
        ///
        /// Measured rather than assumed: a 40pt banner in a 320pt card is mostly
        /// empty white, and a long page in one is a keyhole.
        func reportHeight(of webView: WKWebView) {
            webView.evaluateJavaScript("document.body.scrollHeight") { value, _ in
                // The *unzoomed* height. `scrollHeight` is reported in CSS
                // pixels, which `pageZoom` doesn't change, so this stays stable
                // across zoom steps and the fit doesn't drift each time.
                guard let height = value as? CGFloat, height > 0 else { return }
                guard let fitting = self.fitting, height > fitting else {
                    self.fit = 1
                    webView.pageZoom = self.zoom
                    self.onHeight?(height * self.zoom)
                    return
                }
                // Shrink to fit rather than crop. Floored, because past a point
                // the page is legible only in the expanded view anyway and
                // scaling further just makes a grey smudge.
                let fit = max(fitting / height, 0.35)
                self.fit = fit
                webView.pageZoom = fit * self.zoom
                self.onHeight?(min(height * fit * self.zoom, fitting))
            }
        }
    }
}

/// Zoom steps, and the control that walks them.
///
/// A fixed ladder rather than a free multiplier. Every browser on the platform
/// does it this way for the same reason: a zoom you can land on 103% is a zoom
/// you can't get back off, and the steps are what make ⌘+ and ⌘− feel like they
/// have detents rather than acceleration.
enum Zoom {
    static let steps: [CGFloat] = [0.5, 0.67, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2]
    static let normal: CGFloat = 1

    /// Compared with a tolerance, because these are floating point and the
    /// stored value has been through `@Published` and a `Double` round trip.
    static func stepIn(_ current: CGFloat) -> CGFloat {
        steps.first { $0 > current + 0.001 } ?? steps.last ?? normal
    }

    static func stepOut(_ current: CGFloat) -> CGFloat {
        steps.last { $0 < current - 0.001 } ?? steps.first ?? normal
    }

    static func label(_ value: CGFloat) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

/// Zoom out, the readout, zoom in — plus the keys.
///
/// The readout only appears once you've left 100%, and pressing it goes back.
/// A permanent "100%" in a toolbar is a label that spends almost all of its life
/// telling you nothing, and the reset it offers is only meaningful in the state
/// where the label has something to say.
struct ZoomControl: View {
    @Binding var zoom: CGFloat
    /// Whether to claim ⌘+ / ⌘− / ⌘0. Only the frontmost surface should.
    var shortcuts = true

    private var atFloor: Bool { zoom <= (Zoom.steps.first ?? 1) + 0.001 }
    private var atCeiling: Bool { zoom >= (Zoom.steps.last ?? 1) - 0.001 }

    var body: some View {
        HStack(spacing: Theme.s1) {
            button("minus.magnifyingglass", "Zoom out", enabled: !atFloor) {
                zoom = Zoom.stepOut(zoom)
            }
            if abs(zoom - Zoom.normal) > 0.001 {
                Button { zoom = Zoom.normal } label: {
                    Text(Zoom.label(zoom))
                        .font(.system(size: 10.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Theme.s3)
                        .padding(.vertical, 1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(HoverCapsule())
                .help("Reset to 100%")
                .transition(.opacity)
            }
            button("plus.magnifyingglass", "Zoom in", enabled: !atCeiling) {
                zoom = Zoom.stepIn(zoom)
            }
        }
        .animation(Motion.reveal, value: zoom)
        .background {
            if shortcuts {
                // Zero-sized buttons carrying the key equivalents. SwiftUI has
                // no way to attach a shortcut to a view that isn't a control,
                // and the alternative — a local event monitor — would swallow
                // ⌘+ from every text field in the window.
                //
                // Both "=" and "+" are bound: ⌘+ requires shift on a UK and a US
                // layout alike, so binding only the shifted form means the key
                // most people press does nothing.
                Group {
                    key("=") { zoom = Zoom.stepIn(zoom) }
                    key("+") { zoom = Zoom.stepIn(zoom) }
                    key("-") { zoom = Zoom.stepOut(zoom) }
                    key("0") { zoom = Zoom.normal }
                }
                .hidden()
            }
        }
    }

    private func key(_ character: KeyEquivalent, action: @escaping () -> Void) -> some View {
        Button("", action: action)
            .keyboardShortcut(character, modifiers: .command)
            .frame(width: 0, height: 0)
    }

    private func button(_ symbol: String, _ label: String,
                        enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(enabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverCapsule())
        .disabled(!enabled)
        .help(label)
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
