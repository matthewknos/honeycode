import SwiftUI

struct Todo: Identifiable, Codable, Sendable, Equatable {
    enum Status: String, Codable { case pending, in_progress, completed, deleted }

    let id: String
    var subject: String
    /// Present-continuous form ("Running tests"), shown while in progress.
    var activeForm: String?
    var status: Status

    var label: String {
        status == .in_progress ? (activeForm ?? subject) : subject
    }
}

/// The agent's plan, as one live card.
///
/// Unlike every other element in the transcript this is *mutable* — it's
/// inserted once, at the point the agent first commits to a plan, and updated
/// in place as tasks progress. Appending a fresh card per `TaskUpdate` would
/// bury the transcript in near-identical lists.
struct TodoListView: View {
    let todos: [Todo]
    @State private var collapsed = false

    private var visible: [Todo] { todos.filter { $0.status != .deleted } }
    private var done: Int { visible.filter { $0.status == .completed }.count }
    private var allDone: Bool { !visible.isEmpty && done == visible.count }
    private var running: Bool { visible.contains { $0.status == .in_progress } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !collapsed { list }
        }
        .animation(Motion.disclose, value: collapsed)
        .animation(Motion.disclose, value: done)
    }

    private var header: some View {
        Button { withAnimation(Motion.disclose) { collapsed.toggle() } } label: {
            HStack(spacing: 7) {
                headerIcon
                    .frame(width: 14, height: 14)
                Text("To-dos")
                    .font(Theme.label)
                Text("\(done)/\(visible.count)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    // The system's own numeric transition rolls the digits;
                    // hand-rolled digit animation is a lot of code for
                    // something AppKit already does better.
                    .contentTransition(.numericText())
                    .foregroundStyle(.quaternary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.tertiary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var headerIcon: some View {
        if allDone {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.diffAddText)
        } else if running {
            // A progress ring rather than a spinner: the work has a known
            // denominator, so showing indeterminate motion throws information
            // away.
            ZStack {
                Circle()
                    .stroke(Theme.rule, lineWidth: 2)
                Circle()
                    .trim(from: 0, to: visible.isEmpty ? 0 : CGFloat(done) / CGFloat(visible.count))
                    .stroke(Color.secondary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 11, height: 11)
        } else {
            Image(systemName: "list.bullet")
                .font(.system(size: 11))
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(visible) { todo in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: symbol(todo.status))
                        .font(.system(size: 11))
                        .foregroundStyle(tint(todo.status))
                        .frame(width: 13)
                    Text(todo.label)
                        .font(.system(size: 12.5))
                        .foregroundStyle(todo.status == .completed
                                         ? AnyShapeStyle(.quaternary)
                                         : todo.status == .in_progress
                                            ? AnyShapeStyle(.primary)
                                            : AnyShapeStyle(.secondary))
                        .strikethrough(todo.status == .completed, color: .secondary.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.top, 7)
        .padding(.leading, 2)
    }

    private func symbol(_ status: Todo.Status) -> String {
        switch status {
        case .completed:   return "checkmark.circle"
        case .in_progress: return "arrow.right.circle"
        default:           return "circle.dotted"
        }
    }

    private func tint(_ status: Todo.Status) -> AnyShapeStyle {
        switch status {
        case .completed:   return AnyShapeStyle(Color.diffAddText.opacity(0.8))
        case .in_progress: return AnyShapeStyle(.secondary)
        default:           return AnyShapeStyle(.quaternary)
        }
    }
}
