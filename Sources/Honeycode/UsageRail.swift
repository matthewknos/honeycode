import SwiftUI
import AppKit
import Combine

/// State, in the three colours the rest of the app already uses for it.
///
/// Here rather than beside `UsagePressure` itself, which lives in AgentKit and
/// so cannot see a `Color` — the engine has to run in `honeycoded`, which has
/// no windows. The bands are the engine's decision; what they look like is
/// this side's.
extension UsagePressure {
    var colour: Color {
        switch self {
        case .easy:     return Theme.stateDone
        case .tight:    return Theme.stateHeld
        case .critical: return Theme.stateBad
        }
    }
}

// MARK: - One subscription, as a ring

/// How much of one allowance is gone, drawn as an arc.
///
/// A ring rather than the bar the readouts use, for the reason a rail exists at
/// all: four bars stacked down the side of a screen is a chart, and a chart is
/// a thing you read. Four rings is a thing you glance at and look away from,
/// which is the only interaction this is ever going to get.
///
/// The two colours say different things and are kept apart on purpose, the same
/// way `AccountDot` and the state palette are: the **dot in the middle** is
/// identity — which subscription this is — and the **arc around it** is state,
/// in the same three colours the rest of the app uses for going well, waiting,
/// and gone wrong. Colouring the arc in the account's own tint would have been
/// the obvious thing and would have left the rail saying nothing at all: four
/// hues that mean four names, with the one fact you opened it for — which of
/// them is nearly spent — carried by arc length alone.
struct UsageRing: View {
    let account: Account
    /// Nil when this subscription has not reported an allowance and has no
    /// spend to measure against a cap.
    ///
    /// Drawn rather than skipped, which is the one place this disagrees with
    /// its own instinct. A rail that shows only the accounts that answered is
    /// a rail whose height changes as answers arrive, and — worse — one where
    /// a subscription that has gone quiet looks like a subscription you do not
    /// have. So every seat keeps its place, and one that has said nothing says
    /// so: a hollow dot, no arc, and a dash where the number goes. The hollow
    /// dot is not a new idea either — `AccountDot` already uses it to mean
    /// real but provisional.
    let reading: AccountUsage?
    var size: CGFloat = UsageRailView.ring

    private var window: UsageWindow? { reading?.binding }

    private var pressure: UsagePressure { window?.pressure ?? .easy }

    /// A hair of arc even at zero, so a subscription nobody has touched reads
    /// as "nothing used" rather than as a ring that failed to draw. Nothing at
    /// all when there is no reading, which is a different statement.
    private var fraction: Double {
        guard let window else { return 0 }
        return max(0.015, min(1, Double(window.percent) / 100))
    }

    var body: some View {
        VStack(spacing: Theme.s1) {
            ZStack {
                Circle()
                    .stroke(Theme.rule, lineWidth: Self.stroke)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(pressure.colour,
                            style: StrokeStyle(lineWidth: Self.stroke,
                                               lineCap: .round))
                    // From the top, clockwise. The default start is three
                    // o'clock, which reads as an arc that begins somewhere
                    // arbitrary rather than as a gauge filling up.
                    .rotationEffect(.degrees(-90))
                AccountDot(account, hollow: reading == nil,
                           size: Theme.dot + Theme.s1)
            }
            .frame(width: size, height: size)
            // Measured readings are this app's own arithmetic against a cap
            // somebody typed in — see `AccountUsage.Source`. Drawn a shade back
            // so the rail doesn't present a guess and a fact at the same
            // weight; the popover says which is which in words.
            .opacity(reading?.source == .measured ? 0.72 : 1)

            Text(window.map { "\($0.percent)%" } ?? "—")
                .font(Theme.captionStrong)
                .monospacedDigit()
                .foregroundStyle(pressure.isAlarming
                                 ? AnyShapeStyle(Theme.stateBad)
                                 : AnyShapeStyle(.secondary))
        }
        .help(account.title + "\n" + summary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(account.title)
        .accessibilityValue(summary)
    }

    private var summary: String {
        reading?.summary ?? "No usage limits reported for this account"
    }

    private static let stroke: CGFloat = 3
}

// MARK: - The card behind one ring

/// Every window this subscription has, in full.
///
/// The ring can only ever show the binding one — see `AccountUsage.binding` —
/// and "73%" without "of what, and when does it come back" is a number you
/// cannot act on. This is where the rest of it lives.
struct UsageCard: View {
    let account: Account
    let reading: AccountUsage?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s4) {
            HStack(spacing: Theme.s3) {
                AccountDot(account, hollow: reading == nil)
                Text(account.title).font(Theme.captionStrong)
            }

            guardedBody
        }
        .padding(Theme.s5)
        .frame(width: 260, alignment: .leading)
    }

    /// What there is to say, or why there isn't anything.
    ///
    /// The second half is the one worth writing carefully. "Nothing reported"
    /// is not a fault and is the honest answer for two entirely ordinary
    /// situations — an agent that publishes no allowance at all, and one that
    /// does but has not been asked yet because nothing has run on it — and the
    /// remedy is different for each. Saying only "unknown" leaves somebody
    /// checking their network.
    @ViewBuilder
    private var guardedBody: some View {
        if let reading {
            windows(reading)
        } else {
            Text("This agent reports no allowance of its own. Set a monthly "
                 + "cap for it in Settings ▸ General and this fills in from "
                 + "what Honeycode spends.")
                .font(Theme.captionStrong)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func windows(_ reading: AccountUsage) -> some View {
        VStack(alignment: .leading, spacing: Theme.s4) {
            ForEach(reading.windows) { window in
                VStack(alignment: .leading, spacing: Theme.s1) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(window.title)
                        Spacer(minLength: Theme.s5)
                        if let resets = window.resets {
                            Text("Resets \(resets)").foregroundStyle(.tertiary)
                        }
                    }
                    .font(Theme.captionStrong)

                    bar(window)

                    HStack(alignment: .firstTextBaseline) {
                        Text("\(window.percent)% used").monospacedDigit()
                        if let detail = window.detail {
                            Text(detail).foregroundStyle(.tertiary)
                        }
                    }
                    .font(Theme.captionStrong)
                    .foregroundStyle(.secondary)
                }
            }

            // Where the figure came from and how old it is, in one line and
            // always. A panel that sits on screen all day looks live whether or
            // not it is, and the difference between a reading taken a minute
            // ago and one restored from disk at launch is the whole question of
            // whether to trust it.
            Text(provenance(reading))
                .font(Theme.captionStrong)
                .foregroundStyle(.tertiary)
        }
    }

    private func bar(_ window: UsageWindow) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.rule)
                Capsule()
                    .fill(window.pressure.colour)
                    .frame(width: max(2, geometry.size.width
                                         * min(1, Double(window.percent) / 100)))
            }
        }
        .frame(height: 4)
    }

    private func provenance(_ reading: AccountUsage) -> String {
        let age = Date().timeIntervalSince(reading.measuredAt)
        let when: String
        switch age {
        case ..<90:    when = "just now"
        case ..<3600:  when = "\(Int(age / 60)) min ago"
        default:       when = Self.clock.string(from: reading.measuredAt)
        }
        return reading.source.blurb + " · " + when
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}

