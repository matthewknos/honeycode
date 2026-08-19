import Foundation
import Combine

/// The live line under each working delegate.
///
/// Delegates run in parallel for minutes at a time, and before this they
/// printed "working" and then nothing — which makes a thinking agent and a dead
/// one look identical. That isn't only a comfort problem: it's why a delegate
/// that never landed went unnoticed until the code was read.
///
/// A fixed block of lines at the bottom of the screen, rewritten in place. Only
/// when stdout is a terminal — piped into a file, cursor movement is noise, so
/// it degrades to printing each change once.
@MainActor
final class Progress {

    private struct Row {
        let account: Account
        var state: String
        var done = false
    }

    private var rows: [Row] = []
    private var feeds: [AnyCancellable] = []
    private var drawn = 0
    private var ticker: AnyCancellable?
    private let live = isatty(fileno(stdout)) == 1

    /// Long-running work needs to show it's still moving even when nothing has
    /// changed, so the elapsed clock ticks on its own.
    private var startedAt = Date()

    func begin(_ sessions: [(Account, Session)]) {
        // Only the first `begin` of a round starts the clock. One delegate
        // finishing puts the block back up for the rest, and resetting here
        // made the elapsed time jump back to zero each time somebody landed —
        // which is precisely when you're trying to judge how long the stragglers
        // have left.
        if rows.isEmpty { startedAt = Date() }
        rows = sessions.map { Row(account: $0.0, state: "starting") }

        feeds = sessions.map { account, session in
            session.objectWillChange
                .throttle(for: .milliseconds(250), scheduler: RunLoop.main, latest: true)
                .sink { [weak self] in self?.update(account, from: session) }
        }
        if live {
            ticker = Timer.publish(every: 1, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in self?.draw() }
        }
        draw()
    }

    /// Take the block down so something permanent can be printed above it.
    func clear() {
        guard live, drawn > 0 else { drawn = 0; return }
        var out = ""
        for _ in 0..<drawn { out += "\u{1B}[1A\u{1B}[2K" }
        Console.write(out)
        drawn = 0
    }

    func finish(_ account: Account) {
        guard let index = rows.firstIndex(where: { $0.account == account }) else { return }
        rows[index].done = true
        rows[index].state = "done"
    }

    func end() {
        clear()
        feeds = []
        ticker = nil
        rows = []
    }

    private func update(_ account: Account, from session: Session) {
        guard let index = rows.firstIndex(where: { $0.account == account }),
              !rows[index].done else { return }
        rows[index].state = Self.state(of: session)
        draw()
    }

    /// What the agent is doing *now* — the last thing it started, not a summary
    /// of everything it has done.
    private static func state(of session: Session) -> String {
        for item in session.items.reversed() {
            switch item {
            case .tool(_, _, let name, let target, _, _):
                return trim("\(name) \(target)")
            case .diff(_, _, let file, let rows, _):
                return trim("editing \(URL(fileURLWithPath: file).lastPathComponent) (\(rows.count) lines)")
            case .search(_, _, let query, _, _):
                return trim("searching \(query)")
            case .assistant(_, let text) where !text.isEmpty:
                let line = text.components(separatedBy: .newlines)
                    .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
                return trim(line.isEmpty ? "writing" : line)
            case .thinking:
                return "thinking"
            default:
                continue
            }
        }
        return session.isRunning ? "thinking" : "starting"
    }

    private static func trim(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 68 ? String(flat.prefix(67)) + "…" : flat
    }

    private func draw() {
        guard !rows.isEmpty else { return }
        let elapsed = Int(Date().timeIntervalSince(startedAt).rounded())
        guard live else { return }

        var out = ""
        for _ in 0..<drawn { out += "\u{1B}[1A\u{1B}[2K" }
        for row in rows {
            let mark = row.done ? "✓" : "·"
            let name = Console.paint("\(mark) @\(AgentMention.handle(row.account))",
                                     Console.tint(row.account))
            out += "  \(name)  \(Console.dim(row.state))\n"
        }
        out += "  " + Console.dim("\(elapsed)s") + "\n"
        Console.write(out)
        drawn = rows.count + 1
    }
}
