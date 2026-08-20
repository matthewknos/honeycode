import Foundation
import Combine

/// A crew run, while it is happening.
///
/// The terminal has had this since delegates started running for minutes at a
/// time: `Progress` draws a block at the foot of the screen with a row per
/// agent, what it is doing and how long it has been doing it. The window has
/// had nothing — `TranscriptReporter` writes one-line notices into the
/// transcript and no view reads `Crew` at all — so the only way to learn what a
/// run was doing was to ask the lead, which is a question the lead answers by
/// guessing.
///
/// That is not a hypothetical. In the run this came out of, five of the six
/// messages the person sent were "whats currently happening", "how long will
/// this take", "check if they are running" and "stop all for now". None of them
/// were about the thing being built. Every fact they wanted already existed in
/// `Crew` — who is running, what each was given, what it is spending — and had
/// nowhere to be seen.
///
/// So this is that state, published. It is written by `TranscriptReporter` from
/// the events the reporter protocol already delivers, which is why `Crew` needs
/// no knowledge of it: the run reports what it is doing, and this is one more
/// thing listening.
@MainActor
final class CrewRun: ObservableObject {

    /// What one agent in the run is doing.
    ///
    /// Ordered by the plan, not by who finished first — the person read the
    /// plan a moment ago and re-sorting under them would cost more than the
    /// tidiness is worth.
    struct Member: Identifiable, Equatable {
        let seat: Seat
        /// What it is running. Named here because "which model is this" is the
        /// question this feature got wrong for an hour.
        var model: String
        /// The one-line gist of its piece, from `Crew.gist`.
        var piece: String
        var state: State
        /// The conversation it is working in, for live activity and spend.
        /// Absent for a piece that never left.
        var session: Session?
        /// How many files it actually changed, once it has landed. `nil` while
        /// it is still going. Zero is the number worth seeing — see `Crew.Work`.
        var files: Int?

        var id: Seat { seat }

        static func == (a: Member, b: Member) -> Bool {
            a.seat == b.seat && a.model == b.model && a.piece == b.piece
                && a.state == b.state && a.session === b.session && a.files == b.files
        }
    }

    enum State: Equatable {
        case waiting
        case working
        /// Answering another agent's question rather than doing its own piece.
        /// Worth telling apart: it is the one state where an agent is busy on
        /// something the plan doesn't mention.
        case answering
        case done
        /// The tenancy check refused to let this piece leave, or it was never
        /// dispatched. Carries the reason.
        case held(String)
        case gaveUp
    }

    /// Who is leading, and the conversation it leads in.
    @Published private(set) var leader: Seat?
    @Published private(set) var leaderSession: Session?
    @Published private(set) var members: [Member] = []
    /// What the lead is doing between the delegates — "planning", "assembling".
    @Published private(set) var phase: String?
    @Published private(set) var startedAt: Date?
    /// How many questions the agents have asked each other. A crew that talks
    /// costs more than the plan says it will, so the count is worth a glance.
    @Published private(set) var messages = 0
    /// Set when the run ends. The panel uses it to take itself down.
    @Published private(set) var finished = false

    init(leader: Seat, session: Session?) {
        self.leader = leader
        self.leaderSession = session
        self.startedAt = Date()
    }

    // MARK: What the reporter tells it

    func setPhase(_ text: String?) { phase = text }

    /// The plan, as members. Called once, before anything is sent — including
    /// the pieces that turn out not to be sendable, for the same reason the
    /// reporter is told about those: a plan you can see and a plan that ran are
    /// different things.
    func plan(_ assignments: [CrewAssignment], model: (Seat) -> String) {
        members = assignments.map {
            Member(seat: $0.to, model: model($0.to),
                   piece: Crew.gist($0.task), state: .waiting, session: nil)
        }
    }

    func hold(_ seat: Seat, reason: String) {
        update(seat) { $0.state = .held(reason); $0.session = nil }
    }

