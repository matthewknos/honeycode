import Foundation

/// How a run of scrollback text is meant to read.
///
/// Semantic rather than a colour, because there are two clients with two
/// palettes: `ai` maps these to ANSI codes and Honeycode's coding mode maps
/// them to `NSColor`s. Naming the *role* is what lets one renderer serve both —
/// the alternative is the formatting living twice and drifting, which is what
/// this file was extracted to end.
enum ScrollbackStyle: Sendable {
    /// The agent's own words.
    case prose
    /// What you typed, echoed back.
    case prompt
    /// `▸ claude-p` — who is about to speak.
    case speaker
    /// A tool line.
    case activity
    /// Secondary text: tool output, reasoning, elisions.
    case detail
    case added
    case removed
    case failure
    /// Something the app is telling you, not the agent.
    case notice
}

/// A span of text and how to draw it — the unit both clients append.
///
/// Text is carried verbatim, newlines included, so a client only ever has to
/// concatenate. Nothing here knows about line wrapping, widths or cursors:
/// a scrollback is an append-only stream of bytes with attributes, and the
/// moment it becomes anything cleverer it stops being fast.
struct ScrollbackRun: Sendable {
    let text: String
    let style: ScrollbackStyle
}

/// What a given client wants to see. The two presets are at the bottom.
struct ScrollbackOptions: Sendable {
    /// Echo your own messages.
    ///
    /// The CLI doesn't: you typed them a second ago and they are still on
    /// screen above the prompt. The app does, because a pane you scroll back
    /// through has to say what was asked as well as what came back.
    var showsPrompts = false
    var showsReasoning = false
    var showsActivity = true
    /// The body of an edit rather than a one-line summary of it.
    var showsDiffs = false
    /// A tool's output, once it has any.
    var showsToolOutput = false
    /// `▸ claude-p` before the first reply. Worth it when four accounts share
    /// one stream; noise when the whole pane is a single session.
    var speaker: String?
    /// How many lines of a diff or a tool result to show before eliding. A
    /// terminal that dumps a 900-line diff has buried the reply that follows it.
    var bodyLimit = 40

    /// `ai`: several accounts in one stream, no echo, one-line tool notes.
    static func cli(speaker: String) -> ScrollbackOptions {
        ScrollbackOptions(speaker: speaker)
    }

    /// Honeycode's coding mode, derived from the transcript detail setting the
    /// rest of the app already has. One session per pane, so no speaker label.
    static func pane(_ mode: TranscriptMode) -> ScrollbackOptions {
        ScrollbackOptions(showsPrompts: true,
                          showsReasoning: mode.showsReasoning,
                          showsActivity: mode.showsActivity,
                          showsDiffs: mode.showsActivity,
                          showsToolOutput: mode.expandsDetail,
                          speaker: nil)
    }
}

/// Turns a transcript into an append-only stream of styled text.
///
/// The transcript is an array the adapters mutate in place, so "what is new"
/// isn't handed to us — it has to be worked out. This keeps a high-water mark
/// per item and returns only the tail, which is the whole reason a client can
/// draw a streaming reply in time proportional to the delta rather than to the
/// conversation.
///
/// That distinction is the point of coding mode. The SwiftUI transcript
/// re-evaluates every row for every delta — sixty times a second, over a stack
/// that is eager by necessity — so its cost grows with the length of the
/// session. This grows with the length of the *token*.
final class Scrollback {

    private let options: ScrollbackOptions

    /// UTF-8 bytes already emitted, per item.
    ///
    /// Bytes and not Characters: `String.count` walks every grapheme, and this
    /// runs over every item of the transcript on every tick. `utf8.count` is
    /// O(1), which makes a settled paragraph free to skip — only the one item
    /// still growing pays to be measured. The offsets are safe to cut on
    /// because `DeltaCoalescer` slices its backlog by Character, so an append
    /// never lands mid-scalar.
    private var printed: [UUID: Int] = [:]
    /// Items whose first byte has been written, so the blank line that opens a
    /// block is written once rather than per delta.
    private var started: Set<UUID> = []
    /// Rows announced with a line of their own.
    private var announced: Set<UUID> = []
    /// Rows whose body — a diff, a tool result — has been written.
    private var bodied: Set<UUID> = []
    /// Failures reported, so one failing tool prints one line.
    private var failed: Set<UUID> = []
    /// Statuses last seen, so a plan reports what changed rather than
    /// reprinting itself a dozen times a turn.
    private var todoStatus: [String: Todo.Status] = [:]
    private var openedSpeaker = false
    /// Whether the last thing written was a tool line or its body. See
    /// `activity`.
    private var lastWasActivity = false

