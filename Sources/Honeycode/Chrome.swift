import SwiftUI
import AppKit

/// The sidebar's translucent material.
///
/// Hand-rolled because the layout no longer uses `NavigationSplitView` — see
/// `RootView` for why. `.sidebar` is the same material AppKit gives a real
/// source list, so this looks identical to the one we gave up.
struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Strips the titlebar down to just the traffic lights.
///
/// `.windowStyle(.hiddenTitleBar)` gets most of the way, but the window still
/// carries a title string (which shows through in some states) and a toolbar
/// baseline. Clearing all three here is what removes the rule across the top
/// without also removing the traffic lights.
struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { configure(view.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        WindowMode.shared.observe(window)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        // The content extends under the titlebar, so the sidebar's material
        // runs all the way to the top edge behind the traffic lights rather
        // than starting below a grey band.
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
    }
}

/// How much room the traffic lights need.
enum Chrome {
    /// The three lights run from roughly x=13 to x=70. Everything used to dodge
    /// them *downwards*, because there was no bar across the top of the window
    /// to put anything in — so this number never had to exist. `TitleBar` puts
    /// controls on the lights' own line, and 78 is the leading inset that
    /// clears the last one with a normal gap after it rather than a control
    /// butting up against the zoom button.
    ///
    /// Only while the lights are actually there — see `WindowMode`.
    static let trafficLightWidth: CGFloat = 78
}

/// Whether the traffic lights are on screen.
///
/// They are not, in full screen: macOS moves them into the overlay that slides
/// down when you push the pointer at the top of the display, and until you do
/// there is nothing whatever in the window's leading corner. The title bar was
/// holding 78 points open for three buttons that had left, so the wordmark sat
/// a centimetre in from the window edge with nothing to explain it — which
/// reads exactly like a row that failed to line up with anything.
///
/// A shared object rather than per-view state, because there is one window and
/// this is a fact about it. `WindowChrome` hands the window over; the two
/// notifications keep the answer right afterwards.
@MainActor
final class WindowMode: ObservableObject {
    static let shared = WindowMode()

    /// True when the leading corner is empty and content may start at the edge.
    @Published private(set) var lightsHidden = false

    private weak var window: NSWindow?
    private var observing = false

    private init() {}

    func observe(_ window: NSWindow) {
        self.window = window
        refresh()
        guard !observing else { return }
        observing = true
        for name in [NSWindow.didEnterFullScreenNotification,
                     NSWindow.didExitFullScreenNotification] {
            NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { _ in MainActor.assumeIsolated { WindowMode.shared.refresh() } }
        }
    }

    private func refresh() {
        let hidden = window?.styleMask.contains(.fullScreen) ?? false
        if lightsHidden != hidden { lightsHidden = hidden }
    }
}

/// `glassEffect` where the OS has one, and the nearest older material where it
/// doesn't.
///
/// Every call site already sits inside an `if glass` branch with an opaque
/// alternative beside it — but that branch asks whether a background *photo* is
/// set, which is a different question from whether the API exists. Answering
/// both with one flag would put an opaque card over a photograph on an older
/// Mac, which is the thing the background feature was there to avoid.
///
/// `.regularMaterial` is not Liquid Glass and doesn't pretend to be. It is the
/// same job — a translucent surface that samples what is behind it — done by
/// the API that predates it by four releases. It is also the one symbol that
/// was holding the whole app at macOS 26: see `tools/availability.py`.
extension View {
    @ViewBuilder
    func glassy(in shape: some Shape) -> some View {
        // Reduce Transparency first, because it is an answer about the person
        // rather than about the API. What the system does with its own chrome
        // when this is on is exactly this — the material becomes an opaque
        // fill — and following it is not a concession: a surface that samples
        // what is behind it is unreadable to whoever turned this on, which is
        // why they turned it on. It also happens to be the cheapest thing this
        // app can do on a Mac that feels every offscreen pass.
        if Accessibility.shared.reduceTransparency {
            background(Theme.surface, in: shape)
        } else if #available(macOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }
}

/// The composer and the mention list, over whatever's behind them.
///
/// Real `glassEffect` when a background photo is set, an opaque fill otherwise.
/// Both halves are needed: glass over a flat `canvas` is invisible work, and an
/// opaque card over a photograph is the thing the background feature was
/// supposed to avoid. A solid fill was used everywhere until now because it
/// wasn't confirmed the material samples *in-app* content rather than the
/// desktop the way `NSVisualEffectView.behindWindow` does.
struct RaisedSurface: ViewModifier {
    let glass: Bool
    let radius: CGFloat
    var focused: Bool = false

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        // The system accent, always. It used to be overridable, so a composer
        // in a column could tint its focus ring with the account's own colour —
        // the ring saying both which composer had the keys and whose it was.
        // With one conversation in the pane there is nothing to tell it apart
        // from, and the account is named twice above it anyway.
        let ring = Color.accentColor
        if glass {
            content
                .glassy(in: shape)
                // Glass carries its own edge, so the hairline would double it.
                // Only the focus ring survives.
                .overlay(shape.strokeBorder(
                    focused ? ring.opacity(0.55) : .clear, lineWidth: 1))
        } else {
            content
                .background(Theme.surface, in: shape)
                .overlay(shape.strokeBorder(
                    focused ? ring.opacity(0.5) : Theme.rule, lineWidth: 1))
        }
    }
}