    /// Who is working right now. Anyone who has dropped out of the set has
    /// landed — including the case where the set is empty, which is how a run
    /// ends.
    func working(_ active: [(seat: Seat, session: Session)], answering: Set<Seat>) {
        let now = Set(active.map(\.seat))
        for index in members.indices {
            let seat = members[index].seat
            if let live = active.first(where: { $0.seat == seat }) {
                members[index].session = live.session
                members[index].state = answering.contains(seat) ? .answering : .working
            } else if case .held = members[index].state {
                continue
            } else if !now.contains(seat), members[index].state != .waiting {
                members[index].state = .done
            }
        }
    }

    /// Fill in what a seat turned out to be running.
    ///
    /// Separate from `plan` because the two know different things at different
    /// moments: a plan knows the qualifier the lead wrote, and only a live
    /// session knows the title that resolved to.
    func resolved(_ seat: Seat, model: String) {
        update(seat) { if $0.model.isEmpty || $0.model != model { $0.model = model } }
    }

    func worked(_ seat: Seat, files: Int) {
        update(seat) { $0.files = files }
    }

    func landed(_ seat: Seat) {
        update(seat) { if case .held = $0.state {} else { $0.state = .done } }
    }

    func gaveUp(_ seat: Seat) {
        update(seat) { $0.state = .gaveUp }
    }

    func counted(_ message: Bool = true) { if message { messages += 1 } }

    func end() {
        finished = true
        phase = nil
        for index in members.indices where members[index].state == .working
            || members[index].state == .answering || members[index].state == .waiting {
            members[index].state = .done
        }
    }

    // MARK: What the panel asks it

    var elapsed: TimeInterval { startedAt.map { -$0.timeIntervalSinceNow } ?? 0 }

    /// Everything this run has spent, across every account in it.
    ///
    /// Reported only at the end before this existed, which is the wrong moment:
    /// four subscriptions running at once is exactly when you want to see a
    /// number climbing, and the one place it could not be seen was while it
    /// still mattered.
    var spend: Double {
        var total = leaderSession?.costUSD ?? 0
        // Distinct conversations only — a seat that never got one contributes
        // nothing, and two members can't share a session.
        for member in members { total += member.session?.costUSD ?? 0 }
        return total
    }

    var isBusy: Bool {
        !finished && members.contains { $0.state == .working || $0.state == .answering }
    }

    private func update(_ seat: Seat, _ change: (inout Member) -> Void) {
        guard let index = members.firstIndex(where: { $0.seat == seat }) else { return }
        change(&members[index])
    }
}

extension Session {

    /// What this agent is doing *now* — the last thing it started, not a
    /// summary of everything it has done.
    ///
    /// Lifted out of the terminal's progress block so the window can say the
    /// same thing. Two descriptions of "what is it doing" would drift, and the
    /// whole reason a person looks at either is to compare one agent against
    /// another; they had better be describing them the same way.
    ///
    /// Crew transport is filtered out for the same reason it is everywhere
    /// else: an agent that has just asked a colleague a question would
    /// otherwise be reported as doing `` ``` ``.
    func activity(limit: Int = 68) -> String {
        func trim(_ text: String) -> String {
            let flat = text.replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
        }
        for item in items.reversed() {
            switch item {
            case .tool(_, _, let name, let target, _, _):
                return trim("\(name) \(target)")
            case .diff(_, _, let file, let rows, _):
                return trim("editing \(URL(fileURLWithPath: file).lastPathComponent)"
                            + " (\(rows.count) lines)")
            case .search(_, _, let query, _, _):
                return trim("searching \(query)")
            case .assistant(_, let text) where !text.isEmpty:
                let shown = CrewFence.hidden(from: text)
                let line = shown.components(separatedBy: .newlines)
                    .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
                return trim(line.isEmpty ? "writing" : line)
            case .thinking:
                return "thinking"
            default:
                continue
            }
        }
        return isRunning ? "thinking" : "starting"
    }
}
