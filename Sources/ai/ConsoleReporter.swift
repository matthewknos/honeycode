import Foundation

/// A crew run, as a terminal transcript.
///
/// Everything `Crew` used to do inline. It reads as a thin adapter because it
/// is one — the only judgement left here is where the blank lines go and when
/// the live progress block has to come down, and both of those are terminal
/// problems that the app half has no equivalent of.
@MainActor
final class ConsoleReporter: CrewReporter {

    private let progress = Progress()
    private var streamer: Streamer?

    // MARK: Asides

    func status(_ text: String) {
        progress.clear()
        Console.breakLine()
        Console.status(text)
    }

    func problem(_ text: String) {
        progress.clear()
        Console.breakLine()
        Console.failure(text)
    }

    func speaker(_ seat: Seat, note: String) {
        // Before anything permanent is written, because the progress block sits
        // at the bottom of the screen and is redrawn by cursor movement — text
        // printed under it would be overwritten by the next tick.
        progress.clear()
        Console.speaker(seat, note: note)
    }

    func prose(_ text: String) {
        guard !text.isEmpty else { return }
        progress.clear()
        Console.line(text)
    }

    // MARK: The plan

    func plan(_ assignments: [CrewAssignment]) {
        progress.clear()
        Console.breakLine()
        Console.line()
        for assignment in assignments {
            let name = Console.paint("▸ " + assignment.label,
                                     Console.tint(assignment.to.account), bold: true)
            Console.line(name + " " + Console.dim(String(assignment.task.prefix(110))))
        }
        Console.line()
    }

    /// A refusal, in the colour refusals are already in.
    ///
    /// On the same line as the piece it refers to rather than in a block of its
    /// own: the plan was printed a moment ago and this is a correction to one
    /// row of it, not news of its own.
    func held(_ assignment: CrewAssignment, reason: String) {
        progress.clear()
        Console.breakLine()
        Console.line(Console.paint("  ✗ " + assignment.to.mention, "203")
                     + " " + Console.dim("not sent — " + reason))
    }

    // MARK: Live output

    func stream(_ session: Session, as seat: Seat) {
        streamer?.finish()
        streamer = Streamer(session, as: seat)
    }

    func endStream() {
        streamer?.finish()
        streamer = nil
    }

    func working(_ delegates: [(seat: Seat, session: Session)]) {
        guard !delegates.isEmpty else { progress.end(); return }
        progress.begin(delegates.map { ($0.seat, $0.session) })
    }

    /// Indented under the live block, and truncated hard. The point is that you
    /// can see a conversation happening and who is in it; the substance is in
    /// the transcript each of them keeps.
    func message(from: Seat, to: Seat, _ text: String, answering: Bool) {
        progress.clear()
        let arrow = answering ? " ↩ " : " → "
        let heads = Console.paint(from.mention, Console.tint(from.account))
            + Console.dim(arrow)
            + Console.paint(to.mention, Console.tint(to.account))
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        Console.line("  " + heads + " " + Console.dim(String(flat.prefix(90))))
    }

    func worked(_ seat: Seat, files: Int) {
        progress.worked(seat, files: files)
    }

    func landed(_ seat: Seat) {
        progress.finish(seat)
    }

    func finished(seconds: Int, spend: String) {
        progress.clear()
        Console.breakLine()
        Console.status("\(seconds)s · " + spend)
    }
}
