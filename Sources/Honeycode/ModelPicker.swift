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
                    .font(Theme.label)
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
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Theme.s5)
                .padding(.top, Theme.s4)
                .padding(.bottom, Theme.s2)
        }
        .padding(.vertical, Theme.s3)
        .frame(width: 268)
        .background {
            PopoutSide(needed: Self.effortWidth + Theme.s7) { side = $0 }
        }
        .popoutSettles(hover, into: $effortFor)
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
            // Remembered for the account, not just for this conversation. This
            // and a `:model` qualifier are the two places a person actually
            // chooses a model, and they are the two that make it stick.
            ModelCatalog.prefer(choice.id, for: session.account)
            showing = false
        }
        .popout(choice, hover: $hover, open: $effortFor, side: side,
                enabled: showsEffort) {
            effortList(for: choice)
        }
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
                    ModelCatalog.prefer(model.id, for: session.account)
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

// The popover rows, headers, menus and button styles that used to live here
// are in Controls.swift. They were never ModelPicker's — this screen was just
// the first to need them.