    /// Newlines currently at the end of the stream. Two means there is already
    /// a blank line and `blank()` has nothing to do. Starts at two so the very
    /// first block doesn't open with a leading gap.
    private var trailingNewlines = 2
    private var out: [ScrollbackRun] = []

    init(_ options: ScrollbackOptions) {
        self.options = options
    }

    /// Treat everything currently in the transcript as already emitted.
    ///
    /// For attaching to a session that has spoken before. Without it, joining
    /// a running conversation replays the whole thing — which for `ai` meant a
    /// lead's assembly turn reprinting its own planning prose, and for a pane
    /// would mean the scrollback doubling every time you switched to it.
    func catchUp(items: [TranscriptItem], todos: [Todo] = []) {
        for item in items {
            switch item {
            case .user(let id, _), .notice(let id, _), .compaction(let id, _, _),
                 .todos(let id):
                announced.insert(id)
            case .assistant(let id, let text), .opinion(let id, _, let text, _):
                printed[id] = text.utf8.count
                started.insert(id)
            case .thinking(let id, let text, _, _):
                printed[id] = text.utf8.count
                started.insert(id)
            case .tool(let id, _, _, _, _, _), .search(let id, _, _, _, _):
                announced.insert(id); bodied.insert(id); failed.insert(id)
            case .diff(let id, _, _, _, _):
                announced.insert(id); bodied.insert(id); failed.insert(id)
            }
        }
        for todo in todos { todoStatus[todo.id] = todo.status }
    }

    /// Everything that has appeared since the last call.
    ///
    /// Returns an empty array when nothing has — which is the common case, and
    /// is what lets a client tick at 60Hz without doing any work.
    func drain(items: [TranscriptItem], todos: [Todo] = []) -> [ScrollbackRun] {
        out.removeAll(keepingCapacity: true)

        for item in items {
            switch item {
            case .user(let id, let text):
                guard options.showsPrompts, announced.insert(id).inserted else { continue }
                blank()
                lastWasActivity = false
                for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                    write("› " + line + "\n", .prompt)
                }

            case .assistant(let id, let text):
                emit(id: id, text: text, style: .prose) { self.openSpeaker() }

            case .thinking(let id, let text, _, _):
                guard options.showsReasoning else { continue }
                emit(id: id, text: text, style: .detail) {}

            case .opinion(let id, let agent, let text, _):
                // Always labelled, whatever the speaker setting: the whole
                // point of a second opinion is that it wasn't the agent above.
                emit(id: id, text: text, style: .prose) {
                    self.write("▸ " + agent + "\n", .speaker)
                }

            case .tool(let id, _, let name, let target, let detail, let state):
                activity(id: id, "\(name)  \(target)", state)
                body(id: id, state: state) { self.output(detail) }

            case .diff(let id, _, let file, let rows, let state):
                activity(id: id, "Edit  \(file)", state)
                body(id: id, state: state) { self.diff(rows) }

            case .search(let id, _, let query, let results, let state):
                activity(id: id, "Search  \(query)", state)
                body(id: id, state: state) {
                    guard self.options.showsToolOutput else { return }
                    for result in results.prefix(self.options.bodyLimit) {
                        self.write("      " + result.title + "\n", .detail)
                    }
                }

            case .notice(let id, let text):
                guard options.showsActivity, announced.insert(id).inserted else { continue }
                blank()
                write("  " + text + "\n", .notice)

            case .compaction(let id, let trigger, let dropped):
                guard announced.insert(id).inserted else { continue }
                blank()
                write("  — compacted (\(trigger)): \(dropped) message"
                      + (dropped == 1 ? "" : "s") + " dropped —\n", .notice)

            case .todos:
                continue
            }
        }

