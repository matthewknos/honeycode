import SwiftUI
import AppKit

/// The browser, beside the conversation rather than on top of it.
///
/// A sheet was the wrong shape for this. The point of previewing a dev server
/// is watching it change *while* you talk to the agent about it — a modal that
/// hides the transcript makes you close it to say anything, which is exactly
/// the loop you were trying to stay in. So it's a panel: resizable, alongside,
/// and it stays put.
struct BrowserPanel: View {
    @ObservedObject var session: Session
    @ObservedObject var workspace: Workspace
    @StateObject private var web = WebController()
    @StateObject private var watch = FileWatch()
    @State private var address = ""
    @State private var showingBlocked = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.rule)

            GeometryReader { geometry in
                ZStack(alignment: .bottomTrailing) {
                    // A document wins over a URL: it's the thing you just asked
                    // for, and it can only get here by your sending it.
                    //
                    // Keyed on the path, not on the artifact's identity. The
                    // whole point of a file is that its *contents* change under
                    // a view that stays put — rebuilding the view on every
                    // revision would throw away the scroll position and the
                    // slide you were on, which is the thing live reloading was
                    // supposed to save.
                    if let file = session.browserFile {
                        WebPreview(source: .file(file), controller: web, scrolls: true,
                                   zoom: session.browserZoom)
                            .id(file)
                    } else if let artifact = session.browserHTML {
                        WebPreview(source: .html(artifact.markup),
                                   controller: web, scrolls: true,
                                   zoom: session.browserZoom)
                            .id(artifact.id)
                    } else if let url = session.browserURL {
                        WebPreview(source: .url(url), controller: web, scrolls: true,
                                   zoom: session.browserZoom)
                    } else {
                        empty
                    }

                    if !session.splitOpen && session.miniChatVisible {
                        MiniChat(session: session, workspace: workspace,
                                 bounds: geometry.size)
                            .padding(Theme.s6)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .background(Theme.canvas)
        .onAppear {
            address = title
            follow()
        }
        .onChange(of: session.browserURL) { _, new in
            address = new?.absoluteString ?? ""
        }
        .onChange(of: session.browserHTML) { _, new in
            guard new != nil else { return }
            address = title
        }
        .onChange(of: session.browserFile) { _, _ in
            address = title
            follow()
        }
        .onChange(of: web.currentURL) { _, new in
            // Follow redirects and link clicks in the field, so it says where
            // you are rather than where you asked to go. A document is shown by
            // name, so there's nothing to follow and the label stands.
            guard session.browserFile == nil, session.browserHTML == nil,
                  let new else { return }
            address = new.absoluteString
        }
        .onDisappear { watch.stop() }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: Theme.s3) {
            navButton("chevron.left", "Back", enabled: web.canGoBack) { web.back() }
            navButton("chevron.right", "Forward", enabled: web.canGoForward) { web.forward() }

            TextField("Type a URL", text: $address)
                .textFieldStyle(.plain)
                .font(Theme.monoSmall)
                .padding(.horizontal, Theme.s4)
                .padding(.vertical, Theme.s3 - 1)
                .background(Theme.well, in: Capsule())
                .onSubmit(go)

            if !web.blocked.isEmpty { blockedBadge }

            ZoomControl(zoom: $session.browserZoom)
                .disabled(!loaded)

            if web.isLoading {
                ProgressView().controlSize(.small).scaleEffect(0.55).frame(width: 14)
            } else {
                navButton("arrow.clockwise", "Reload", enabled: loaded) {
                    // `reload()` has nothing to fetch for markup loaded from a
                    // string, so an artifact with no file behind it is
                    // re-rendered by handing the panel a fresh identity instead.
                    if session.browserFile == nil, let artifact = session.browserHTML {
                        session.browserHTML = Artifact(language: artifact.language,
                                                       markup: artifact.markup)
                            .succeeding(artifact)
                    } else {
                        web.reload()
                    }
                }
            }
            navButton("folder", "Open a file…", enabled: true) { pick() }
            navButton("safari", "Open in browser", enabled: loaded) { openExternally() }
            // Only with the conversation hidden. Beside the transcript
            // there's already a composer six inches to the left.
            if !session.splitOpen {
                navButton("bubble.left.and.text.bubble.right",
                          session.miniChatVisible ? "Hide chat" : "Chat about this page",
                          enabled: true) {
                    withAnimation(Motion.reveal) { session.miniChatVisible.toggle() }
                }
            }
            // The full-width toggle that used to live here is the tab strip's
            // split button now — see `PaneTabs.splitButton`. It was the same
            // switch reached two ways, and the strip's version is the one that
            // is on screen whichever tab you are on.
        }
        .padding(.horizontal, Theme.s5)
        .padding(.vertical, Theme.s4)

    }

    /// Out as a real file, so the browser renders it unsandboxed — which is the
    /// reason to ask for it.
    private func openExternally() {
        if let file = session.browserFile {
            NSWorkspace.shared.open(file)
        } else if let artifact = session.browserHTML, let file = artifact.write() {
            NSWorkspace.shared.open(file)
        } else if let url = session.browserURL {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: What didn't load

    /// The count of hosts the sandbox refused, and only when there are any.
    ///
    /// A permanent indicator saying "0 blocked" would be one more thing in a
    /// toolbar that already has nine, and it would be telling you nothing on
    /// almost every page you ever open. This appears when it has something to
    /// say, which is also the only moment anyone would look for it.
    private var blockedBadge: some View {
        Button { showingBlocked.toggle() } label: {
            HStack(spacing: Theme.s1) {
                Image(systemName: "shield.slash")
                    .font(.system(size: 10, weight: .medium))
                Text("\(web.blocked.count)")
                    .font(Theme.captionStrong)
                    .monospacedDigit()
            }
            .foregroundStyle(Color.diffDelText)
            .padding(.horizontal, Theme.s3)
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverCapsule())
        .help(web.blocked.count == 1
              ? "One host blocked by the preview sandbox"
              : "\(web.blocked.count) hosts blocked by the preview sandbox")
        .popover(isPresented: $showingBlocked, arrowEdge: .bottom) { blockedDetail }
        .transition(.opacity)
    }

    /// Which hosts, and what to do about it.
    ///
    /// Hosts rather than URLs, and the sentence before them matters more than
    /// the list: the failure this explains looks like a broken page, not like a
    /// refused request, so the first thing it has to do is say that the page is
    /// probably fine and the sandbox stopped it.
    private var blockedDetail: some View {
        VStack(alignment: .leading, spacing: 0) {
            PopoverHeader("Blocked by the preview sandbox", top: Theme.s5)
            Text("This page asked other servers for parts of itself. The preview "
                 + "only reaches this machine, so those requests never left — "
                 + "which is usually what a blank or half-drawn page here means.")
                .font(Theme.note)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Theme.s5)
                .padding(.bottom, Theme.s4)

            Divider().overlay(Theme.rule)

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.s2) {
                    ForEach(web.blocked, id: \.self) { host in
                        Text(host)
                            .font(Theme.monoSmall)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.s5)
                .padding(.vertical, Theme.s4)
            }
            .frame(maxHeight: 132)

            Divider().overlay(Theme.rule)

            VStack(alignment: .leading, spacing: Theme.s4) {
                Text("The agent that wrote this page can fix it — or open it in your "
                     + "browser, which has no sandbox.")
                    .font(Theme.note)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Theme.s4) {
                    Button("Ask the Agent to Fix It") {
                        showingBlocked = false
                        askAgentToVendor()
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Open in Browser") {
                        showingBlocked = false
                        openExternally()
                    }
                }
                .controlSize(.small)
            }
            .padding(.horizontal, Theme.s5)
            .padding(.vertical, Theme.s4)
        }
        .frame(width: 300)
    }

    /// Hand the diagnosis back to whoever caused it.
    ///
    /// The badge made a silent failure visible, which is worth having and is
    /// not the same as fixing it — the pages that hit this are written by an
    /// agent that has no idea the sandbox exists, so left alone it writes the
    /// same page again tomorrow. Twice in one hour, in the case that prompted
    /// all of this, and both times the repair was done by hand.
    ///
    /// Sent rather than dropped in the composer because the composer's text is
    /// owned by the transcript column and this panel can't reach it — and
    /// because a button labelled with what it will do should do it. The hosts
    /// are named, and so are the four places a page usually hides them, which
    /// is the part an agent gets wrong: the import map and the decoder path
    /// were separate discoveries in the run this came from.
    private func askAgentToVendor() {
        let hosts = web.blocked
        guard !hosts.isEmpty else { return }
        session.send("""
        The browser panel blocked this page's requests to \(Self.list(hosts)) — the \
        preview sandbox only reaches this machine, so those files never arrived and the \
        page doesn't work in the panel.

        Make it work with no external requests: fetch what it needs into the project \
        beside the page and point it at the local copies. Check every place a URL can \
        hide — import maps, `<script src>`, `<link rel="stylesheet">`, `@import` in CSS, \
        `new Worker(...)`, and any loader that takes its own decoder or worker path. Then \
        confirm nothing outside the project is referenced any more.
        """)
    }

    /// "a", "a and b", "a, b and c".
    private static func list(_ items: [String]) -> String {
        guard let last = items.last else { return "" }
        guard items.count > 1 else { return last }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }

    /// Whether there's anything in the panel at all — a page or a document.
    private var loaded: Bool {
        session.browserURL != nil || session.browserHTML != nil || session.browserFile != nil
    }

    /// What the address field says.
    ///
    /// The path, whenever there's a file — including for an artifact, which
    /// used to say "Artifact — HTML" here. That label was honest when an
    /// artifact was a string with no file behind it and inventing an
    /// `artifact://` URL would have been a lie. It has a real path now, and the
    /// field that exists to say where you are should say it: it's the path
    /// you'd hand to the agent, drop in a terminal, or check against the one in
    /// a diff card above.
    ///
    /// Abbreviated with `~`, and shown without `file://` — the scheme is the
    /// least informative eleven characters available.
    private var title: String {
        if let file = session.browserFile {
            return (file.path as NSString).abbreviatingWithTildeInPath
        }
        if let artifact = session.browserHTML { return artifact.label }
        return session.browserURL?.absoluteString ?? ""
    }

    /// Reload the panel when the file underneath it changes.
    ///
    /// This is the part that makes the preview live: the agent edits the file,
    /// half a second later the page you're looking at is the new one, and you
    /// never touched anything. `reload()` rather than a fresh load, so WebKit
    /// keeps the back list and the view keeps its place on the page.
    private func follow() {
        watch.watch(session.browserFile) { web.reload() }
    }

    private func navButton(_ symbol: String, _ label: String,
                           enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(enabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverCapsule())
        .disabled(!enabled)
        .help(label)
    }

    /// Anything without a scheme is treated as a host, so `localhost:5173`
    /// works — which is how anyone actually types it.
    private func go() {
        var text = address.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        // A path typed or pasted into the field is a file, not a host. Worth
        // handling because it's the obvious thing to try once the panel can
        // show files at all, and `http://Users/me/deck.html` is a baffling
        // thing to be shown in return.
        let expanded = NSString(string: text).expandingTildeInPath
        if expanded.hasPrefix("/"), FileManager.default.fileExists(atPath: expanded) {
            session.open(file: URL(fileURLWithPath: expanded))
            return
        }
        if !text.contains("://") { text = "http://" + text }
        guard let url = URL(string: text) else { return }
        // Typed, so it sticks until a new server appears.
        session.browserURLIsManual = true
        // Going somewhere puts the document away. It's still in the transcript,
        // and leaving it loaded underneath would make Back mean two things.
        session.browserHTML = nil
        session.browserFile = nil
        session.browserURL = url
        web.load(url)
    }

    /// Open something from disk.
    ///
    /// Deliberately not restricted to HTML. WebKit renders PDFs, SVGs, images,
    /// plain text and Markdown-as-text perfectly well, and a picker that greys
    /// out the file you're pointing at is a worse experience than a page that
    /// says it can't display it. The read grant covers only the chosen file's
    /// own folder either way.
    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a file to preview. It reloads when it changes on disk."
        panel.directoryURL = session.directory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        session.open(file: url)
    }

    // MARK: Empty state

    private var empty: some View {
        VStack(spacing: Theme.s5) {
            Image(systemName: "globe")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.quaternary)
            VStack(spacing: Theme.s2) {
                Text("Nothing loaded")
                    .font(Theme.display(Theme.t6))
                Text("Type a URL above, open a file from disk, or open the dev "
                     + "server this session started.")
                    .font(Theme.note)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 260)
            }
            if let server = session.devServer {
                HStack(spacing: Theme.s4) {
                    Button("Open \(server.host ?? "server")\(server.port.map { ":\($0)" } ?? "")") {
                        session.browserURLIsManual = false
                        session.browserURL = server
                        address = server.absoluteString
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Open a File…") { pick() }
                }
                .controlSize(.small)
            } else {
                VStack(spacing: Theme.s3) {
                    Button("Open a File…") { pick() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Text("No dev server detected yet")
                        .font(Theme.note)
                        .foregroundStyle(.secondary)
                    // A manual re-read, for when a server was announced in a
                    // turn that finished before this feature existed — or in
                    // any shape the pattern didn't catch.
                    Button("Look again") { session.scanForDevServer() }
                        .buttonStyle(.link)
                        .font(Theme.note)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
