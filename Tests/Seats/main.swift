// Several instances of one subscription.
//
// The rule this replaces was "one account is one conversation", and it was
// enforced in three places that had to agree: the mention grammar a person
// types, the assignment grammar a lead writes back, and the seat identity both
// resolve to. What is checked here is that they do agree — a `@kimi#2` typed
// into a composer and a `{"to":"kimi#2"}` written by a model must name the
// same agent, or a plan silently addresses somebody who isn't there.
//
// Everything below runs on parsing alone. Actually launching four Kimis needs
// four subscriptions and four minutes; what it would tell us that this doesn't
// is whether the CLI can be started twice, which is not a question about this
// code.

import Foundation

var failures = 0
func check(_ label: String, _ ok: Bool) {
    print((ok ? "  ok   " : "  FAIL ") + label)
    if !ok { failures += 1 }
}

// --- the identity itself ---
check("the bare handle is seat one", Seat(.kimi) == Seat(.kimi, 1))
check("a numbered seat is a different agent", Seat(.kimi, 2) != Seat(.kimi))
check("two accounts never collide", Seat(.kimi, 2) != Seat(.copilot, 2))
check("seat one is spelled without a number", Seat(.kimi).handle == "kimi")
check("and the rest are spelled with one", Seat(.kimi, 3).handle == "kimi#3")
check("the first seat's folder is unchanged", Seat(.kimi).folderName == "kimi")
check("a later seat's folder is not a URL fragment",
      Seat(.kimi, 2).folderName == "kimi-2" && !Seat(.kimi, 2).folderName.contains("#"))
check("the first seat keeps the account's own name", Seat(.kimi).title == Account.kimi.title)
check("a later seat is told apart on screen", Seat(.kimi, 2).title.contains("#2"))

// Out of range clamps rather than traps: this is built from text a model wrote,
// and losing an assignment to a typo is worse than running it on seat 1.
check("zero clamps to the first seat", Seat(.kimi, 0).index == 1)
check("beyond the limit clamps to the limit", Seat(.kimi, 99).index == Seat.limit)

// --- what a person types ---
let (crew, prompt) = AgentMention.parse(
    "build it @claude-p with @kimi#1:k3 @kimi#2:k3 @kimi#3 @kimi#2 please")
check("each numbered instance is its own agent",
      crew.map(\.seat) == [Seat(.personal), Seat(.kimi, 1), Seat(.kimi, 2), Seat(.kimi, 3)])
check("a repeated instance still collapses", crew.filter { $0.seat == Seat(.kimi, 2) }.count == 1)
check("qualifiers survive the number", crew.first { $0.seat == Seat(.kimi, 1) }?.model == "k3")
check("an unnumbered instance defaults to k3's absence",
      crew.first { $0.seat == Seat(.kimi, 3) }?.model == nil)
check("mentions are stripped whole, number and all",
      prompt == "build it with please")

// The bare handle and #1 are the same agent, so naming both is naming one.
let (same, _) = AgentMention.parse("@kimi and @kimi#1")
check("the bare handle and #1 collapse together", same.count == 1)

// Out of range is left in the prose rather than becoming the fourth agent —
// silently spending a subscription nobody asked for is the failure worth
// avoiding here.
let (none, kept) = AgentMention.parse("@kimi#9 do it")
check("an impossible instance names nobody", none.isEmpty)
check("and is left visible in what was typed", kept.contains("@kimi#9"))