/// The composer's ground, in both modes.
///
/// Coding mode isn't a restyled card — it's the absence of one. A terminal
/// prompt sits directly on the same ground as the scrollback above it, divided
/// by a rule and nothing else, and the focus ring becomes a caret-coloured
/// underline because there is no border left to tint. Wrapping the choice in
/// one modifier keeps the composer from growing a `if terminal` at every
/// corner radius.
struct ComposerSurface: ViewModifier {
    let terminal: Bool
    let glass: Bool
    var focused: Bool = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if terminal {
            content
                // Opaque, and not the glass the rest of the app uses. Every
                // translucent surface is an offscreen pass per frame, and the
                // one place that cost is least affordable is the pane you
                // switched to because it was faster.
                .background(Theme.canvas)
                // A hairline, and it stays a hairline. The focus ring moved to
                // the caret: a full-bleed rule that lights up is a two-thousand
                // point announcement that you clicked in the only field on
                // screen, and no terminal has ever needed one.
                .overlay(alignment: .top) {
                    Rectangle().fill(Theme.rule).frame(height: 1)
                }
        } else {
            content.modifier(RaisedSurface(glass: glass,
                                           radius: Theme.cornerCard * 2,
                                           focused: focused))
        }
    }
}

// MARK: - Content over a background image

/// Whether the surrounding content is sitting on glass.
///
/// Passed through the environment rather than as a parameter because it has to
/// reach code blocks, diffs and charts nested several levels inside the
/// transcript, and threading a `Bool` through every intermediate view to change
/// one fill is how a codebase acquires a parameter nobody can delete.
private struct OnGlassKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var onGlass: Bool {
        get { self[OnGlassKey.self] }
        set { self[OnGlassKey.self] = newValue }
    }
}

/// The reading panel, as a fixed backdrop rather than a wrapper.
///
/// It used to hug the transcript — glass applied to the scrolling stack itself,
/// so the panel grew and shrank with the content like a page. That looked
/// right and behaved badly: glass is composited by the window server, and a
/// layer that resizes on every lazily-built row gets invalidated constantly.
/// It would drop out entirely for a frame or two while scrolling, and never in
/// a screen capture, because a capture re-renders instead of reading the
/// composited layer.
///
/// Sized to the column and pinned to the pane, it stops changing size, so
/// there's nothing to invalidate. The cost is that a two-line reply now sits on
/// a full-height panel rather than a small card — which is the same trade every
/// document app makes, and steadier than the alternative.
struct ReadingPanel: View {
    let glass: Bool
    let width: CGFloat

    /// The corner radius and the inset are the same number on purpose: the
    /// scrolling content is masked to exactly this inset, so text can't appear
    /// in the space the corners curve out of.
    static let corner: CGFloat = Theme.s6
    static let inset: CGFloat = Theme.s6

    var body: some View {
        if glass {
            RoundedRectangle(cornerRadius: Self.corner)
                .fill(Color.clear)
                .glassy(in: RoundedRectangle(cornerRadius: Self.corner))
                .frame(maxWidth: width + Theme.s6 * 2)
                .padding(.vertical, Self.inset)
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)
        }
    }
}

