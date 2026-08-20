// What a session actually changed on disk.
//
// This logic could not be tested until it was moved: it lived in
// `ChangesView.swift`, a SwiftUI file, and the suites compile AgentKit alone.
// It is worth testing because it has been wrong once in a way that reached two
// surfaces at the same time — a refused edit was counted in the tally, so the
// Changes header read "+120 −40" for edits that were declined and never
// reached disk, and those same numbers went into the pull-request description
// offered to a human reviewer.
//
// The rule it has to hold is narrow and easy to get backwards: a refused edit
// is *shown*, because you asked what the agent proposed, and *not counted*,
// because it didn't happen.

import Foundation

var failures = 0
func check(_ label: String, _ ok: Bool) {
    print((ok ? "  ok   " : "  FAIL ") + label)
    if !ok { failures += 1 }
}

func rows(add: Int, del: Int) -> [DiffRow] {
    (0..<add).map { DiffRow(old: nil, new: $0, kind: .add, text: "+\($0)") }
    + (0..<del).map { DiffRow(old: $0, new: nil, kind: .del, text: "-\($0)") }
    + [DiffRow(old: 0, new: 0, kind: .context, text: " ")]
}

func edit(_ file: String, add: Int, del: Int, state: ToolState = .applied) -> TranscriptItem {
    .diff(id: UUID(), toolUseID: UUID().uuidString, file: file,
          rows: rows(add: add, del: del), state: state)
}

// --- the ordinary case ---
let simple = Changes.summarise([
    edit("src/a.swift", add: 3, del: 1),
    edit("src/b.swift", add: 10, del: 0),
])
check("one entry per file", simple.count == 2)
check("additions are counted", simple.first?.added == 3)
check("deletions are counted", simple.first?.removed == 1)
check("context lines are not counted as either",
      simple.first.map { $0.added + $0.removed } == 4)

// Order is the order they happened, not alphabetical and not dictionary order —
// the question behind this list is "what did it do", which is a sequence.
let ordered = Changes.summarise([
    edit("z.swift", add: 1, del: 0),
    edit("a.swift", add: 1, del: 0),
    edit("m.swift", add: 1, del: 0),
])
check("files stay in the order they were touched",
      ordered.map(\.file) == ["z.swift", "a.swift", "m.swift"])

// --- a file touched more than once ---
//
// Each edit is kept separately. "What changed" and "what happened" are
// different questions and merging them answers neither.
let repeated = Changes.summarise([
    edit("src/a.swift", add: 2, del: 0),
    edit("src/a.swift", add: 3, del: 4),
])
check("a file touched twice is one entry", repeated.count == 1)
check("with both edits kept", repeated.first?.edits.count == 2)
check("and the tallies summed", repeated.first?.added == 5)
check("across both directions", repeated.first?.removed == 4)

// --- the rule that was wrong once ---
let declined = Changes.summarise([
    edit("src/a.swift", add: 120, del: 40, state: .declined("no")),
])
check("a refused edit is shown", declined.first?.edits.count == 1)
check("and marked as refused", declined.first?.refused == true)
check("and its additions are not counted", declined.first?.added == 0)
check("nor its deletions", declined.first?.removed == 0)

// Refused and applied edits to one file: the tally is the applied ones only,
// and the file still reports that something was refused.
let mixed = Changes.summarise([
    edit("src/a.swift", add: 5, del: 2),
    edit("src/a.swift", add: 100, del: 100, state: .declined("no")),
    edit("src/a.swift", add: 1, del: 0),
])
check("a mixed file counts only what was applied", mixed.first?.added == 6)
check("and only what was applied, deleting too", mixed.first?.removed == 2)
check("but still says something was refused", mixed.first?.refused == true)
check("while showing all three attempts", mixed.first?.edits.count == 3)

// --- the other two states are not refusals ---
//
// `failed` was conflated with `declined` once elsewhere, and the distinction
// matters here for the same reason: a tool that ran and errored did reach the
// disk, and a tool that was blocked did not.
let failed = Changes.summarise([edit("a.swift", add: 4, del: 0, state: .failed("boom"))])
check("a failed edit is not a refusal", failed.first?.refused == false)
check("and is counted", failed.first?.added == 4)

let pending = Changes.summarise([edit("a.swift", add: 4, del: 0, state: .pending)])
check("an edit still in flight is not a refusal", pending.first?.refused == false)

// --- everything that isn't a diff ---
let noise = Changes.summarise([
    .assistant(id: UUID(), text: "I'll edit src/a.swift now"),
    .notice(id: UUID(), text: "something happened"),
])
check("prose that mentions a file is not a change", noise.isEmpty)
check("nothing at all summarises to nothing", Changes.summarise([]).isEmpty)

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
