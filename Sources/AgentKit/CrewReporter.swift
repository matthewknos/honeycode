import Foundation

/// One piece of a plan: who it is for, and what it says.
///
/// A struct rather than the tuple this used to be, for one reason — it now
/// crosses a protocol boundary, and `(to:task:)` in a protocol requirement is a
/// signature nobody can read at the call site.
struct CrewAssignment: Equatable {
    let to: Account
    let task: String
    /// What the lead asked this delegate to run, if it asked. Same grammar as a
    /// mention — `{"to": "kimi:k3"}` — because that is the grammar the lead
    /// reads in its own briefing and will reasonably write back.
    var model: String?
    var effort: EffortChoice?

    /// `@kimi:k3` — how the plan should read.
    ///
    /// Qualifiers included, because "which model is this running on" is the
    /// question a plan gets asked most and the one it was least able to answer.
    var label: String {
        var out = "@" + AgentMention.handle(to)
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
    func speaker(_ account: Account, note: String)

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

    /// Mirror this session's output as it arrives, under this account's name.
    /// At most one at a time; a second call replaces the first.
    func stream(_ session: Session, as account: Account)

    /// Stop mirroring, flushing whatever arrived since the last tick.
    func endStream()

    /// Who is working right now, and in which session. Called again each time
    /// the set changes, and with an empty array when nobody is — which is also
    /// how a live progress display is told to take itself down.
    func working(_ delegates: [(account: Account, session: Session)])

    /// One delegate has landed. Separate from `working` because the two answer
    /// different questions: this one is "mark it finished", that one is "here
    /// is the current set".
    func landed(_ account: Account)

    /// The run is over and it is safe to ask for input again.
    func finished(seconds: Int, spend: String)
}