/// A recessed block — code, diff, chart — inside the reading column.
///
/// On the plain canvas that's an opaque ground, which is what makes code read as
/// set into the page. On glass it has to be translucent instead: an opaque slab
/// inside a glass panel reads as a second, competing surface, which was exactly
/// the three-surfaces-at-once problem the glass column was meant to solve.
struct InsetSurface: ViewModifier {
    @Environment(\.onGlass) private var onGlass
    /// A code block, a diff, a chart — a panel of content set into the pane,
    /// which is what `cornerCard` means. It was a bare 8, which is the last
    /// place a corner radius was hiding after the named ones were snapped.
    var radius: CGFloat = Theme.cornerCard

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        return content
            .background(onGlass ? AnyShapeStyle(.quaternary.opacity(0.5))
                                : AnyShapeStyle(Theme.codeGround),
                        in: shape)
            .overlay(shape.strokeBorder(Theme.rule.opacity(onGlass ? 0.5 : 1), lineWidth: 1))
    }
}

/// The floating status readout, which has nothing behind it but the photo.
struct StatusSurface: ViewModifier {
    let glass: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if glass {
            content.glassy(in: Capsule())
        } else {
            content
        }
    }
}

/// The collapsed sidebar's floating control groups.
struct RailSurface: ViewModifier {
    let glass: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if glass {
            // No extra horizontal padding: the rail's own width already
            // provides the margin, and adding more here made the pill sit
            // closer to the edge on the left than the View menu does on the
            // right.
            content.glassy(in: Capsule())
        } else {
            content
        }
    }
}

/// Sending a rendered artifact to the browser panel.
///
/// A closure through the environment rather than the session itself: a code
/// block sits several levels down inside a markdown block inside a transcript
/// row, and it has no other reason to know which session it belongs to. This
/// way the transcript that owns the session decides what "open" means, and the
/// one place that can't do it — the mini chat, which floats *over* the panel —
/// simply doesn't install a handler, so the button isn't offered.
private struct OpenArtifactKey: EnvironmentKey {
    static let defaultValue: ((Artifact) -> Void)? = nil
}

extension EnvironmentValues {
    var openArtifact: ((Artifact) -> Void)? {
        get { self[OpenArtifactKey.self] }
        set { self[OpenArtifactKey.self] = newValue }
    }
}

/// Reader text size, as a multiplier on the prose base.
///
/// An environment value rather than a global: the transcript scales, the
/// chrome around it doesn't. A sidebar that grew with the reading size would
/// be a zoom control, which is a different and worse thing.
/// Prose only: no previews, no source, no second opinions.
///
/// Set by the floating chat over a full-width preview, where every one of those
/// things is redundant — the artifact is the thing filling the screen behind
/// the card, live, and a 400pt copy of it inside a 400pt window is a worse view
/// of what you're already looking at.
private struct PlainProseKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var plainProse: Bool {
        get { self[PlainProseKey.self] }
        set { self[PlainProseKey.self] = newValue }
    }
}

private struct ProseScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }

extension EnvironmentValues {
    var proseScale: CGFloat {
        get { self[ProseScaleKey.self] }
        set { self[ProseScaleKey.self] = newValue }
    }
}

/// The port this session's dev server is on, if it has announced one.
///
/// Read by `WebPreview` to decide how much of loopback agent-written markup is
/// allowed to reach. An environment value because the previews that need it are
/// transcript rows — a code fence, a diff card — several levels below anything
/// holding a `Session`, and threading a port through all of them would put a
/// security parameter in seven signatures that have no other reason to change.
private struct DevServerPortKey: EnvironmentKey { static let defaultValue: Int? = nil }

extension EnvironmentValues {
    var devServerPort: Int? {
        get { self[DevServerPortKey.self] }
        set { self[DevServerPortKey.self] = newValue }
    }
}

/// A hover cursor that always cleans up after itself.
///
/// `NSCursor.push()` on enter and `.pop()` on exit is the obvious spelling and
/// it leaks: if the view goes away while the pointer is still over it — the
/// browser panel closing under a divider you were about to drag, the mini chat
/// collapsing under its own resize grip — the exit never arrives and the pushed
/// cursor stays on the stack for the rest of the session. This pops on
/// disappear too, and tracks whether it actually pushed so it can never pop a
/// cursor it doesn't own.
struct HoverCursor: ViewModifier {
    let cursor: NSCursor
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside, !pushed {
                    cursor.push()
                    pushed = true
                } else if !inside, pushed {
                    NSCursor.pop()
                    pushed = false
                }
            }
            .onDisappear {
                if pushed {
                    NSCursor.pop()
                    pushed = false
                }
            }
    }
}

extension View {
    func hoverCursor(_ cursor: NSCursor) -> some View {
        modifier(HoverCursor(cursor: cursor))
    }
}
