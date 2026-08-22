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
        let seat: Seat
        var state: String
        var done = false
        /// What it actually changed, once it has landed. `nil` while working.
        var files: Int?
    }

    private var rows: [Row] = []
    private var feeds: [AnyCancellable] = []
    private var drawn = 0
    private var ticker: AnyCancellable?
    private let live = isatty(fileno(stdout)) == 1

    /// Long-running work needs to show it's still moving even when nothing has
    /// changed, so the elapsed clock ticks on its own.
    private var startedAt = Date()

    func begin(_ sessions: [(Seat, Session)]) {
        // Only the first `begin` of a round starts the clock. One delegate
        // finishing puts the block back up for the rest, and resetting here
        // made the elapsed time jump back to zero each time somebody landed —
        // which is precisely when you're trying to judge how long the stragglers
        // have left.
        if rows.isEmpty { startedAt = Date() }
        rows = sessions.map { Row(seat: $0.0, state: "starting") }

        feeds = sessions.map { seat, session in
            session.objectWillChange
                .throttle(for: .milliseconds(250), scheduler: RunLoop.main, latest: true)
                .sink { [weak self] in self?.update(seat, from: session) }
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

    func worked(_ seat: Seat, files: Int) {
        guard let index = rows.firstIndex(where: { $0.seat == seat }) else { return }
        rows[index].files = files
    }

    func finish(_ seat: Seat) {
        guard let index = rows.firstIndex(where: { $0.seat == seat }) else { return }
        rows[index].done = true
        // What it changed, not merely that it stopped. A delegate that wrote
        // nothing and one that wrote nine files both used to read "done".
        rows[index].state = rows[index].files.map {
            $0 == 0 ? "done · no files written" : "done · \($0) file\($0 == 1 ? "" : "s")"
        } ?? "done"
    }

    func end() {
        clear()
        feeds = []
        ticker = nil
        rows = []
    }

    private func update(_ seat: Seat, from session: Session) {
        guard let index = rows.firstIndex(where: { $0.seat == seat }),
              !rows[index].done else { return }
        rows[index].state = session.activity()
        draw()
    }

    private func draw() {
        guard !rows.isEmpty else { return }
        let elapsed = Int(Date().timeIntervalSince(startedAt).rounded())
        guard live else { return }

        var out = ""
        for _ in 0..<drawn { out += "\u{1B}[1A\u{1B}[2K" }
        for row in rows {
            let mark = row.done ? "✓" : "·"
            let name = Console.paint("\(mark) \(row.seat.mention)",
                                     Console.tint(row.seat.account))
            // A live line that wraps is a live line that can't be erased: the
            // cursor walk that takes this block down counts rows, and a wrapped
            // row is two of them.
            let state = Console.fit(row.state, to: Console.width - row.seat.mention.count - 7)
            out += "  \(name)  \(Console.dim(state))\n"
        }
        out += "  " + Console.dim("\(elapsed)s") + "\n"
        Console.write(out)
        drawn = rows.count + 1
    }
}