        plan(todos)
        return out
    }

    // MARK: Items

    /// `header` runs once, after the opening blank line and before the first
    /// byte of the block — never per delta.
    private func emit(id: UUID, text: String, style: ScrollbackStyle,
                      header: () -> Void) {
        let length = text.utf8.count
        let already = printed[id] ?? 0
        guard length > already else { return }

        if started.insert(id).inserted {
            blank()
            header()
        }
        lastWasActivity = false
        printed[id] = length
        write(tail(of: text, from: already), style)
    }

    /// The bytes after `offset`, as a string.
    ///
    /// Written out rather than `dropFirst`, which on a `UTF8View` walks from
    /// the start: this indexes from the end instead, so the work is the size of
    /// the delta and not the size of the reply so far. The difference shows up
    /// as a reply that streams at the same speed on its thousandth word as its
    /// tenth.
    private func tail(of text: String, from offset: Int) -> String {
        let bytes = text.utf8
        let count = bytes.count - offset
        guard count > 0 else { return "" }
        guard offset > 0 else { return text }
        let start = bytes.index(bytes.endIndex, offsetBy: -count)
        return String(decoding: bytes[start...], as: UTF8.self)
    }

    /// One line per tool, the first time it's seen.
    ///
    /// The state it *ends* in is what matters, but waiting for that would leave
    /// a long build silent — so it prints on sight and only a failure is worth
    /// a second line. This is the one place a scrollback is poorer than a card,
    /// and it is the trade the whole mode is making.
    private func activity(id: UUID, _ label: String, _ state: ToolState) {
        guard options.showsActivity else { return }
        if announced.insert(id).inserted {
            // A run of tool calls is one movement and packs tight; the gap
            // belongs between the prose and the work, not between the eighth
            // grep and the ninth.
            if lastWasActivity { breakLine() } else { blank() }
            write("⏺ " + label + "\n", .activity)
            lastWasActivity = true
        }
        if case .failed(let message) = state, failed.insert(id).inserted {
            write("  ! " + (message.isEmpty ? "\(label) failed" : message) + "\n", .failure)
        }
        if case .declined(let message) = state, failed.insert(id).inserted {
            write("  ⨯ " + (message.isEmpty ? "declined" : message) + "\n", .detail)
        }
    }

    /// A tool's body, written once, when the tool has stopped moving.
    ///
    /// Held until then because `detail` and `rows` are filled from the result
    /// rather than streamed — emitting on sight would print an empty block and
    /// have nowhere to put the real one.
    private func body(id: UUID, state: ToolState, _ write: () -> Void) {
        guard options.showsActivity, state != .pending, bodied.insert(id).inserted else { return }
        write()
    }

    private func output(_ detail: String) {
        guard options.showsToolOutput, !detail.isEmpty else { return }
        let lines = detail.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines.prefix(options.bodyLimit) {
            write("      " + line + "\n", .detail)
        }
        if lines.count > options.bodyLimit {
            write("      … \(lines.count - options.bodyLimit) more lines\n", .detail)
        }
    }

    private func diff(_ rows: [DiffRow]) {
        guard options.showsDiffs else { return }
        // A file that ends in a newline produces a final empty context row.
        // As a card that's an invisible nothing; as a line of scrollback it's
        // a stray run of spaces under the last change.
        var rows = rows
        while let last = rows.last, last.kind == .context, last.text.isEmpty {
            rows.removeLast()
        }
        guard !rows.isEmpty else { return }
        for row in rows.prefix(options.bodyLimit) {
            switch row.kind {
            case .add:     write("    + " + row.text + "\n", .added)
            case .del:     write("    - " + row.text + "\n", .removed)
            case .context: write("      " + row.text + "\n", .detail)
            }
        }
        if rows.count > options.bodyLimit {
            write("      … \(rows.count - options.bodyLimit) more lines\n", .detail)
        }
    }

    /// What changed in the plan, not the plan.
    ///
    /// A todo list is mutated in place several times a turn, so reprinting it
    /// whole on each update buries the reply under a dozen near-identical
    /// copies of itself. A scrollback wants the transitions.
    private func plan(_ todos: [Todo]) {
        guard options.showsActivity else { return }
        // A plan update can land mid-sentence — the model marks a step done
        // between two deltas of the paragraph describing it.
        var opened = false
        for todo in todos {
            let was = todoStatus[todo.id]
            guard was != todo.status else { continue }
            todoStatus[todo.id] = todo.status
            // A plan arriving fully-formed announces only what's underway;
            // listing four pending items as four events is not news.
            guard was != nil || todo.status == .in_progress else { continue }
            if !opened { breakLine(); opened = true }
            switch todo.status {
            case .in_progress: write("  ▸ " + todo.label + "\n", .detail)
            case .completed:   write("  ✓ " + todo.subject + "\n", .detail)
            case .pending, .deleted: continue
            }
        }
    }

    // MARK: Line discipline

    private func openSpeaker() {
        guard let speaker = options.speaker, !openedSpeaker else { return }
        openedSpeaker = true
        write("▸ " + speaker + "\n", .speaker)
    }

    private func write(_ text: String, _ style: ScrollbackStyle) {
        guard !text.isEmpty else { return }
        out.append(ScrollbackRun(text: text, style: style))

        var newlines = 0
        for character in text.reversed() {
            guard character == "\n" else { break }
            newlines += 1
        }
        trailingNewlines = newlines == text.count ? trailingNewlines + newlines : newlines
    }

    /// End the current line, wherever the model happened to stop.
    private func breakLine() {
        if trailingNewlines == 0 { write("\n", .prose) }
    }

    /// One blank line before a block, and never two.
    private func blank() {
        breakLine()
        if trailingNewlines < 2 { write("\n", .prose) }
    }
}
