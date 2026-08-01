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
    /// Drops the effort label. The menu still offers it — this is about the
    /// trigger fitting, not about taking the control away.
    var compact = false
    @State private var showing = false

    /// ACP has no reasoning-effort concept, so offering the control on a Copilot
    /// session would be a switch wired to nothing.
    private var showsEffort: Bool { session.account != .copilot }

    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: Theme.s2 - 1) {
                Text(session.model.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                if showsEffort && !compact {
                    Text(session.effort.title)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                }
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
        .help("Model and effort")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            content
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

    private var content: some View {
        // Twenty models is taller than any screen wants a popover to be, so the
        // list scrolls and the effort control below it stays pinned in view.
        VStack(alignment: .leading, spacing: 0) {
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
                            row(title: choice.title,
                                blurb: choice.blurb,
                                selected: session.model.id == choice.id) {
                                session.model = choice
                                showing = false
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 340)

            if showsEffort {
                Divider()
                    .overlay(Theme.rule)
                    .padding(.vertical, Theme.s2)

                Text("Effort")
                    .font(Theme.label)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, Theme.s5)
                    .padding(.top, Theme.s2)
                    .padding(.bottom, Theme.s3)

                ForEach(EffortChoice.allCases) { choice in
                    row(title: choice.title,
                        blurb: nil,
                        selected: session.effort == choice) {
                        session.effort = choice
                        showing = false
                    }
                }
            }

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
    }

    private func row(title: String, blurb: String?,
                     selected: Bool, action: @escaping () -> Void) -> some View {
        PopoverRow(title: title, blurb: blurb, selected: selected, action: action)
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.s4) {
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
            }
            .padding(.horizontal, Theme.s5)
            .padding(.vertical, Theme.s3)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRow())
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
