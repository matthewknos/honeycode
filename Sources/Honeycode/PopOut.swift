import SwiftUI
import AppKit

/// The conversation, in a window of its own, over everything else.
///
/// The mini chat this is descended from floats over a full-width preview and
/// can't leave the window it's drawn in — which is fine for talking about a
/// page you're looking at, and no use at all for talking to an agent while you
/// watch something on the other side of the screen. So this is the same card,
/// promoted to a real window: `.floating` level, joins every Space, and stays
/// up while Honeycode is behind whatever you're actually doing.
///
/// One at a time. See `Workspace.poppedOut`.
@MainActor
final class PopOut: NSObject, NSWindowDelegate {

    static let shared = PopOut()
    private override init() { super.init() }

    private var panel: NSPanel?
    private var showing: Session.ID?
    /// Whether the state has been reconciled at least once.
    ///
    /// The first reconciliation is the restored arrangement rather than a
    /// decision — so a window that comes back at launch does so without taking
    /// the keyboard, and your first keystroke goes where you were looking.
    /// Every one after it is you pressing something, and takes the keyboard as
    /// any window would. Set in `sync` rather than in `show`, or a launch with
    /// nothing popped out would spend the allowance on your first real one.
    private var hasSynced = false
    /// Weak, and only so the window can clear the state that opened it when
    /// it's closed by something other than the state — ⌘W, mostly.
    private weak var workspace: Workspace?

    /// Called whenever `poppedOut` changes, and once when the window appears.
    ///
    /// Written as a reconciliation rather than as open/close calls so there's
    /// exactly one path from the state to the window. Popping straight from one
    /// session to another is then a close and an open, in that order, with no
    /// case where both are on screen.
    func sync(workspace: Workspace, background: BackgroundStore) {
        self.workspace = workspace
        let launch = !hasSynced
        hasSynced = true
        guard let id = workspace.poppedOut,
              let session = workspace.sessions.first(where: { $0.id == id })
        else { hide(); return }
        guard showing != id else { return }
        hide()
        show(session, workspace: workspace, background: background, quietly: launch)
    }

    private func show(_ session: Session, workspace: Workspace,
                      background: BackgroundStore, quietly: Bool) {
        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
            styleMask: [.titled, .closable, .resizable,
                        .fullSizeContentView, .nonactivatingPanel, .utilityWindow],
            backing: .buffered, defer: false)

        // No titlebar and no traffic lights: the card draws its own header, as
        // the main window does, and a 420pt overlay can't spare a band across
        // the top for three buttons two of which do nothing here.
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }

        // Above other applications, and present on whichever Space you're on —
        // including a full-screen one, which is the case this feature exists
        // for and needs `.fullScreenAuxiliary` specifically. The cost is that
        // it follows you everywhere rather than living on one desktop; that's
        // what the close button is for.
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        // 340 is where the composer's rail stops fitting even stripped down —
        // the same floor the mini chat uses, and for the same reason.
        panel.minSize = NSSize(width: 340, height: 260)

        // Translucent to the *desktop*, which needs the window itself to be
        // non-opaque — a SwiftUI material inside an opaque window blurs the
        // window's own background and nothing behind it, which over a video is
        // no translucency at all.
        panel.isOpaque = false
        panel.backgroundColor = .clear

        let content = PopOutChat(session: session, workspace: workspace)
            .environmentObject(workspace)
            .environmentObject(background)

        let material = NSVisualEffectView()
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        material.autoresizingMask = [.width, .height]

        // Constraints rather than an autoresizing mask: the material has no
        // size until it becomes the content view, so a mask pinned to a zero
        // frame keeps the card at zero.
        let host = NSHostingView(rootView: content)
        host.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: material.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: material.trailingAnchor),
            host.topAnchor.constraint(equalTo: material.topAnchor),
            host.bottomAnchor.constraint(equalTo: material.bottomAnchor),
        ])
        panel.contentView = material

        // AppKit remembers the frame rather than `@AppStorage` — a window drag
        // writes sixty times a second, which is the reason every other
        // draggable thing in this app keeps a live value separate from a stored
        // one. Autosave coalesces that itself.
        //
        // Restored explicitly as well as by name, and saved explicitly on the
        // way out. Popping from one conversation to another builds a second
        // panel while the first may not yet have deallocated, and a name
        // already registered makes `setFrameAutosaveName` fail — at which point
        // the window silently stops remembering where you put it.
        panel.setFrameAutosaveName(Self.frameName)
        if !panel.setFrameUsingName(Self.frameName) { place(panel) }

        panel.delegate = self
        if quietly {
            // `orderFrontRegardless`, not `orderFront`: at launch the app may
            // not be the active one, and a plain `orderFront` from an inactive
            // app queues the window until it is.
            panel.alphaValue = Self.dimmed
            panel.orderFrontRegardless()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
        self.panel = panel
        showing = session.id
    }

    /// First run: the bottom-right of the screen the pointer is on, inset by
    /// the same margin the window uses everywhere else. Centred would put it
    /// over the middle of whatever you're watching, which is the one place it
    /// mustn't start.
    private func place(_ panel: NSPanel) {
        let screen = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: screen.maxX - size.width - Theme.s7,
                                     y: screen.minY + Theme.s7))
    }

    private func hide() {
        guard let panel else { return }
        self.panel = nil
        showing = nil
        panel.saveFrame(usingName: Self.frameName)
        // Cleared first: closing a window we're deliberately taking down mustn't
        // come back through `windowWillClose` and clear the state that's already
        // being changed.
        panel.delegate = nil
        panel.close()
    }

    /// Closed by something that isn't `poppedOut` — ⌘W while the panel has the
    /// keyboard. The state follows the window rather than the other way round.
    func windowWillClose(_ notification: Notification) {
        (notification.object as? NSWindow)?.saveFrame(usingName: Self.frameName)
        panel = nil
        showing = nil
        workspace?.poppedOut = nil
    }

    /// Dimmed when it doesn't have the keyboard, and never click-through.
    ///
    /// Fading is what stops a panel over a video reading as an obstruction;
    /// click-through would be the natural next step and is deliberately not
    /// taken — a window that sometimes swallows clicks and sometimes passes
    /// them on is one you have to test before every click.
    func windowDidBecomeKey(_ notification: Notification) { fade(to: 1) }
    func windowDidResignKey(_ notification: Notification) { fade(to: Self.dimmed) }

    private func fade(to alpha: CGFloat) {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            panel.animator().alphaValue = alpha
        }
    }

    /// Dim enough to recede, not so far that a streaming reply stops being
    /// readable — the point of leaving it up is that you can read it.
    private static let dimmed: CGFloat = 0.78

    private static let frameName = "honeycode.popout"
}

