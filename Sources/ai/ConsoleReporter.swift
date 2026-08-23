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

    /// What the window says when nothing is running.
    private let idleTitle: String

    init(title: String) {
        self.idleTitle = title
    }

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
            let room = Console.width - assignment.label.count - 4
            Console.line(name + " " + Console.dim(Console.fit(assignment.task, to: room)))
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
        guard !delegates.isEmpty else {
            progress.end()
            Terminal.title(idleTitle)
            return
        }
        // The one thing worth knowing from outside the window: which of the
        // four terminals you have open is the one with agents in it.
        Terminal.title("ai · " + delegates.map(\.seat.handle).joined(separator: " "))
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
        let room = Console.width - from.mention.count - to.mention.count - arrow.count - 4
        Console.line("  " + heads + " " + Console.dim(Console.fit(text, to: room)))
    }

    func worked(_ seat: Seat, files: Int) {
        progress.worked(seat, files: files)
    }

    func landed(_ seat: Seat) {
        progress.finish(seat)
    }

    /// `end` rather than `clear`, which is the difference between taking the
    /// live block off the screen and stopping it coming back.
    ///
    /// `Crew.settle` calls this and then `onIdle`, and `onIdle` is what puts
    /// the prompt up — so anything still ticking after this point is a timer
    /// redrawing a progress block over a line somebody is typing into. Every
    /// path that gets here has called `working([])` first and so has already
    /// stopped it; this is the one that doesn't have to be checked for.
    func finished(seconds: Int, spend: String) {
        progress.end()
        Terminal.title(idleTitle)
        Console.breakLine()
        Console.status("\(seconds)s · " + spend)
    }
}
