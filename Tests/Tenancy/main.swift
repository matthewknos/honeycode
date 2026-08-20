// The PII boundary's decisions, with no agent involved.
//
// Everything here is the part of `Tenancy` that answers on its own: whether a
// verdict is readable, which direction a delegation crosses, and whether the
// preference gates it. The classifier itself is an LLM and can't be tested
// offline — what can be tested, and is, is that every way of failing to hear
// from it ends in a block.

import Foundation

var failures = 0
func check(_ label: String, _ ok: Bool) {
    print((ok ? "  ok   " : "  FAIL ") + label)
    if !ok { failures += 1 }
}

// --- Tenancy.verdict: fails closed on everything it can't read ---
check("nil reply blocks", !Tenancy.verdict(nil).isClear)
check("empty reply blocks", !Tenancy.verdict("").isClear)
check("prose with no fence blocks", !Tenancy.verdict("Yes, that looks fine to me.").isClear)
check("fence with junk blocks", !Tenancy.verdict("```tenancy-verdict\nsure\n```").isClear)
check("fence missing `clear` blocks",
      !Tenancy.verdict("```tenancy-verdict\n{\"reason\":\"x\"}\n```").isClear)
check("clear:true passes",
      Tenancy.verdict("```tenancy-verdict\n{\"clear\": true}\n```").isClear)
check("clear:false blocks",
      !Tenancy.verdict("```tenancy-verdict\n{\"clear\": false, \"reason\":\"names a customer\"}\n```").isClear)

if case .blocked(let reason) = Tenancy.verdict(
    "```tenancy-verdict\n{\"clear\": false, \"reason\":\"names a customer\"}\n```") {
    check("reason survives", reason == "names a customer")
} else { check("reason survives", false) }

// The illustration-then-answer case the `fenced` doc comment describes.
let twice = """
Here is what I will say:
```tenancy-verdict
{"clear": false, "reason": "example"}
```
Having checked, the task is generic.
```tenancy-verdict
{"clear": true}
```
"""
check("last block wins, not the first", Tenancy.verdict(twice).isClear)

// A refusal that survived into the reason must not carry material — can't test
// the model, but an empty reason must not become one.
if case .blocked(let reason) = Tenancy.verdict("```tenancy-verdict\n{\"clear\":false,\"reason\":\"  \"}\n```") {
    check("blank reason gets a default", !reason.trimmingCharacters(in: .whitespaces).isEmpty)
} else { check("blank reason gets a default", false) }

// --- direction ---
check("work → personal leaves", Tenancy.leaves(.work, to: .personal))
check("work → kimi leaves", Tenancy.leaves(.work, to: .kimi))
check("personal → work does not", !Tenancy.leaves(.personal, to: .work))
check("work → work does not", !Tenancy.leaves(.work, to: .work))
check("personal → kimi does not", !Tenancy.leaves(.personal, to: .kimi))

// --- the preference gates both fences ---
let was = Tenancy.gates
Tenancy.gates = true
check("gates on: work → copilot is inspected", Tenancy.inspects(.work, to: .copilot))
Tenancy.gates = false
check("gates off: nothing is inspected", !Tenancy.inspects(.work, to: .copilot))
Tenancy.gates = was

// --- assignment parsing still holds after the struct change ---
let json = #"{"assignments":[{"to":"@kimi","task":"write the parser"},{"to":"kimi","task":"again"},{"to":"nobody","task":"x"},{"to":"copilot","task":"  "}]}"#
let plan = MainActor.assumeIsolated { Crew.assignments(json) } ?? Crew.Plan()
let parsed = plan.assignments
check("one assignment per account", parsed.count == 1)
check("handle resolved", parsed.first?.to == .kimi)
check("task carried", parsed.first?.task == "write the parser")

// Nothing is dropped in silence: a lead that isn't told a piece was refused
// reports it as running, which is how a status table came to list four agents
// working when one was.
check("every dropped piece is accounted for", plan.refused.count == 3)
check("the duplicate says why", plan.refused.contains { $0.to == "kimi" && $0.why.contains("already") })
check("the unknown handle is named as written",
      plan.refused.contains { $0.to == "nobody" && $0.why.contains("no agent") })
check("an empty task is refused, not run",
      plan.refused.contains { $0.to == "copilot" && $0.why == "no task" })

// --- qualifiers on an assignment ---
let qualified = MainActor.assumeIsolated {
    Crew.assignments(#"{"assignments":[{"to":"kimi:k3","task":"build the city"},{"to":"@claude-w:opus:max","task":"review it"}]}"#)
} ?? Crew.Plan()
check("a model suffix no longer deletes the assignment", qualified.assignments.count == 2)
check("the model survives", qualified.assignments.first?.model == "k3")
check("effort is read on an account that has it", qualified.assignments.last?.effort == .max)
check("and the model beside it", qualified.assignments.last?.model == "opus")
check("the plan says what it will run", qualified.assignments.first?.label == "@kimi:k3")

// --- mentions ---
let (crew, prompt) = AgentMention.parse("a landing page @claude-w and @kimi:free please @kimi")
check("order preserved, duplicates collapsed", crew.map(\.account) == [.work, .kimi])
check("model hint captured", crew.last?.model == "free")
check("mentions stripped", prompt == "a landing page and please")
check("email left alone", AgentMention.parse("mail me@example.com").crew.isEmpty)

// --- effort in a mention ---
let effortful = AgentMention.parse("@claude-p:opus:max and @claude-p:max:opus").crew
check("model and effort, either way round",
      effortful.first?.model == "opus" && effortful.first?.effort == .max)
let reversed = AgentMention.parse("@claude-w:max:sonnet").crew
check("order between qualifiers doesn't matter",
      reversed.first?.model == "sonnet" && reversed.first?.effort == .max)
check("an account with no effort reads it as a model instead",
      AgentMention.parse("@copilot:max").crew.first?.model == "max")
check("and carries no effort", AgentMention.parse("@copilot:max").crew.first?.effort == nil)
check("a bare handle still carries nothing",
      AgentMention.parse("@kimi go").crew.first?.model == nil)

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
