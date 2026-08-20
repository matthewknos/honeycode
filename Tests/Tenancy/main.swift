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
let parsed = MainActor.assumeIsolated { Crew.assignments(json) } ?? []
check("one assignment per account, unknown handles dropped", parsed.count == 1)
check("handle resolved", parsed.first?.to == .kimi)
check("task carried", parsed.first?.task == "write the parser")

// --- mentions ---
let (crew, prompt) = AgentMention.parse("a landing page @claude-w and @kimi:free please @kimi")
check("order preserved, duplicates collapsed", crew.map(\.account) == [.work, .kimi])
check("model hint captured", crew.last?.model == "free")
check("mentions stripped", prompt == "a landing page and please")
check("email left alone", AgentMention.parse("mail me@example.com").crew.isEmpty)

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
