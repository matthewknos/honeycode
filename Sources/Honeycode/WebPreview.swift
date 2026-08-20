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
            // The one refusal nothing reports.
            //
            // A blocked sub-resource announces itself and a blocked *document*
            // does not: WebKit cancels the navigation before the delegate is
            // consulted, so there is no policy callback, no notification and no
            // failure — an external address typed into the panel simply leaves
            // the previous page sitting there. Measured rather than assumed: a
            // second navigation to an allowed URL reaches `decidePolicyFor`,
            // one to a blocked host never does.
            //
            // The grant is right here and the check is a string comparison, so
            // the answer is worked out up front instead. A tick later, because
            // this runs inside `updateNSView` and publishing from within a view
            // update is a bug of its own.
            if let scheme = url.scheme?.lowercased(),
               scheme == "http" || scheme == "https", !loopback.permits(url) {
                let controller = controller
                DispatchQueue.main.async {
                    controller?.clearBlocked()
                    controller?.noteBlocked(url)
                }
            }
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

        /// Whether this URL was inside the grant.
        ///
        /// A second opinion, and only ever used to *suppress* a report — the
        /// rule engine decides what loads and this decides what the toolbar is
        /// allowed to complain about. Written out rather than inferred from the
        /// regexes above because the two answer different questions: those have
        /// to be exact about what gets through, this only has to be sure before
        /// telling you something was refused.
        func permits(_ url: URL) -> Bool {
            if url.scheme?.lowercased() == "file" { return true }
            guard let host = url.host?.lowercased(),
                  ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) else { return false }
            switch self {
            case .all:
                return true
            case .port(let port):
                // The port a canonical URL doesn't carry is the scheme's own,
                // which is the case a dev server on 80 actually hits.
                return (url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)) == port
            case .none:
                return false
            }
        }
    }

    /// The one thing the rule list says out loud, and why it says anything.
    ///
    /// A blocked sub-resource is silent. `WKNavigationDelegate` reports
    /// navigations, and a stylesheet or a module import that never left isn't
    /// one — so what you get is a page that paints its background colour and
    /// stops. No error, no console, nothing in the toolbar. The only way to
    /// find out why was to read this file.
    ///
    /// That is not a hypothetical: the same project hit it twice in an hour.
    /// An agent wrote a page against a CDN, the panel went black, and a sandbox
    /// working exactly as designed was indistinguishable from a dead server. So
    /// the list carries a `notify` action beside the block, and the panel
    /// counts what it hears.
    ///
    /// This loosens nothing. `notify` doesn't allow a request; it reports one
    /// that was refused, after it was refused.
    static let notification = "honeycode-blocked"

    static func installBlocklist(on view: WKWebView, loopback: Loopback,
                                 then finish: @escaping (_ sandboxed: Bool) -> Void) {
        compile(loopback, announcing: true) { list, _ in
            if let list {
                view.configuration.userContentController.add(list)
                finish(true)
                return
            }
            // The counter is a convenience and the block is a boundary, and
            // they are not allowed to fail together. If `notify` is ever
            // rejected — a WebKit that doesn't know it, a syntax that moves —
            // the same list without it is compiled instead, so the preview
            // loses its counter rather than its sandbox.
            NSLog("Honeycode: preview sandbox rules failed to compile with the "
                  + "blocked-request counter; retrying without it.")
            compile(loopback, announcing: false) { list, error in
                guard let list else {
                    // Fail closed, and closed means *nothing loads*.
                    //
                    // Disabling JavaScript was the previous answer and it does
                    // take effect — `webView.configuration` hands back a copy,
                    // but the copy shares the same `WKWebpagePreferences`
                    // object, so the flag reaches the live view (checked, not
                    // assumed: a page whose only script fired a beacon didn't
                    // fire it). It just isn't sufficient. A page with no script
                    // at all can still carry `<img src="https://…/?stolen">`,
                    // and the markup was written by the agent that has already
                    // read your files — so "no JavaScript" leaves the
                    // exfiltration path it was meant to close. Without a rule
                    // list there is no safe way to show agent-written markup,
                    // so it isn't shown.
                    view.configuration.defaultWebpagePreferences
                        .allowsContentJavaScript = false
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
    }

    /// Build the list and hand it to WebKit.
    ///
    /// `announcing` is the only axis, and it is a separate identifier rather
    /// than a flag threaded through one: the store caches by identifier, and
    /// two different rule sets under one name is how you end up debugging a
    /// list you didn't write.
    private static func compile(_ loopback: Loopback, announcing: Bool,
                                then finish: @escaping (WKContentRuleList?, Error?) -> Void) {
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

        // Ordering matters twice over.
        //
        // `ignore-previous-rules` has to come after the block or it cancels it,
        // which would silently produce an unrestricted web view that looked
        // identical from the outside.
        //
        // And `notify` has to come *before* those same allowances, because that
        // is what keeps the counter honest: an allowed request matches the
        // notify rule too, and the `ignore-previous-rules` that lets it through
        // discards the notification along with the block. Only a request that
        // was actually refused survives to be reported. (The panel re-checks
        // each reported URL against the grant anyway — see `Loopback.permits`.
        // A counter that cried wolf about localhost would be worse than none.)
        var entries: [String] = []
        if announcing {
            entries.append(#"{"trigger":{"url-filter":".*"},"action":{"type":"notify","notification":"\#(notification)"}}"#)
        }
        entries.append(#"{"trigger":{"url-filter":".*"},"action":{"type":"block"}}"#)
        entries += allow.map {
            #"{"trigger":{"url-filter":"\#($0)"},"action":{"type":"ignore-previous-rules"}}"#
        }
        let rules = "[\n" + entries.joined(separator: ",\n") + "\n]"

        guard let store = WKContentRuleListStore.default() else {
            finish(nil, nil)
            return
        }
        store.compileContentRuleList(
            forIdentifier: "honeycode-sandbox-3-\(announcing ? "loud" : "quiet")"
                + "-\(loopback.identifier)",
            encodedContentRuleList: rules,
            completionHandler: finish)
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
            guard let url = action.request.url else { return .allow }

            // The initial load is `.other`; anything the user clicked leaves.
            if action.navigationType == .linkActivated {
                // Only the web schemes leave. Handing an arbitrary URL to
                // `NSWorkspace` means handing it to Launch Services, and the
                // markup around the link was written by the agent: `<a
                // href="file:///…/results.command">Click for results</a>` reads
                // as a link and behaves as a double-click on an executable.
                // Cancelled rather than opened, and cancelled rather than
                // navigated — a preview that follows a link stops being a
                // preview.
                guard let scheme = url.scheme?.lowercased(),
                      ["http", "https", "mailto"].contains(scheme) else { return .cancel }
                NSWorkspace.shared.open(url)
                return .cancel
            }

            // A new document is a new set of complaints.
            //
            // Everything that reaches this method is about to be handed to the
            // rule list *and will get there* — a document the list is going to
            // refuse never arrives here at all, which is why `load` checks that
            // case for itself. So this only ever fires for a page that is
            // genuinely starting, which is exactly when the old page's blocked
            // hosts stop being true.
            if action.targetFrame?.isMainFrame ?? false {
                controller?.clearBlocked()
            }
            return .allow
        }

        /// A request the rule list refused, as WebKit reports it.
        ///
        /// SPI, and the reason for using it is that there is no public
        /// equivalent: content-rule blocks are invisible to every delegate
        /// method that ships in the SDK. What it costs if it ever goes away is
        /// a toolbar badge — the selector stops being called, nothing else
        /// changes, and no part of the sandbox depends on it. Verified against a
        /// live web view rather than assumed: an `<img>` and a `fetch()` to a
        /// blocked host both arrive here, and an allowed loopback request
        /// doesn't.
        @MainActor
        @objc(_webView:URL:contentRuleListIdentifiers:notifications:)
        func webView(_ webView: WKWebView, url: URL,
                     contentRuleListIdentifiers: [String], notifications: [String]) {
            guard notifications.contains(WebPreview.notification) else { return }
            guard !loopback.permits(url) else { return }
            controller?.noteBlocked(url)
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

    /// Hosts the preview sandbox refused, in the order they were first heard
    /// of, cleared whenever a new document starts.
    ///
    /// Diagnostic only. Nothing reads this to decide what loads — see
    /// `WebPreview.notification` for why it exists at all.
    @Published private(set) var blocked: [String] = []

    private weak var view: WKWebView?

    func attach(_ view: WKWebView) { self.view = view }

    func update(from view: WKWebView, loading: Bool) {
        canGoBack = view.canGoBack
        canGoForward = view.canGoForward
        isLoading = loading
        currentURL = view.url
    }

    /// By host rather than by URL. A page pulling a library, its stylesheet
    /// and four fonts off one CDN has one problem and not six, and the fix is
    /// the same for all of them — so the list stays the length of the answer
    /// rather than the length of the page.
    func noteBlocked(_ url: URL) {
        guard let host = url.host, !blocked.contains(host) else { return }
        blocked.append(host)
    }

    func clearBlocked() {
        guard !blocked.isEmpty else { return }
        blocked = []
    }

    func back() { view?.goBack() }
    func forward() { view?.goForward() }
    func reload() { view?.reload() }
    func load(_ url: URL) { view?.load(URLRequest(url: url)) }
}

/// A preview that says what the sandbox refused.
///
/// The panel has a toolbar to put a badge in; a transcript row does not, and
/// for a while that meant the fix for a silently-black preview existed in the
/// one place the problem was *least* common. Most previews in this app are
/// inline — a code fence with a Preview toggle, a diff card, the sheet either
/// of them expands into — and every one of them was still capable of rendering
/// a page's background colour and nothing else with no explanation anywhere.
///
/// So the reporting moves to where the previews are. This owns the
/// `WebController` the reporting needs, which is the only reason it exists as a
/// wrapper rather than a modifier: `WebPreview` is an `NSViewRepresentable` and
/// can't hold a `@StateObject` of its own.
struct SandboxedPreview: View {
    let source: WebPreview.Source
    var scrolls = false
    var fitting: CGFloat?
    var zoom: CGFloat = 1
    var onHeight: ((CGFloat) -> Void)?

    @StateObject private var web = WebController()

    var body: some View {
        WebPreview(source: source, controller: web, scrolls: scrolls,
                   fitting: fitting, zoom: zoom, onHeight: onHeight)
            // Over the page rather than under it. A strip that takes space
            // would resize every preview in the transcript the moment a page
            // reached for a CDN, and the height a code fence reports is
            // measured from the page — so the note has to sit outside that
            // measurement or it feeds back into it.
            .overlay(alignment: .bottom) {
                if !web.blocked.isEmpty {
                    BlockedNote(hosts: web.blocked)
                        .padding(Theme.s4)
                        .transition(.opacity)
                }
            }
            .animation(Motion.reveal, value: web.blocked)
    }
}

/// What the sandbox refused, small enough to sit on top of a page.
///
/// Names the first host rather than only counting them. "2 blocked" tells you
/// there's a problem and leaves you to find out which; "unpkg.com + 1" is
/// usually the whole diagnosis, because a page that reaches for one CDN has
/// generally reached for one CDN.
struct BlockedNote: View {
    let hosts: [String]

    var body: some View {
        HStack(spacing: Theme.s2) {
            Image(systemName: "shield.slash")
                .font(.system(size: 9.5, weight: .medium))
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, Theme.s4)
        .padding(.vertical, Theme.s2 + 1)
        .background(Color.diffDelText.opacity(0.92), in: Capsule())
        .help(help)
    }

    private var label: String {
        guard let first = hosts.first else { return "" }
        return hosts.count == 1 ? "\(first) blocked" : "\(first) + \(hosts.count - 1) blocked"
    }

    private var help: String {
        "This page asked other servers for parts of itself and the preview only "
            + "reaches this machine, so nothing was sent:\n"
            + hosts.map { "• \($0)" }.joined(separator: "\n")
    }
}
