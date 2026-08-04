import SwiftUI

/// Model and effort.
///
/// A popover rather than a system `Menu`. `Menu` can only render a flat string
/// per row, so the model's one-line description had to be jammed into the
/// title with an em dash, and the selected state came out as a leading icon
/// instead of a trailing check. A popover costs a little more code and gets the
/// two-line row, the trailing check, and control over spacing.
struct ModelPicker: View {
    @ObservedObject var session: Session
    @State private var showing = false
    /// Which row's effort popout is open, if any.
    @State private var effortFor: AgentModel?
    /// Where the pointer is. Turned into `effortFor` by `HoverPolicy`, after a
    /// pause — see there for why the pause is the entire feature.
    @State private var hover = HoverPolicy<AgentModel>()
    /// Which side the effort panel has room to open on. Drives the popover *and*
    /// the chevron, so the two can't disagree.
    @State private var side: HorizontalEdge = .trailing

    private var showsEffort: Bool { session.account.hasEffort }

    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: Theme.s2 - 1) {
                Text(session.model.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Theme.s4)
            .padding(.vertical, Theme.s2)
            .contentShape(Rectangle())
            // Never wraps. In a narrow composer "Opus 5 High" was breaking a
            // character per line — a label that reflows inside a toolbar is
            // always wrong, so it holds its width and the row sheds other
            // things instead.
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(HoverCapsule())
        .help(showsEffort ? "Model and effort" : "Model")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            content
        }
        // A child popover outlives its parent unless it's told not to: closing
        // the model list would otherwise leave an effort panel floating beside
        // nothing. The hover state goes too, or reopening the list immediately
        // reopens whichever panel was up when it closed.
        .onChange(of: showing) { _, open in
            if !open { effortFor = nil; hover = HoverPolicy() }
        }
    }

    /// Models in wire order, grouped by vendor without resorting them — the
    /// agent's own ordering puts the ones it recommends first, and alphabetising
    /// five vendors would bury that.
    private var groups: [(name: String, models: [AgentModel])] {
        var order: [String] = []
        var buckets: [String: [AgentModel]] = [:]
        for model in session.availableModels {
            if buckets[model.family] == nil { order.append(model.family) }
            buckets[model.family, default: []].append(model)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    /// One list, with a second popover hanging off whichever row you opened.
    ///
    /// Not a page swap inside the same frame. Effort belongs to the model you're
    /// pointing at, and a panel that arrives *beside that row* says so in a way
    /// that replacing the whole popover's contents can't — the same reason the
    /// platform's own submenus open sideways rather than redrawing the menu you
    /// were reading.
    ///
    /// One hit target per row. Clicking picks the model and keeps the effort you
    /// already had; resting on it brings the effort panel out beside it, the way
    /// a submenu does. Nothing about effort needs clicking to *reach*, so the row
    /// keeps a single meaning and the pointer does the rest.
    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Twenty models is taller than any screen wants a popover to be, so
            // the list scrolls.
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(groups, id: \.name) { group in
                        // A single vendor needs no heading — that's every Claude
                        // account, where a lone "Anthropic" label says nothing.
                        if groups.count > 1 {
                            Text(group.name)
                                .font(Theme.label)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, Theme.s5)
                                .padding(.top, Theme.s4)
                                .padding(.bottom, Theme.s2)
                        }
                        ForEach(group.models) { choice in
                            modelRow(choice)
                        }
                    }
                }
            }
            .frame(maxHeight: 340)

            // Changing either is a process relaunch, so say so rather than
            // letting it look like it applied to the turn already running.
            Text("Applies from your next message.")
                .font(.system(size: 10.5))
                .foregroundStyle(.quaternary)
                .padding(.horizontal, Theme.s5)
                .padding(.top, Theme.s4)
                .padding(.bottom, Theme.s2)
        }
        .padding(.vertical, Theme.s3)
        .frame(width: 268)
        .background {
            PopoutSide(needed: Self.effortWidth + Theme.s7) { side = $0 }
        }
        // One timer for the whole list rather than one per row. `task(id:)`
        // cancels the previous run whenever the pointer moves, so sweeping down
        // five models schedules five opens and performs one — the four you
        // passed over are cancelled before their delay is up.
        .task(id: hover) {
            try? await Task.sleep(for: hover.delay)
            guard !Task.isCancelled else { return }
            effortFor = hover.settled(from: effortFor)
        }
    }

    private func modelRow(_ choice: AgentModel) -> some View {
        PopoverRow(title: choice.title,
                   blurb: choice.blurb,
                   selected: session.model.id == choice.id,
                   disclosure: showsEffort ? side : nil) {
            // Clicking takes the model and leaves the effort as it was, so
            // switching model doesn't make you restate a decision you hadn't
            // come here to change.
            session.model = choice
            showing = false
        }
        .onHover { inside in
            guard showsEffort else { return }
            if inside {
                hover.row = choice
            } else if hover.row == choice {
                // Only clear if we're still the row it thinks it's on. Leaving
                // one row and entering the next arrive in an order nobody
                // guarantees, and the exit must not undo the entry that
                // overtook it.
                hover.row = nil
            }
        }
        .popover(isPresented: effortBinding(for: choice),
                 attachmentAnchor: .rect(.bounds),
                 arrowEdge: side == .trailing ? .trailing : .leading) {
            effortList(for: choice)
                .onHover { hover.inPanel = $0 }
        }
    }

    /// One row's popout, open or shut.
    ///
    /// Derived from `effortFor` rather than held per row, because only one may
    /// be open at a time — two effort panels hanging off two different models
    /// would be two answers to a question with one.
    ///
    /// The setter only ever *closes*. Opening is the hover policy's job, and a
    /// popover that dismissed itself would otherwise fight it: SwiftUI writes
    /// `false` here whenever the panel is dismissed for its own reasons, and a
    /// symmetric setter would let that race the pointer.
    private func effortBinding(for model: AgentModel) -> Binding<Bool> {
        Binding(get: { effortFor == model },
                set: { open in if !open, effortFor == model { effortFor = nil } })
    }

    /// Nothing is committed until an effort is picked.
    ///
    /// Selecting the model on the way in would mean dismissing the popout left
    /// you on a model you never chose — and a model change restarts the agent
    /// process, so that's a relaunch for a decision you backed out of.
    private func effortList(for model: AgentModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.title)
                .font(Theme.label)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, Theme.s5)
                .padding(.top, Theme.s3)
                .padding(.bottom, Theme.s3)

            ForEach(EffortChoice.allCases) { choice in
                PopoverRow(title: choice.title,
                           // The check marks what this session is set to. On a
                           // model you haven't chosen yet that's a prediction of
                           // what picking it would give you, which is the useful
                           // thing to show.
                           selected: session.effort == choice) {
                    if session.model.id != model.id { session.model = model }
                    session.effort = choice
                    effortFor = nil
                    showing = false
                }
            }
        }
        .padding(.vertical, Theme.s3)
        .frame(width: Self.effortWidth)
    }

    private static let effortWidth: CGFloat = 190
}

