import Foundation

// Moved out of `ChangesView.swift`, which is a SwiftUI file. Neither of these
// types is a view or touches one: `FileChange` is a record and `Changes` is a
// regroup over `TranscriptItem`, which is an engine type. Living in the view
// meant the app's only summary of what an agent changed on disk — including
// the rule that a refused edit shows but doesn't count, which was wrong once —
// could not be reached by a test, because the suites compile AgentKit alone.
//
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
            if state.isDeclined {
                byFile[file]?.refused = true
            } else {
                byFile[file]?.added += rows.count { $0.kind == .add }
                byFile[file]?.removed += rows.count { $0.kind == .del }
            }
        }
        return order.compactMap { byFile[$0] }
    }
}