/// A panel that takes the keyboard without activating the app.
///
/// Both halves matter. `canBecomeKey` is what lets you type into it at all;
/// `.nonactivatingPanel` in the style mask is what stops doing so from pulling
/// Honeycode to the front and pushing whatever you were watching behind it.
/// Main is refused because main window means "the document you're working on",
/// and that's still the real window.
private final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - The card

/// What's in the window: the same transcript and the same composer as the
/// column it came from, in the mini chat's stripped-down mode.
///
/// Words only. At 420pt a diff is unreadable, a tool row is a truncated path,
/// and a rendered artifact is a thumbnail of something the main window shows
/// properly — so the transcript runs `plain`, which keeps prose and turns a
/// code block into one line saying how much went past. What the machinery was
/// telling you is carried instead by the one live line under the transcript,
/// which is the part that matters while you're not watching.
///
/// The composer is the real one. Attachments, `@` mentions, slash commands, the
/// model picker and stop all work because this is the same `Session` object —
/// there is no second conversation and no second rendering path.
/// Drag the window by this view, where the OS can.
///
/// `WindowDragGesture` is macOS 15. Below that the header simply isn't a
/// handle — which costs less than it sounds, because the panel is `.titled`
/// with a transparent titlebar, so the strip along the top drags it the way it
/// drags every other window. `isMovableByWindowBackground` is still not the
/// answer for the reason given at the call site.
extension View {
    @ViewBuilder
    func windowDraggable() -> some View {
        if #available(macOS 15, *) {
            gesture(WindowDragGesture())
        } else {
            self
        }
    }
}

struct PopOutChat: View {
    @ObservedObject var session: Session
    @ObservedObject var workspace: Workspace