// --- what a lead writes back ---
let plan = MainActor.assumeIsolated {
    Crew.assignments(#"""
    {"assignments":[
      {"to":"kimi#1:k3","task":"the city"},
      {"to":"kimi#2:k3","task":"the camera"},
      {"to":"kimi#3:k3","task":"the character"},
      {"to":"kimi#4:k3","task":"the HUD"},
      {"to":"kimi#2","task":"and one more thing"},
      {"to":"kimi#5","task":"one instance too many"},
      {"to":"nobody#2","task":"nor this"}
    ]}
    """#)
} ?? Crew.Plan()

// The whole point: the run that motivated this asked for four Kimis and got one.
check("four instances of one subscription run four ways", plan.assignments.count == 4)
check("each is a distinct agent", Set(plan.assignments.map(\.to)).count == 4)
check("they share the account they are billed to",
      plan.assignments.allSatisfy { $0.to.account == .kimi })
check("the model is carried onto every one",
      plan.assignments.allSatisfy { $0.model == "k3" })
check("the plan reads as four agents, not one repeated",
      plan.assignments.map(\.label) == ["@kimi:k3", "@kimi#2:k3", "@kimi#3:k3", "@kimi#4:k3"])

// Refusals still explain themselves — the property that stopped a lead
// reporting dropped work as finished.
check("a second task for one instance is refused, not queued",
      plan.refused.contains { $0.to == "kimi#2" && $0.why.contains("already") })
check("and the refusal says how to run it beside the first",
      plan.refused.contains { $0.to == "kimi#2" && $0.why.contains("kimi#3") })
check("past the limit is refused as a limit, not as a misspelling",
      plan.refused.contains { $0.to == "kimi#5" && $0.why.contains("numbered 1 to") })
check("an unknown name is still an unknown name, number or no number",
      plan.refused.contains { $0.to == "nobody#2" && $0.why.contains("no agent") })
check("nothing was dropped in silence",
      plan.assignments.count + plan.refused.count == 7)

// --- who a plan is allowed to spend ---
//
// A seat is the lead's decision and a subscription is the person's, and this is
// the line between them. It matters most on the account that isn't there: a
// plan that recruits an enterprise seat because the work looked enterprise-
// shaped would put the tenancy gate in front of a crossing nobody chose.
let roster: Set<Account> = [.personal, .kimi]
let lead = Seat(.personal)
func admits(_ seat: Seat) -> Bool {
    MainActor.assumeIsolated { Crew.objection(to: seat, leader: lead, roster: roster) } == nil
}
check("an agent the person named is admitted", admits(Seat(.kimi)))
check("and so is a new instance of it", admits(Seat(.kimi, 3)))
check("a second instance of the lead's own account is a real delegate",
      admits(Seat(.personal, 2)))
check("the lead itself is refused a piece", !admits(lead))
check("an account nobody named is refused", !admits(Seat(.work)))
check("and numbering it doesn't get it in", !admits(Seat(.work, 2)))
check("the refusal names the account, not the instance",
      MainActor.assumeIsolated {
          Crew.objection(to: Seat(.work, 2), leader: lead, roster: roster)
      }?.contains("claude-w") == true)

// --- one grammar, not two ---
// A handle typed into a composer and one written into a plan must resolve
// identically, or the roster a delegate is shown lists agents its own messages
// can't reach.
for text in ["kimi", "kimi#1", "kimi#4", "claude-w#2", "copilot"] {
    let typed = AgentMention.parse("@" + text).crew.first?.seat
    let written = AgentMention.seat(forHandle: text)
    check("`\(text)` means the same typed as written", typed != nil && typed == written)
}
check("a handle round-trips through its own spelling",
      AgentMention.seat(forHandle: Seat(.kimi, 3).handle) == Seat(.kimi, 3))

// --- what the team control composes is what the parser reads ---
//
// The control exists so nobody has to know the grammar; the cost of that is a
// second writer of it. If these two ever disagree the control silently
// addresses nobody — it would compose a line, the parser would find no crew,
// and the message would go to one agent with no sign anything was dropped.
let team = [
    AgentMention.Pick(seat: Seat(.kimi, 1), model: "k3"),
    AgentMention.Pick(seat: Seat(.kimi, 2), model: "k3"),
    AgentMention.Pick(seat: Seat(.kimi, 3), model: nil),
    AgentMention.Pick(seat: Seat(.work), model: "opus", effort: .max),
]
let line = team.map(\.mention).joined(separator: " ")
check("the composed line is the grammar it looks like",
      line == "@kimi:k3 @kimi#2:k3 @kimi#3 @claude-w:opus:max")

let readBack = AgentMention.parse(line + "\n\nbuild it").crew
check("every agent the control named is read back",
      readBack.map(\.seat) == team.map(\.seat))
check("and so is every model",
      readBack.map(\.model) == team.map(\.model))
check("and the effort with it", readBack.last?.effort == .max)
check("the prompt survives", AgentMention.parse(line + "\n\nbuild it").prompt == "build it")

// Typing a handle yourself while it is already on the team is one agent, not
// two — the composer prepends rather than checking, and this is what makes
// that safe.
let doubled = AgentMention.parse("@kimi:k3\n\nlook at @kimi again").crew
check("a handle named twice by two routes is still one agent", doubled.count == 1)

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
