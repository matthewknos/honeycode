import SwiftUI
import AppKit

/// The bar across the top of the window.
///
/// New, and the reason it is new is that everything it holds used to be
/// somewhere else *per column*: which conversation you were in was said by
/// three separate `HeaderBar`s at once, the command palette was a keystroke
/// with no visible affordance, and the appearance switch lived four levels down
/// in Settings. None of those are facts about a conversation. They are facts
/// about the window, and a window fact repeated once per column is a window
/// fact you have to check three of to trust one.
///
/// So: one bar, one breadcrumb, one search, one set of window switches. The
/// traffic lights live in it rather than being dodged by everything underneath
/// — see `Chrome.trafficLightWidth`, which had no reason to exist until there
/// was a bar for the lights to sit *in*, and `WindowMode`, which is how the bar
/// knows they have gone.
struct TitleBar: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var background: BackgroundStore
    @Binding var sidebarExpanded: Bool
    @Binding var inspectorShown: Bool
    @Binding var showPalette: Bool
    @Binding var appearance: HoneycodeApp.Appearance

    @ObservedObject private var repo = RepoStatus.shared
    @ObservedObject private var mode = WindowMode.shared

    private var session: Session? { workspace.selected }

    /// Where the bar's content may start.
    ///
    /// The lights' width while they are there, and the sidebar's own margin
    /// while they are not — which is full screen. Aligning on `Theme.s5` rather
    /// than nothing means the mark lines up with SESSIONS directly underneath
    /// it, so the bar reads as the top of the same column rather than as a
    /// separate strip that happens to be indented.
    private var leadingInset: CGFloat {
        mode.lightsHidden ? Theme.s5 : Chrome.trafficLightWidth
    }

    var body: some View {
        HStack(spacing: Theme.s4) {
            // Both flanks are `maxWidth: .infinity`, which is what centres the
            // search field in the *window* rather than in whatever is left over
            // after the breadcrumb. A fixed field between two greedy halves is
            // the only arrangement that stays centred as the breadcrumb grows,
            // and the breadcrumb truncates rather than pushing, so it can never
            // shove the field off-centre.
            leading
                .frame(maxWidth: .infinity, alignment: .leading)

            search

            trailing
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.leading, leadingInset)
        .padding(.trailing, Theme.s6)
        .frame(height: Theme.titleBarHeight)
        .background(alignment: .bottom) {
            // A rule under the bar, and nothing behind it. The pane background
            // — a flat canvas or a photograph — runs up under this, which is
            // what keeps the bar part of the window rather than a band stuck on
            // top of it.
            Rectangle().fill(Theme.rule).frame(height: 1)
        }
        .modifier(FollowsRepo(directory: session?.directory
                              ?? URL(fileURLWithPath: NSHomeDirectory())))
        .animation(Motion.reveal, value: session?.id)
        // Entering and leaving full screen is already an animated transition;
        // the bar's contents slide with it rather than jumping 66 points at
        // whatever frame the resize happens to finish on.
        .animation(Motion.panel, value: leadingInset)
    }

    // MARK: What you are looking at

    private var leading: some View {
        HStack(spacing: Theme.s4) {
            Button {
                withAnimation(Motion.panel) { sidebarExpanded.toggle() }
            } label: {
                Image(systemName: "sidebar.leading")
                    .font(.system(size: 13))
                    // The same on/off pair as the inspector's toggle opposite.
                    // They are the same control for the two panels either side
                    // of the pane, and reading "shown" as two different
                    // greys is how one of them looks broken.
                    .foregroundStyle(sidebarExpanded
                                     ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HoverCapsule())
            .help(sidebarExpanded ? "Collapse sidebar" : "Expand sidebar")

            mark

            if let session {
                breadcrumb(session)
            }
        }
    }

    /// The app, named once.
    ///
    /// A hexagon because that is what the name is about, and because the window
    /// otherwise has nowhere at all that says which application this is — the
    /// title was turned off by `WindowChrome` and the Dock icon is not on
    /// screen while you are working.
    private var mark: some View {
        HStack(spacing: Theme.s3) {
            Image(systemName: "hexagon.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.accentColor)
            Text("Honeycode")
                .font(Theme.title)
                .fixedSize()
        }
    }

    /// Account, folder, and whether it is running.
    ///
    /// Deliberately not the session's *name*: the name is in the sidebar row
    /// you clicked and in the pane's own header, and a breadcrumb that repeats
    /// the leaf is a breadcrumb with one useful segment. What it says instead
    /// is the two things nothing else on this line says — which subscription is
    /// paying for this and which folder the agent can reach.
    private func breadcrumb(_ session: Session) -> some View {
        HStack(spacing: Theme.s3) {
            separator
            AccountDot(session.account)
            Text(session.account.shortTitle)
                .font(Theme.row)
                .foregroundStyle(.secondary)
                .fixedSize()

            separator
            Text(session.directory.lastPathComponent)
                .font(Theme.rowStrong)
                .lineLimit(1)
                .truncationMode(.middle)

            if session.isRunning {
                // The same green the sidebar row and the status strip use for
                // the same fact. A breadcrumb is where your eye already is when
                // you switch sessions, so it is worth one dot.
                Circle()
                    .fill(Theme.stateLive)
                    .frame(width: Theme.dot, height: Theme.dot)
                    .transition(.opacity)
            }
        }
        .help(session.subtitle)
        .layoutPriority(-1)
        .animation(Motion.reveal, value: session.isRunning)
    }

    private var separator: some View {
        Text("/")
            .font(Theme.row)
            .foregroundStyle(.quaternary)
    }

    // MARK: One way in to everything

    /// The command palette, given a face.
    ///
    /// It has been ⌘K since it was written and there has never been anything on
    /// screen to say so — which is the whole problem with a palette: it is the
    /// fastest route to every session, file and command in the app, and it is
    /// invisible to anyone who wasn't told. A field you can click is not a
    /// faster way to open it than the shortcut. It is the only way anybody
    /// finds out the shortcut exists.
    private var search: some View {
        Button { showPalette = true } label: {
            HStack(spacing: Theme.s3) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("Search sessions, files, commands…")
                    .font(Theme.note)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: Theme.s4)
                KeyCap(Shortcuts.quickOpen.display)
            }
            .padding(.horizontal, Theme.s4)
            .frame(height: 26)
            .frame(maxWidth: 400)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(FieldSurface(glass: background.isGlassy))
        .help("Search sessions, files and commands (\(Shortcuts.quickOpen.display))")
    }

    // MARK: What the window is set to

    private var trailing: some View {
        HStack(spacing: Theme.s3) {
            if let session { ContextRing(session: session) }

            appearanceButton

            Button {
                withAnimation(Motion.panel) { inspectorShown.toggle() }
            } label: {
                Image(systemName: "sidebar.trailing")
                    .font(.system(size: 12))
                    .foregroundStyle(inspectorShown
                                     ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HoverCapsule())
            .help(inspectorShown ? "Hide the inspector" : "Show the inspector")

            // A control whose whole job is naming the account you are acting as
            // has nothing to name when you are acting as nobody — same test the
            // sidebar footer used to make, moved here with the control.
            if Features.isOn(.gitHub) || Features.isOn(.azure) {
                IdentityMenu(compact: true, arrowEdge: .bottom)
            }
        }
    }

    /// Light, dark, or whatever the Mac is set to — cycled rather than picked.
    ///
    /// Three states and one button, which works because the glyph says the
    /// state rather than the action: a sun means light, a moon means dark, and
    /// the half-filled circle means "follow the system". Its tooltip names what
    /// pressing it will do, which is the half a glyph can't carry.
    private var appearanceButton: some View {
        Button {
            withAnimation(Motion.reveal) { appearance = appearance.next }
        } label: {
            Image(systemName: appearance.symbol)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverCapsule())
        .help("Appearance: \(appearance.title) — click for \(appearance.next.title)")
    }
}

// MARK: - The ring

/// How full the context window is, as a ring you can open.
///
/// The number was a `62% ctx` readout that appeared at sixty per cent and
/// vanished below it, on the theory that a permanent low reading is furniture.
/// That was right about the *text* and wrong about the fact: the reading is
/// also the door to everything else this session has spent, and a door that is
/// only there once you are in trouble is a door nobody knows about. A ring is
/// small enough to be permanent and legible at a glance from across the window,
/// which a two-digit percentage is not.
struct ContextRing: View {
    @ObservedObject var session: Session
    @State private var showing = false

    private var fraction: Double {
        guard let context = session.context, context.window > 0 else { return 0 }
        return min(1, Double(context.used) / Double(context.window))
    }

    private var percent: Int { session.context?.percent ?? 0 }

    /// Whether anything has been measured yet.
    ///
    /// A session that has not had a reply has no window size, so the ring is
    /// empty and the number is unknown — which is not the same as nought. The
    /// popover already says "nothing sent yet"; this is the one-glyph version.
    private var measured: Bool { (session.context?.window ?? 0) > 0 }

    private var tint: Color { ContextRing.tint(percent) }

    /// Green until it matters, amber while it does, red once compaction is
    /// imminent. The same three states `Theme` names everywhere else.
    ///
    /// Static because the inspector and the popover draw the same number as a
    /// bar, and a bar that stays accent-blue while the ring beside it has gone
    /// red is two readouts of one fact disagreeing about how bad it is.
    static func tint(_ percent: Int) -> Color {
        switch percent {
        case ..<75:  return Theme.stateLive
        case ..<90:  return Theme.stateHeld
        default:     return Theme.stateBad
        }
    }

    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: Theme.s2) {
                ZStack {
                    Circle()
                        .stroke(Theme.rule, lineWidth: 2)
                    if measured {
                        Circle()
                            .trim(from: 0, to: max(fraction, 0.001))
                            .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                }
                .frame(width: 12, height: 12)

                Text(!measured ? "—" : (percent < 1 ? "<1%" : "\(percent)%"))
                    .font(Theme.captionStrong)
                    .monospacedDigit()
                    .foregroundStyle(measured ? AnyShapeStyle(.secondary)
                                              : AnyShapeStyle(.tertiary))
            }
            .padding(.horizontal, Theme.s3)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverCapsule())
        .help("What this session has spent")
        .animation(Motion.reveal, value: percent)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            UsagePopover(session: session).frame(width: 288)
        }
    }
}