/// Which way a panel of a given width can open from here.
///
/// AppKit already flips a popover that won't fit, and does it well — the problem
/// is that it does so silently, and our own chevron has by then committed to a
/// direction. So the same question is asked ahead of time and both answers come
/// from it.
///
/// Measured against the *screen*, not the window: a popover is its own window
/// and is perfectly happy to hang past the edge of the app.
struct PopoutSide: NSViewRepresentable {
    /// How much room the panel needs, beak and margin included.
    let needed: CGFloat
    let onResolve: (HorizontalEdge) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // Deferred: at `makeNSView` the view has no window yet, so there is
        // nothing to measure against.
        DispatchQueue.main.async { resolve(from: view) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { resolve(from: view) }
    }

    private func resolve(from view: NSView) {
        guard let window = view.window else { return }
        let screen = window.screen ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        onResolve(visible.maxX - window.frame.maxX >= needed ? .trailing : .leading)
    }
}

/// When a hover should open a submenu, and when it should let one go.
///
/// A type of its own because it is the whole of the difficult part, and because
/// buried in a view it can only ever be checked by waving a mouse at it.
///
/// The problem every hover submenu has is the *gap*. To reach the panel the
/// pointer must leave the row that opened it, and the row's exit arrives before
/// the panel's entry — so a policy that closed on exit would shut the panel in
/// the moment you set off towards it. Hence two rules:
///
/// - **Leaving a row doesn't close anything for a while.** The delay is longer
///   on the way out than on the way in, which buys the crossing.
/// - **The panel counts as somewhere to be.** While the pointer is inside it,
///   "no row is hovered" means keep what's open rather than close it.
///
/// Opening waits too, for a different reason: sweeping down a list of twenty
/// models shouldn't flash twenty panels. `task(id:)` cancels each pending open
/// as the next row takes over, so only the row you rest on ever opens.
struct HoverPolicy<Row: Equatable>: Equatable {
    /// The row the pointer is over, if any.
    var row: Row?
    /// Whether the pointer is inside the panel a row opened.
    var inPanel: Bool = false

    /// Long enough not to fire while you're passing through, short enough not
    /// to feel like a wait. The exit is slower than the entry on purpose: it's
    /// the budget for crossing the gap.
    var delay: Duration {
        row != nil ? .milliseconds(220) : .milliseconds(260)
    }

    /// What should be open once the delay has passed, given what's open now.
    func settled(from current: Row?) -> Row? {
        if let row { return row }
        // No row. Either the pointer made it to the panel — in which case the
        // panel stays — or it left altogether.
        return inPanel ? current : nil
    }
}