// MARK: - The rail itself

/// Every subscription's allowance, down the edge of the screen.
///
/// The thing this app is for is holding several paid subscriptions at once, and
/// until now the only way to find out how much of one was left was to open a
/// session on it and read a five-character readout in the corner of a header
/// bar — which meant the question "who should get the biggest piece of this
/// crew run" was answered by feel, four times a day, by someone who could not
/// see the answer without leaving the thing they were deciding about.
///
/// Deliberately not a menu-bar extra, which is where this shape usually goes.
/// A menu-bar item shows one glyph until you click it; the whole value here is
/// four rings side by side, because what you are reading is not any one number
/// but which of them is furthest along.
struct UsageRailView: View {
    @ObservedObject private var usage = UsageStore.shared
    @State private var open: Account?

    var body: some View {
        VStack(spacing: Self.gap) {
            ForEach(Account.enabled) { account in
                UsageRing(account: account, reading: usage.reading(for: account))
                    .onHover { inside in open = inside ? account : nil }
                    .popover(isPresented: Binding(
                        get: { open == account },
                        set: { if !$0 { open = nil } })) {
                        UsageCard(account: account,
                                  reading: usage.reading(for: account))
                    }
            }
        }
        .padding(Self.inset)
        // Sized to the panel rather than to its own contents, and the panel is
        // sized from the same function — so the card fills the window exactly.
        //
        // Not a cosmetic choice. The panel is transparent so that the card can
        // have a rounded edge, and every point of a transparent panel that
        // isn't the card is a point of the screen that quietly stops taking
        // clicks. Letting the card hug its contents and leaving the window a
        // little generous would put a strip of invisible click-eater down the
        // edge of the display.
        .frame(width: Self.width, height: Self.height(for: Account.enabled.count))
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerFloat))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerFloat)
                    .strokeBorder(Theme.rule, lineWidth: 1))
        // Kept fresh while it is on screen and not otherwise — a rail nobody
        // has opened costs nothing at all, which is why this is here rather
        // than on a timer somewhere central.
        //
        // Five minutes, not one. Asking Claude costs a `claude` process, which
        // is north of 100MB of Node and about a second of wall clock; at sixty
        // seconds a rail left open all day was two of those a minute, forever,
        // to redraw a ring measuring a five-hour window. Nothing it reports can
        // move enough in five minutes to be worth more than that, and the two
        // things that *do* move it — a turn finishing, the command being
        // changed — already force a refresh of their own.
        .task { usage.refreshAll() }
        .onReceive(Timer.publish(every: 300, on: .main, in: .common).autoconnect()) { _ in
            usage.refreshAll()
        }
    }

    // MARK: Sizing
    //
    // The panel has to know how tall its contents are before there are any, so
    // the numbers live here and `UsageRailWindow` asks. A controller carrying
    // its own copy of a layout constant is how a window ends up half a ring
    // taller than the thing inside it.

    static let width: CGFloat = 76
    private static let inset = Theme.s5
    private static let gap = Theme.s6
    /// A ring, the gap under it, and its caption at `Theme.t1`.
    private static let seatHeight: CGFloat = Self.ring + Theme.s1 + 14
    /// The one number both the ring and the sizing have to agree on.
    static let ring: CGFloat = 34

    static func height(for seats: Int) -> CGFloat {
        let rows = max(1, seats)
        return inset * 2 + CGFloat(rows) * seatHeight + CGFloat(rows - 1) * gap
    }
}

