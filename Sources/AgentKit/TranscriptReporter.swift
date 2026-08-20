import Foundation

/// A crew run, as a conversation.
///
/// The window's answer to `ConsoleReporter`, and shaped by one fact the
/// terminal doesn't have: **the lead is already on screen.** In `ai` the lead's
/// reply has to be printed, because nothing else would. Here the lead *is* this
/// session — it streams into this transcript by itself, the way it does for
/// every other turn — so anything this class also printed would arrive twice.
///
/// So most of the protocol is deliberately quiet, and what's left is the part
/// the transcript genuinely can't see for itself:
///
/// - the delegates, which are separate sessions nobody is looking at, mirrored
///   into blocks here the way a second opinion already is;
/// - the plumbing — how the work was split, what the tenancy check held back,
///   what the whole run cost across four accounts, none of which any one
///   session's own rendering knows about.
@MainActor
final class TranscriptReporter: CrewReporter {

    /// Weak for the reason `Crew.host` is: the session owns the crew, which
    /// owns this. A strong reference here would close the loop.
    private weak var host: Session?
    /// The block each working delegate is being mirrored into, and the session
    /// it is being mirrored from — needed again at the end, because closing a
    /// block means reading one last time from the transcript behind it.
    private var blocks: [Seat: (id: UUID, session: Session)] = [:]

    init(host: Session) {
        self.host = host
    }

    // MARK: What the transcript can't see for itself

    func status(_ text: String) { host?.note(text) }

    func problem(_ text: String) { host?.note(text) }

    /// Only the lead's own phase changes, and only the ones that explain a
    /// pause. A delegate's "done" is already visible — its block stops
    /// spinning — and saying it again in a notice underneath is the app
    /// narrating what the reader just watched happen.
    func speaker(_ seat: Seat, note: String) {
        // The lead is always seat 1 of its account — a window's own session is
        // the conversation you're in, and there is only ever one of those.
        guard let host, seat == Seat(host.account) else { return }
        host.note(note)
    }

    /// Nothing. Every call carries text that is already on screen: the lead's
    /// plan is an `.assistant` block in this very transcript, and a delegate's
    /// report is the block it has been streaming into since it started. This is
    /// the method whose emptiness is the design — see the type's note.
    func prose(_ text: String) {}

    func plan(_ assignments: [CrewAssignment]) {
        guard !assignments.isEmpty else { return }
        let lines = assignments.map { "\($0.label) — \(Self.summarise($0.task))" }
        host?.note(lines.joined(separator: "\n"))
    }

    func held(_ assignment: CrewAssignment, reason: String) {
        host?.note("\(assignment.to.mention) — not sent: \(reason)")
    }

    // MARK: The delegates

    /// Nothing here either. `stream` exists for the terminal, which has to be
    /// told which session to print; a delegate's output reaches this transcript
    /// through `working`, and the lead's reaches it by being the lead.
    func stream(_ session: Session, as seat: Seat) {}

    func endStream() {}

    func working(_ delegates: [(seat: Seat, session: Session)]) {
        let now = Set(delegates.map(\.seat))

        // Anyone who has dropped out of the set has finished — including the
        // case where the set is empty, which is how a run ends.
        for (seat, block) in blocks where !now.contains(seat) {
            host?.stopMirroring(block.id, from: block.session)
            blocks[seat] = nil
        }

        for delegate in delegates where blocks[delegate.seat] == nil {
            // `Seat.title` carries the instance number, so three Kimis are
            // three distinguishable blocks rather than three identical headers
            // the reader has to tell apart by watching which one moves.
            let label = "\(delegate.seat.title) · \(delegate.session.model.title)"
            guard let id = host?.mirror(delegate.session, labelled: label) else { continue }
            blocks[delegate.seat] = (id: id, session: delegate.session)
        }
    }

    /// A notice rather than a block of its own.
    ///
    /// The two agents involved are both already on screen, streaming into their
    /// own mirrored blocks — what's missing is the fact that one of them
    /// stopped to ask the other something, which is a one-line event and reads
    /// as one.
    func message(from: Seat, to: Seat, _ text: String, answering: Bool) {
        let arrow = answering ? "↩" : "→"
        host?.note("\(from.mention) \(arrow) \(to.mention) — "
                   + Self.summarise(text, limit: 150))
    }

    /// Deliberately not the place a block is closed.
    ///
    /// `landed` says a turn finished; the block should stay open until the run
    /// stops mirroring it, because a delegate's last streamed delta and its
    /// completion can share a tick. `working` closes it a moment later with a
    /// final read, which is the one that catches that delta.
    func landed(_ seat: Seat) {}

    func finished(seconds: Int, spend: String) {
        // Worth saying here and not in the terminal's sense of "worth saying":
        // the rail above counts this session's own cost, and a crew spends on
        // three others it has never heard of.
        host?.note("\(seconds)s · \(spend)")
    }

    /// A task, short enough to sit in a notice.
    ///
    /// The first sentence rather than the first N characters where there is
    /// one: an assignment opens by saying what to build, and cutting mid-clause
    /// turns that into a riddle.
    private static func summarise(_ task: String, limit: Int = 120) -> String {
        let flat = task.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if let stop = flat.firstIndex(of: "."), flat.distance(from: flat.startIndex, to: stop) < limit {
            return String(flat[..<stop])
        }
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }
}