/// One row of a picker popover: two lines, trailing check, hover fill.
///
/// Shared by the model and transcript pickers. They're the same control doing
/// the same job in the same rail, and two hand-maintained copies of a row is
/// how two controls that should match stop matching.
struct PopoverRow: View {
    let title: String
    var blurb: String?
    var selected: Bool = false
    /// Destructive rows are tinted, the way a system menu tints them — the
    /// only visual difference a delete row gets, and enough.
    var destructive: Bool = false
    /// A chevron marking a row that has more behind it, on the side that more
    /// actually appears.
    ///
    /// Drawn inside the row rather than as its own button. The row has one hit
    /// area and one meaning — click to choose — and the further choice arrives
    /// on hover, so a second target here would be a target for something that
    /// doesn't need clicking.
    ///
    /// The side is passed in because the panel's side isn't ours to decide: it
    /// goes wherever there's room. An arrow pointing right at a panel that
    /// opened left is the kind of small wrongness that makes a window feel
    /// unfinished.
    var disclosure: HorizontalEdge?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.s4) {
                if disclosure == .leading { chevron("chevron.left") }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13))
                        .foregroundStyle(destructive ? AnyShapeStyle(Color.diffDelText)
                                                     : AnyShapeStyle(.primary))
                    if let blurb, !blurb.isEmpty {
                        Text(blurb)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: Theme.s4)
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(selected ? 1 : 0)
                if disclosure == .trailing { chevron("chevron.right") }
            }
            .padding(.horizontal, Theme.s5)
            .padding(.vertical, Theme.s3)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRow())
    }

    private func chevron(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
    }
}

/// How much of the transcript to show.
///
/// Deliberately the same popover as the model picker rather than a system
/// menu: they sit feet apart doing the same kind of job, and each mode needs a
/// line of explanation that a menu row can't carry.
struct TranscriptModePicker: View {
    @Binding var mode: TranscriptMode
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: Theme.s2 - 1) {
                Text(mode.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Theme.s4)
            .padding(.vertical, Theme.s2)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverCapsule())
        .help("Transcript detail")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Detail")
                    .font(Theme.label)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, Theme.s5)
                    .padding(.top, Theme.s3)
                    .padding(.bottom, Theme.s3)

                ForEach(TranscriptMode.allCases) { option in
                    PopoverRow(title: option.title,
                               blurb: option.blurb,
                               selected: mode == option) {
                        mode = option
                        showing = false
                    }
                }
            }
            .padding(.vertical, Theme.s3)
            .frame(width: 248)
        }
    }
}

/// Row highlight on hover — the thing a system menu gives you for free and a
/// custom popover doesn't.
struct HoverRow: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(hovering ? Theme.well : .clear)
            // This was the one hover fill with no animation at all, so popover
            // rows snapped while every other control eased.
            .animation(Motion.hover, value: hovering)
            .onHover { hovering = $0 }
    }
}

/// Sidebar footer row — a rounded hover fill matching the list's own selection
/// shape, so it reads as part of the source list rather than a button bolted
/// underneath it.
struct SidebarFooterButton: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(hovering || configuration.isPressed ? Theme.well : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .animation(Motion.hover, value: hovering)
            .onHover { hovering = $0 }
    }
}

/// Small circular/capsule hover fill for the composer's rail buttons.
struct HoverCapsule: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(hovering || configuration.isPressed ? Theme.well : .clear,
                        in: Capsule())
            .animation(Motion.hover, value: hovering)
            .onHover { hovering = $0 }
    }
}

/// One entry in a `PopoverMenu`.
struct PopoverChoice: Identifiable {
    let title: String
    var blurb: String?
    var selected = false
    var destructive = false
    let action: () -> Void

    var id: String { title }
}

/// A dropdown that matches the model picker.
///
/// System `Menu` was used for the sidebar's new-session button and each row's
/// ⋯, and next to the composer's popovers they looked like two different apps —
/// flat single-line rows, a different corner radius, no room for the line of
/// explanation the other pickers all carry. One control, one look.
struct PopoverMenu<Label: View>: View {
    var header: String?
    var width: CGFloat = 240
    let choices: [PopoverChoice]
    @ViewBuilder var label: Label

    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: { label }
            .buttonStyle(.plain)
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 0) {
                    if let header {
                        Text(header)
                            .font(Theme.label)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, Theme.s5)
                            .padding(.top, Theme.s2)
                            .padding(.bottom, Theme.s3)
                    }
                    ForEach(choices) { choice in
                        PopoverRow(title: choice.title,
                                   blurb: choice.blurb,
                                   selected: choice.selected,
                                   destructive: choice.destructive) {
                            showing = false
                            choice.action()
                        }
                    }
                }
                .padding(.vertical, Theme.s3)
                .frame(width: width)
            }
    }
}
