import SwiftUI

/// The popover and button kit the whole app is built from.
///
/// Every one of these lived in `ModelPicker.swift`, which is where the first
/// one was needed and not where any of them belong. `HoverCapsule` is used in
/// ten other files; `PopoverRow`, `PopoverHeader`, `PopoverMenu` and
/// `SidebarFooterButton` in most of the rest. A shared control kit filed under
/// the name of the first screen that wanted it is a kit nobody finds — and the
/// cost is not hypothetical: the team popover was written with hand-rolled rows
/// because its author never thought to look inside a model picker for them.
///
/// `Chrome.swift` is the sibling of this file and the division is by what the
/// thing *is*: surfaces, window furniture and environment keys there, controls
/// you click here.

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

/// The wiring `HoverPolicy` needs to actually drive a submenu.
///
/// The policy is the hard part and was already shared; these are the four
/// pieces of plumbing around it, which weren't. The model picker and the
/// handoff menu had them copied out verbatim modulo the row type — and the
/// bugs this plumbing exists to prevent are all invisible ones you find by
/// waving a mouse, so two hand-maintained copies is two places to regress
/// silently and no way to notice.
extension View {

    /// The settle timer, applied to the panel that holds the rows.
    ///
    /// One timer for the whole list rather than one per row. `task(id:)`
    /// cancels the previous run whenever the pointer moves, so sweeping down
    /// five rows schedules five opens and performs one — the four you passed
    /// over are cancelled before their delay is up.
    func popoutSettles<Row: Equatable>(_ hover: HoverPolicy<Row>,
                                       into open: Binding<Row?>) -> some View {
        task(id: hover) {
            try? await Task.sleep(for: hover.delay)
            guard !Task.isCancelled else { return }
            open.wrappedValue = hover.settled(from: open.wrappedValue)
        }
    }

    /// One row of such a list: reports its own hover, and carries the panel it
    /// opens.
    ///
    /// - Parameters:
    ///   - value: what this row stands for, and what `open` holds when this
    ///     row's panel is the one showing.
    ///   - enabled: false for a list whose rows have nothing behind them, which
    ///     is the model picker on an account with no effort levels.
    func popout<Row: Equatable, Panel: View>(
        _ value: Row,
        hover: Binding<HoverPolicy<Row>>,
        open: Binding<Row?>,
        side: HorizontalEdge,
        enabled: Bool = true,
        @ViewBuilder panel: @escaping () -> Panel
    ) -> some View {
        onHover { inside in
            guard enabled else { return }
            if inside {
                hover.wrappedValue.row = value
            } else if hover.wrappedValue.row == value {
                // Only clear if we're still the row it thinks it's on. Leaving
                // one row and entering the next arrive in an order nobody
                // guarantees, and the exit must not undo the entry that
                // overtook it.
                hover.wrappedValue.row = nil
            }
        }
        // Derived rather than held per row, because only one panel may be open
        // at a time — two hanging off two different rows would be two answers
        // to a question with one.
        //
        // The setter only ever *closes*. Opening is the hover policy's job, and
        // a popover that dismissed itself would otherwise fight it: SwiftUI
        // writes `false` here whenever the panel goes away for its own reasons,
        // and a symmetric setter would let that race the pointer.
        .popover(isPresented: Binding(get: { open.wrappedValue == value },
                                      set: { shown in
                                          if !shown, open.wrappedValue == value {
                                              open.wrappedValue = nil
                                          }
                                      }),
                 attachmentAnchor: .rect(.bounds),
                 arrowEdge: side == .trailing ? .trailing : .leading) {
            panel()
                // The panel counts as somewhere to be — see `HoverPolicy`.
                .onHover { hover.wrappedValue.inPanel = $0 }
        }
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
                VStack(alignment: .leading, spacing: Theme.s1) {
                    Text(title)
                        .font(Theme.sidebarRow)
                        .foregroundStyle(destructive ? AnyShapeStyle(Color.diffDelText)
                                                     : AnyShapeStyle(.primary))
                    if let blurb, !blurb.isEmpty {
                        Text(blurb)
                            .font(Theme.note)
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
    /// Standing selected, as opposed to momentarily hovered. The footer's
    /// Settings row now *goes* somewhere — the pane — so it has to be able to
    /// say it is the thing on screen, which a hover fill cannot: let go of the
    /// pointer and a row that is still the current place stops looking like it.
    var selected = false

    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let filled = selected || hovering || configuration.isPressed
        return configuration.label
            .background(filled ? Theme.well : .clear,
                        in: RoundedRectangle(cornerRadius: Theme.cornerChip))
            .animation(Motion.hover, value: hovering)
            .animation(Motion.hover, value: selected)
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

/// The tertiary caption above a run of popover rows — one view, so the
/// headers in every popover match.
struct PopoverHeader: View {
    let text: String
    /// Zero where the container's own padding already clears the top.
    var top: CGFloat = Theme.s2

    init(_ text: String, top: CGFloat = Theme.s2) {
        self.text = text
        self.top = top
    }

    var body: some View {
        Text(text)
            .font(Theme.label)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, Theme.s5)
            .padding(.top, top)
            .padding(.bottom, Theme.s3)
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
                        PopoverHeader(header)
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

/// The account identity dot.
///
/// `HeaderBar` states the rule it exists to keep: "Identity is the dot, and
/// only ever the dot. Everything else in this bar that carries colour carries a
/// *state* colour — so the two can never be confused." Twenty-eight call sites
/// wrote `Circle().fill(account.accent).frame(width:height:)` out by hand, at
/// four different sizes, and three files disagreed with themselves.
///
/// The `hollow` variant is not decoration either: a ring means the thing is
/// real but provisional — a session that hasn't been kept, an agent that only
/// runs when you ask it to. The sidebar and the agents list had both invented
/// it separately, with the same 1.5pt stroke, which is a strong hint it wanted
/// to be one thing.
struct AccountDot: View {
    let colour: Color
    /// A ring rather than a fill: real, but provisional.
    var hollow = false
    /// Not ready, not enabled, not going anywhere by itself.
    var dimmed: Double = 1
    var size: CGFloat = Theme.dot
    /// Some rows centre the dot in a fixed gutter so their text lines up
    /// whether or not there is one. Nil leaves the dot its own width.
    var gutter: CGFloat?

    var body: some View {
        Group {
            if hollow {
                Circle().strokeBorder(colour, lineWidth: 1.5)
            } else {
                Circle().fill(colour)
            }
        }
        .frame(width: size, height: size)
        .opacity(dimmed)
        .frame(width: gutter, alignment: .center)
    }
}

extension AccountDot {
    init(_ account: Account, hollow: Bool = false, dimmed: Double = 1,
         size: CGFloat = Theme.dot, gutter: CGFloat? = nil) {
        self.init(colour: account.accent, hollow: hollow, dimmed: dimmed,
                  size: size, gutter: gutter)
    }
}
