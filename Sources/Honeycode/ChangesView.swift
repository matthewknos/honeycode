import SwiftUI

/// Everything a session did to the repo, in one place.
///
/// The question "what has this agent actually changed" is the one you ask
/// before you trust a long session, and until now the only way to answer it was
/// to scroll back through the whole conversation reconstructing it from the
/// diffs as they went past. Every diff is already structured and persisted, so
/// the answer is a regroup rather than new machinery — and it's something a
/// terminal genuinely can't do.
struct FileChange: Identifiable {
    let file: String
    var added = 0
    var removed = 0
    /// Each edit in the order it happened. A file touched four times shows all
    /// four, because "what changed" and "what happened" are different questions
    /// and merging them would answer neither.
    var edits: [[DiffRow]] = []
    /// Whether any edit to this file was refused rather than applied.
    var refused = false

    var id: String { file }
}

enum Changes {
    static func summarise(_ items: [TranscriptItem]) -> [FileChange] {
        var order: [String] = []
        var byFile: [String: FileChange] = [:]

        for item in items {
            guard case .diff(_, _, let file, let rows, let state) = item else { continue }
            if byFile[file] == nil {
                order.append(file)
                byFile[file] = FileChange(file: file)
            }
            byFile[file]?.edits.append(rows)
            // A refused edit still shows — you asked what the agent proposed —
            // but it doesn't count. Adding its rows to the tally made the
            // header state "+120 −40" for changes that were declined and never
            // reached disk, and the same wrong numbers went into the
            // pull-request description.
            if state.isRefused {
                byFile[file]?.refused = true
            } else {
                byFile[file]?.added += rows.count { $0.kind == .add }
                byFile[file]?.removed += rows.count { $0.kind == .del }
            }
        }
        return order.compactMap { byFile[$0] }
    }
}

struct ChangesView: View {
    @ObservedObject var session: Session
    let changes: [FileChange]
    @Binding var isPresented: Bool

    @State private var expanded: Set<String> = []
    @State private var openingPullRequest = false

    private var totalAdded: Int { changes.reduce(0) { $0 + $1.added } }
    private var totalRemoved: Int { changes.reduce(0) { $0 + $1.removed } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.rule)

            if changes.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.s4) {
                        ForEach(changes) { change in
                            row(change)
                        }
                    }
                    .padding(Theme.s6)
                }
            }
        }
        .frame(width: 720, height: 560)
        .sheet(isPresented: $openingPullRequest) {
            PullRequestSheet(session: session, changes: changes,
                             isPresented: $openingPullRequest)
        }
    }

    private var header: some View {
        HStack(spacing: Theme.s5) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Changes")
                    .font(.system(size: 15, weight: .semibold))
                Text(changes.isEmpty
                     ? "Nothing edited in this session"
                     : "\(changes.count) file\(changes.count == 1 ? "" : "s") · "
                       + "+\(totalAdded) −\(totalRemoved)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // This list is already the answer to "what does this change do",
            // which is the question a pull request description exists to
            // answer. Everything downstream of the button is a form you edit
            // before anything is pushed.
            if !changes.isEmpty {
                Button("Pull Request…") { openingPullRequest = true }
            }
            Button("Done") { isPresented = false }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, Theme.s6)
        .padding(.vertical, Theme.s5)
    }

    private var empty: some View {
        VStack(spacing: Theme.s3) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 22))
                .foregroundStyle(.quaternary)
            Text("No files were edited")
                .font(Theme.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ change: FileChange) -> some View {
        let isOpen = expanded.contains(change.file)

        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Motion.disclose) {
                    if isOpen { expanded.remove(change.file) } else { expanded.insert(change.file) }
                }
            } label: {
                HStack(spacing: Theme.s4) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 0 : -90))
                    Text(change.file)
                        .font(Theme.monoSmall)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    if change.refused {
                        Text("declined")
                            .font(Theme.label)
                            .foregroundStyle(Color.diffDelText)
                    }
                    if change.edits.count > 1 {
                        Text("\(change.edits.count) edits")
                            .font(Theme.label)
                            .foregroundStyle(.quaternary)
                    }
                    Spacer(minLength: Theme.s4)
                    HStack(spacing: Theme.s3) {
                        if change.added > 0 {
                            Text("+\(change.added)").foregroundStyle(Color.diffAddText)
                        }
                        if change.removed > 0 {
                            Text("−\(change.removed)").foregroundStyle(Color.diffDelText)
                        }
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .monospacedDigit()

                    FileActionButtons(url: FileActions.resolve(change.file))
                }
                .padding(.horizontal, Theme.s5)
                .padding(.vertical, Theme.s4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                VStack(alignment: .leading, spacing: Theme.s4) {
                    ForEach(Array(change.edits.enumerated()), id: \.offset) { _, rows in
                        FileDiffView(file: change.file, rows: rows, state: .applied)
                    }
                }
                .padding(.horizontal, Theme.s5)
                .padding(.bottom, Theme.s5)
            }
        }
        .modifier(InsetSurface(radius: 10))
    }
}
