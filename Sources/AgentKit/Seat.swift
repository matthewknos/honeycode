import Foundation

/// One agent in a crew — as distinct from the account it runs on.
///
/// The type exists because those two things stopped being the same thing. A
/// crew used to be "one conversation per account", and every piece of state in
/// `Crew` was keyed by `Account` on that assumption: who is running, who owes
/// whom an answer, whose mailbox this is. It made a reasonable-sounding rule
/// impossible to lift — *four instances of Kimi, working in parallel* — and
/// worse, the rule wasn't visible from outside. A plan that asked for four got
/// one agent doing four things in sequence, and a lead that had no way to know
/// that told the person all four were working.
///
/// So the account says **which subscription pays and which models are on
/// offer**, and the seat says **which conversation this is**. Two seats on one
/// account are two CLI processes, two transcripts and two turns running at the
/// same moment, and they cost twice as much.
///
/// `index` is 1-based, and **seat 1 is the bare handle**: `@kimi` and `@kimi#1`
/// are the same agent, spelled two ways. That is what keeps every run that
/// never asks for a second instance reading exactly as it did before this type
/// existed — one seat per account, addressed by name, no numbers anywhere.
struct Seat: Hashable {

    let account: Account
    let index: Int

    /// Out-of-range indices clamp rather than trap. This is built from text a
    /// language model wrote, and `@kimi#0` is a typo for the first seat, not a
    /// reason to lose the assignment attached to it.
    init(_ account: Account, _ index: Int = 1) {
        self.account = account
        self.index = min(max(index, 1), Seat.limit)
    }

    /// How many conversations one subscription may hold open in a single run.
    ///
    /// A ceiling rather than a preference: each seat is a real child process on
    /// a paid account, and the lead choosing the number is a model choosing how
    /// much to spend. Four is what the run that motivated all this asked for,
    /// so four is what it gets — and a plan asking for a fifth is told no
    /// rather than quietly given one.
    static let limit = 4

    var isFirst: Bool { index == 1 }

    /// `kimi`, `kimi#2` — how the agent is addressed, everywhere.
    var handle: String {
        let name = AgentMention.handle(account)
        return isFirst ? name : "\(name)#\(index)"
    }

    /// `@kimi#2` — the same thing, for prose.
    var mention: String { "@" + handle }

    /// What to call this seat on screen. The account's own name for the first
    /// seat, so nothing gains a number it didn't have before.
    var title: String {
        isFirst ? account.title : "\(account.title) #\(index)"
    }

    /// A directory component. Deliberately not `handle` — `#` in a path is
    /// legal but reads as a fragment, and this ends up in a URL.
    var folderName: String {
        isFirst ? AgentMention.handle(account) : "\(AgentMention.handle(account))-\(index)"
    }
}
