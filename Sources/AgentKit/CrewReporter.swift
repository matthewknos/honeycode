import Foundation

/// One piece of a plan: who it is for, and what it says.
///
/// A struct rather than the tuple this used to be, for one reason — it now
/// crosses a protocol boundary, and `(to:task:)` in a protocol requirement is a
/// signature nobody can read at the call site.
struct CrewAssignment: Equatable {
    /// Which agent, not merely which subscription — `@kimi#2` is a second Kimi
    /// running beside the first, and the whole reason a plan can now say
    /// "four ways" and mean it.
    let to: Seat
    let task: String
    /// The files this piece is going to write, as the lead declared them.
    ///
    /// Empty means the lead didn't say, not that the piece writes nothing —
    /// every check that reads this falls back to `Crew.namedFiles`, which is a
    /// regex over the prose and is what all of them used to do.
    ///
    /// The regex cannot tell "write this" from "read this", and three separate
    /// checks rested on it: the overlap warning had to be worded as *"named in
    /// more than one piece"* and reported as a note rather than a fault;
    /// `Crew.outstanding` computed exactly the right signal and explicitly
    /// refused to act on it; `alreadyDone` guessed. One field the lead already
    /// knows the answer to turns all three into facts, for about ten tokens a
    /// piece.
    var writes: [String] = []
    /// The part of the job every piece shares, written once by the lead and
    /// prepended to each task on the way out.
    ///
    /// Kept beside the task rather than folded into it, which is the whole
    /// subtlety. Everything that *describes* a piece wants the task alone —
    /// `Crew.gist` builds the roster line from it, and the plan the person
    /// reads is a list of them, and three delegates whose entries all began
    /// with the same four hundred words of project preamble would be a plan you
    /// cannot skim. Everything that *acts* on a piece wants both: the tenancy
    /// check has to see the preamble because that is exactly where a lead would
    /// put the organisation's material, and the overlap check has to see it
    /// because it is where shared filenames get named. That is `wire`.
    var brief: String?
    /// What the lead asked this delegate to run, if it asked. Same grammar as a
    /// mention — `{"to": "kimi:k3"}` — because that is the grammar the lead
    /// reads in its own briefing and will reasonably write back.
    var model: String?
    var effort: EffortChoice?

    /// The whole instruction, as the delegate will receive it.
    ///
    /// Used by everything that reads a piece for what it *contains* rather than
    /// for what it is called — see `brief`.
    /// The declared files are part of it, and have to be.
    ///
    /// Two reasons, and the second is the load-bearing one. A delegate checked
    /// against a list it was never shown is being marked against a paper it
    /// didn't sit — so if this app is going to report "you didn't write x.ts",
    /// the agent has to have been told x.ts was its. And `Tenancy.inspection`
    /// reads `wire`, so a path that carries this organisation's material —
    /// `src/acme-migration/…` is a real shape — goes through the gate with
    /// everything else rather than around it.
    var wire: String {
        var out = task
        if let brief, !brief.isEmpty { out = brief + "\n\n" + out }
        guard !writes.isEmpty else { return out }
        return out + "\n\nThe files this piece is responsible for writing: "
            + writes.joined(separator: ", ")
            + ". They are what it will be checked against."
    }

    /// `@kimi#2:k3` — how the plan should read.
    ///
    /// Qualifiers included, because "which model is this running on" is the
    /// question a plan gets asked most and the one it was least able to answer.
    /// The instance number is in there for the same reason one step up: a plan
    /// listing `@kimi` three times reads as a mistake, and `@kimi#1 @kimi#2
    /// @kimi#3` reads as what it is.
    var label: String {
        var out = to.mention
        if let model { out += ":" + model }
        if let effort { out += ":" + effort.rawValue }
        return out
    }
}

/// A piece of a delegation block that isn't going to run, and why.
///
/// Refusals used to be a `continue`. That is how a lead dispatched four tasks
/// to `@kimi`, watched one of them run, and told the person — twice, in a
/// table — that four agents were working: nothing had told it otherwise, and an
/// empty directory reads as a slow agent rather than an absent one. Silence
/// about work that was thrown away is the worst thing this file can do, because
/// the lead goes on to report it as done.
struct CrewRefusal: Equatable {
    /// As written, so a misspelling can be seen to be one.
    let to: String
    let why: String
}

/// Where a crew run says what it is doing.
///
/// `Crew` used to print. That was fine while the only thing running a crew was
/// a terminal, and it is the single reason the feature couldn't move into the
/// app: three hundred lines of orchestration with `Console.line` woven through
/// them are three hundred lines that only work if there is a stdout to write
/// to. Everything the run has to say goes through here instead, and the two
/// faces implement it differently — ANSI in the terminal, transcript items in
/// the window.
///
/// Deliberately narrow, and deliberately about *events* rather than about text.
/// A method called `printAssignments(String)` would have moved the formatting
/// decision into `Crew` and left each face with nothing to decide; `plan([…])`
/// lets the terminal draw a bulleted list and the app draw a card.
@MainActor
protocol CrewReporter: AnyObject {

    /// A quiet aside: a model resolved, a connection being waited on, how long
    /// the run took. Never the substance of an answer.
    func status(_ text: String)

    /// Something went wrong, phrased for the person rather than for a log.
    func problem(_ text: String)

    /// Who is about to speak, and what they are doing — "planning", "done",
    /// "assembling". The one place the run names an agent out loud.
    func speaker(_ seat: Seat, note: String)

    /// Text that belongs in the record as written: the lead's plan, a
    /// delegate's report.
    func prose(_ text: String)

    /// The work, split. Called once, before anything is sent — including the
    /// pieces that turn out not to be sendable, because a plan the person can
    /// see and a plan that ran are different things and the difference is worth
    /// showing.
    func plan(_ assignments: [CrewAssignment])

    /// A piece that never left. See `Tenancy` — the reason is written for the
    /// person and carries no material.
    func held(_ assignment: CrewAssignment, reason: String)

    /// Mirror this session's output as it arrives, under this agent's name.
    /// At most one at a time; a second call replaces the first.
    func stream(_ session: Session, as seat: Seat)

    /// Stop mirroring, flushing whatever arrived since the last tick.
    func endStream()

    /// Who is working right now, and in which session. Called again each time
    /// the set changes, and with an empty array when nobody is — which is also
    /// how a live progress display is told to take itself down.
    func working(_ delegates: [(seat: Seat, session: Session)])

    /// One agent asking another something, or answering.
    ///
    /// Shown rather than logged. A crew where the members talk is a crew whose
    /// behaviour you cannot predict from the plan, and the plan is the only
    /// thing on screen — so the traffic has to be visible or the run becomes a
    /// black box that occasionally costs four times what you expected.
    func message(from: Seat, to: Seat, _ text: String, answering: Bool)

    /// How many files a delegate actually changed, once it has landed.
    ///
    /// Separate from its report, and deliberately not derived from it: this is
    /// counted from what the session recorded doing, and the whole point is
    /// that it can disagree with what the agent says. See `Crew.Work`.
    func worked(_ seat: Seat, files: Int)

    /// One delegate has landed. Separate from `working` because the two answer
    /// different questions: this one is "mark it finished", that one is "here
    /// is the current set".
    func landed(_ seat: Seat)

    /// The run is over and it is safe to ask for input again.
    func finished(seconds: Int, spend: String)
}