// MARK: - The window it lives in

/// The rail's panel, reconciled from the feature switch.
///
/// Written as a reconciliation rather than as open/close calls, for the reason
/// `PopOut` gives: there is then exactly one path from the state to the window,
/// and every route in — the View menu, the Settings switch, a relaunch with it
/// already on — goes down it.
@MainActor
final class UsageRailWindow: NSObject, NSWindowDelegate {

    static let shared = UsageRailWindow()
    private override init() { super.init() }

    private var panel: NSPanel?

    /// Called on appear and whenever the switch changes.
    func sync() {
        guard Features.isOn(.usageRail) else { return hide() }
        guard panel == nil else { return }
        show()
    }

    private func show() {
        let height = UsageRailView.height(for: Account.enabled.count)
        let panel = RailPanel(
            contentRect: NSRect(x: 0, y: 0, width: UsageRailView.width, height: height),
            // No title bar and nothing to resize: the rail is exactly as big as
            // its rings, and a window you can drag the corner of implies a
            // layout that has more than one right answer.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)

        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        // Transparent *window*, opaque card. The view draws its own rounded
        // surface and the panel is only the rectangle it sits in — which is why
        // the panel is sized to the content rather than left generous: a clear
        // panel is still a panel, and every point of it that isn't the card is
        // a point of the screen that quietly stops taking clicks.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Left to the window, which for a non-opaque one is computed from the
        // content's own alpha and so follows the card's rounded edge. Drawn in
        // SwiftUI instead it would fall outside a panel sized exactly to the
        // card, and be clipped away.
        panel.hasShadow = true
        // Hover is the whole interaction here, and a panel that never sees a
        // moved-mouse event never fires one.
        panel.acceptsMouseMovedEvents = true

        let host = NSHostingView(rootView: UsageRailView())
        host.frame = NSRect(x: 0, y: 0, width: UsageRailView.width, height: height)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        panel.setFrameAutosaveName(Self.frameName)
        if !panel.setFrameUsingName(Self.frameName) { place(panel) }
        panel.delegate = self
        // `orderFrontRegardless`, not `orderFront`: at launch the app may not
        // be the active one, and a plain `orderFront` from an inactive app
        // queues the window until it is.
        panel.orderFrontRegardless()
        self.panel = panel
    }

    /// First run: flush to the right edge, vertically centred.
    ///
    /// Against the edge rather than inset by `Theme.s7` the way `PopOut` places
    /// itself, and that is the one deliberate difference between them. A chat
    /// window is a thing you work in and wants room around it; a rail is a
    /// thing you look at out of the corner of your eye, and everything about
    /// how far you have to move to read it argues for the edge.
    private func place(_ panel: NSPanel) {
        let screen = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: screen.maxX - size.width,
                                     y: screen.midY - size.height / 2))
    }

    private func hide() {
        guard let panel else { return }
        self.panel = nil
        panel.saveFrame(usingName: Self.frameName)
        panel.delegate = nil
        panel.close()
    }

    func windowWillClose(_ notification: Notification) {
        (notification.object as? NSWindow)?.saveFrame(usingName: Self.frameName)
        panel = nil
    }

    private static let frameName = "honeycode.usagerail"
}

/// A borderless panel refuses the keyboard unless it says otherwise, and this
/// one has to have it.
private final class RailPanel: NSPanel {
    /// Key, because hovering a ring has to raise its card and a window that
    /// cannot take the pointer cannot do that. Never main: main window means
    /// the document you are working on, and that is still the real window.
    /// `.nonactivatingPanel` in the style mask is what stops taking the
    /// keyboard here from pulling Honeycode in front of whatever you were
    /// actually looking at.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - The switch

/// The rail's switch, as a menu item.
///
/// Read through `@AppStorage` so the tick follows a change made from the
/// Settings pane, written through `Features.set` so there is one writer. The window itself is not opened
/// here — `RootView` watches the same key and reconciles, which is what keeps
/// the menu, the Settings switch and a relaunch on one path.
struct UsageRailToggle: View {
    @AppStorage(Setup.featureKey(.usageRail), store: Setup.store)
    private var on = Feature.usageRail.initialValue

    var body: some View {
        Toggle("Usage Rail", isOn: Binding(get: { on },
                                           set: { Features.set(.usageRail, $0) }))
            .help(Feature.usageRail.blurb)
    }
}