/// The long form behind the ring.
///
/// Only what Honeycode actually knows. The obvious thing to draw here is the
/// four-way input/cached/reasoning/output split every provider's dashboard
/// shows — but the CLIs report a context total and a window size, not a
/// breakdown, and a stacked bar with three invented segments would be a
/// confident answer to a question nothing has asked the agent. Two segments
/// that are true beat five that are decorative.
private struct UsagePopover: View {
    @ObservedObject var session: Session
    @ObservedObject private var usage = UsageStore.shared

    /// Built once per redraw rather than on each read. `SessionTally` walks the
    /// whole transcript, and `limits` referred to it four times.
    @State private var tally = SessionTally()

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s5) {
            context
            Divider().overlay(Theme.rule)
            limits
        }
        .padding(Theme.s5)
        .onAppear { tally = SessionTally(session) }
        .onChange(of: session.items.count) { _, _ in tally = SessionTally(session) }
    }

    @ViewBuilder
    private var context: some View {
        VStack(alignment: .leading, spacing: Theme.s4) {
            HStack {
                Text("Context window")
                    .font(Theme.title)
                Spacer(minLength: Theme.s4)
                Text(session.context.map { "\($0.percent)%" } ?? "—")
                    .font(Theme.captionStrong)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            if let context = session.context, context.window > 0 {
                let tint = ContextRing.tint(context.percent)
                Meter(fraction: Double(context.used) / Double(context.window),
                      tint: tint)
                Legend(swatch: tint, name: "In context",
                       value: SessionTally.compact(context.used))
                Legend(swatch: Theme.rule, name: "Free space",
                       value: SessionTally.compact(max(0, context.window - context.used)))
            } else {
                Text("Nothing sent yet — the window is measured from the first reply.")
                    .font(Theme.note)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var limits: some View {
        VStack(alignment: .leading, spacing: Theme.s4) {
            HStack {
                Text("This session")
                    .font(Theme.title)
                Spacer(minLength: Theme.s4)
                Text(session.model.title)
                    .font(Theme.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            StatRow(name: "Turns", value: "\(tally.turns)")
            StatRow(name: "Tool calls", value: "\(tally.toolCalls)")
            if let elapsed = tally.elapsed {
                StatRow(name: "Time", value: elapsed)
            }
            if session.tokensSent > 0 {
                StatRow(name: "Sent", value: "≈\(SessionTally.compact(session.tokensSent)) tok")
            }
            if let reading = usage.reading(for: session.account),
               let binding = reading.binding {
                StatRow(name: binding.title, value: "\(binding.percent)%",
                        alarming: binding.pressure.isAlarming)
            } else if session.costUSD > 0 {
                StatRow(name: "Cost", value: SessionTally.money(session.costUSD))
            }
            if let limit = session.rateLimit, limit.isConstrained {
                StatRow(name: limit.windowName,
                        value: limit.resetsAt.map { "resets \(RateLimit.clock.string(from: $0))" }
                            ?? "reached",
                        alarming: limit.status == "rejected")
            }
        }
    }

}

/// A thin filled track. Used by the popover and the inspector, which are
/// drawing the same fact at two sizes.
struct Meter: View {
    let fraction: Double
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.rule)
                Capsule()
                    .fill(tint)
                    .frame(width: max(2, geometry.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 4)
        .animation(Motion.reveal, value: fraction)
    }
}

/// A swatch, a name, and a number — the row a legend is made of.
struct Legend: View {
    let swatch: Color
    let name: String
    let value: String

    var body: some View {
        HStack(spacing: Theme.s3) {
            RoundedRectangle(cornerRadius: 2)
                .fill(swatch)
                .frame(width: 8, height: 8)
            Text(name)
                .font(Theme.row)
                .foregroundStyle(.secondary)
            Spacer(minLength: Theme.s4)
            Text(value)
                .font(Theme.row)
                .monospacedDigit()
        }
    }
}

/// A label and a value on one line, which is most of the inspector.
struct StatRow: View {
    let name: String
    let value: String
    var alarming = false

    var body: some View {
        HStack(spacing: Theme.s4) {
            Text(name)
                .font(Theme.row)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: Theme.s4)
            Text(value)
                .font(Theme.row)
                .monospacedDigit()
                .foregroundStyle(alarming ? AnyShapeStyle(Theme.stateBad)
                                          : AnyShapeStyle(.primary))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

// MARK: - Counting a session

/// Turns, tool calls and elapsed time, counted from the transcript.
///
/// None of these are stored, and none of them need to be: the transcript *is*
/// the record, and walking it is cheaper than keeping three counters correct
/// through edits, retries and a `/clear`. Built fresh where it is read — both
/// readers are inside a popover or a panel that only redraws when it is open.
struct SessionTally {
    var turns = 0
    var toolCalls = 0
    var elapsed: String?

    /// Nothing counted yet — what a panel holds before it has seen a session.
    init() {}

    init(_ session: Session) {
        for item in session.items {
            switch item {
            case .user:                     turns += 1
            case .tool, .diff, .search:     toolCalls += 1
            default:                        break
            }
        }
        // From your first message, not from when the session was created — a
        // conversation restored at launch was opened days ago and has been
        // sitting idle since, and "Time: 3d" is not a fact about the work.
        // `stamps` holds one date per turn *you* sent, so this is a scan of
        // tens of entries rather than of the transcript.
        if let started = session.stamps.values.min() {
            elapsed = Self.duration(Date().timeIntervalSince(started))
        }
    }

    /// 1_234_567 → `1.2M`.
    ///
    /// Lived privately inside `UsageMeter`, which was fine while one readout
    /// used it. Three do now — the ring's popover, the inspector's usage
    /// section and the status strip — and a token count abbreviated three
    /// slightly different ways in one window is the kind of difference nobody
    /// spots and everybody half-notices.
    /// A cost, at the precision the number deserves.
    ///
    /// `%.3f` everywhere gave "$6.442", which reads as a bug rather than as
    /// money. Three places are only worth printing while the total is small
    /// enough that the third one is the difference between "nothing" and "a
    /// bit" — below a pound, in other words.
    static func money(_ usd: Double) -> String {
        String(format: usd < 1 ? "$%.3f" : "$%.2f", usd)
    }

    static func compact(_ value: Int) -> String {
        switch value {
        case 1_000_000...:  return String(format: "%.1fM", Double(value) / 1_000_000)
        case 1_000...:      return String(format: "%.0fk", Double(value) / 1_000)
        default:            return "\(value)"
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        switch whole {
        case ..<60:     return "\(whole)s"
        case ..<3600:   return "\(whole / 60)m \(whole % 60)s"
        default:        return "\(whole / 3600)h \((whole % 3600) / 60)m"
        }
    }
}

// MARK: - Small chrome

/// A keyboard shortcut, drawn as a key.
struct KeyCap: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Theme.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Theme.s2)
            .padding(.vertical, 1)
            .background(Theme.well, in: RoundedRectangle(cornerRadius: 4))
    }
}

/// A control that reads as something you type into.
///
/// The search field and the sidebar's filter are the same shape and want the
/// same treatment on glass, and `RaisedSurface` is the wrong one — it is for
/// things that sit *above* the pane, and draws a shadow to say so. A field is
/// set into its bar.
struct FieldSurface: ViewModifier {
    let glass: Bool
    var radius: CGFloat = Theme.cornerField
    var focused = false

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        if glass {
            content
                .glassy(in: shape)
                .overlay(shape.strokeBorder(
                    focused ? Color.accentColor.opacity(0.55) : .clear, lineWidth: 1))
        } else {
            content
                .background(Theme.well, in: shape)
                .overlay(shape.strokeBorder(
                    focused ? Color.accentColor.opacity(0.5) : Theme.rule, lineWidth: 1))
        }
    }
}