    @State private var draft = ""

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header
                Divider().overlay(Theme.rule)
                // The full width, not an inset one. `width` is a cap on the
                // reading column and the column is centred inside whatever's
                // left — so a cap that lands near the available width buys
                // nothing and risks the measure drifting off-centre.
                TranscriptView(session: session, mode: .summary,
                               width: geometry.size.width,
                               panelled: false, plain: true)
                activity
                ComposerView(draft: $draft, session: session,
                             width: geometry.size.width - Theme.s6,
                             compact: true) { text in
                    send(text)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            // The activity line arrives and leaves with every turn, and the
            // transcript above it moves when it does.
            .animation(Motion.reveal, value: session.isRunning)
        }
        // The panel is titled — that's what gives it the rounded frame and the
        // shadow — so SwiftUI reserves a titlebar's worth of safe area at the
        // top for a titlebar that isn't drawn. Left in, the header sat 40pt
        // down a 560pt card. The main window ignores it for the same reason.
        .ignoresSafeArea(.container, edges: .top)
        // Nothing else is holding this session open while it's out here: the
        // column it came from is drawing a placeholder, so the `onAppear` that
        // normally starts the agent isn't running anywhere.
        .onAppear { session.prepare() }
    }

    /// `/send` crosses an account boundary and needs a destination picker,
    /// which is a popover this window has no room to host. It's declined by
    /// name rather than passed through, because the one thing it must never do
    /// is reach the agent as text.
    private func send(_ text: String) {
        draft = ""
        if Relay.parse(text, from: session, in: workspace) != nil {
            session.append(.notice(id: UUID(),
                                   text: "/send needs the main window — "
                                       + "bring this conversation back to use it."))
            return
        }
        session.send(Skills.expand(text) ?? text)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Theme.s3) {
            Circle()
                .fill(session.account.accent)
                .frame(width: 6, height: 6)

            Text(session.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: Theme.s4)

            button("arrow.down.right.and.arrow.up.left", "Bring back to the window") {
                workspace.popIn()
            }
        }
        .padding(.horizontal, Theme.s5)
        .padding(.vertical, Theme.s4)
        // The header is the handle, as it is on every window — and the only
        // one, because `isMovableByWindowBackground` on a card made mostly of
        // text fields and a scroll view moves the window when you meant to
        // select a sentence.
        .contentShape(Rectangle())
        .windowDraggable()
        .hoverCursor(.openHand)
    }

    private func button(_ symbol: String, _ label: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverCapsule())
        .help(label)
    }

    // MARK: The activity line

    /// One line, only while a turn is running.
    ///
    /// This is what the dropped tool rows are worth from over here: not the
    /// arguments or the output, which you can't read at this size anyway, but
    /// the fact that something is still happening and roughly what. A card that
    /// shows only prose goes silent for the two minutes an agent spends
    /// editing, and silence is indistinguishable from stuck.
    @ViewBuilder
    private var activity: some View {
        if session.isRunning {
            HStack(spacing: Theme.s3) {
                ProgressView().controlSize(.small).scaleEffect(0.5).frame(width: 12)
                Text(Self.summarise(session.items))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.s5 + Theme.s2)
            .padding(.bottom, Theme.s2)
            .transition(.opacity)
        }
    }

    /// The most recent piece of machinery, and how much of it there has been
    /// since the agent last said something.
    ///
    /// Walks backwards and stops at the last thing you'd have read, so the cost
    /// is the length of the current burst rather than the length of the
    /// conversation — this is read on every redraw while a reply streams.
    static func summarise(_ items: [TranscriptItem]) -> String {
        var latest: String?
        var count = 0
        for item in items.reversed() {
            switch item {
            // Anything you'd have read stops the walk. Machinery from before
            // the last paragraph isn't what's happening now — it's what was
            // happening before the agent came back and told you about it.
            case .user, .assistant, .notice, .opinion, .compaction:
                return phrase(latest, count)
            case .tool(_, _, let name, let target, _, _):
                count += 1
                if latest == nil {
                    latest = target.isEmpty ? name : "\(name) · \(target)"
                }
            case .diff(_, _, let file, _, _):
                count += 1
                if latest == nil { latest = "Editing \((file as NSString).lastPathComponent)" }
            case .search(_, _, let query, _, _):
                count += 1
                if latest == nil { latest = "Searching \(query)" }
            case .thinking, .todos:
                continue
            }
        }
        return phrase(latest, count)
    }

    private static func phrase(_ latest: String?, _ count: Int) -> String {
        guard let latest else { return "Working…" }
        guard count > 1 else { return latest }
        return "\(latest)  ·  \(count) tools"
    }
}

// MARK: - What the column shows instead

/// The column a popped-out session left behind.
///
/// It keeps its slot rather than closing, so the arrangement doesn't reshuffle
/// on the way out and reshuffle again on the way back — and so there's an
/// obvious way home that doesn't involve finding the floating window first.
struct PoppedOutColumn: View {
    @ObservedObject var session: Session
    @ObservedObject var workspace: Workspace

    var body: some View {
        VStack(spacing: Theme.s4) {
            HStack(spacing: Theme.s3) {
                Circle()
                    .fill(session.account.accent)
                    .frame(width: 6, height: 6)
                Text(session.name)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if session.isRunning {
                    ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12)
                }
            }

            Text("Popped out — it's in the floating window.")
                .font(Theme.body)
                .foregroundStyle(.tertiary)

            Button("Bring It Back") { workspace.popIn() }
                .buttonStyle(.borderless)
                .font(.system(size: 12, weight: .medium))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The whole column, not just the button: this is a placeholder for a
        // conversation, and clicking a conversation should open it.
        .contentShape(Rectangle())
        .onTapGesture { workspace.popIn() }
    }
}
