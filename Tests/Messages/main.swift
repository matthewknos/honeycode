// The channel between agents.
//
// Only the parts that answer on their own: what counts as a message, and that
// the two fences can't be mistaken for each other. Routing needs three live
// CLIs and a real run, so what's checked here is the grammar underneath it —
// which is where a mistake would be silent rather than loud.

import Foundation

var failures = 0
func check(_ label: String, _ ok: Bool) {
    print((ok ? "  ok   " : "  FAIL ") + label)
    if !ok { failures += 1 }
}

// --- what counts as a message ---
let block = #"""
{"messages":[
  {"to":"kimi","text":"what shape is CityChunkHandle?"},
  {"to":"@claude-p","text":"  is TUNING.city.SEED stable across reloads?  "},
  {"to":"kimi:k3","text":"and the collider type?"},
  {"to":"nobody","text":"hello"},
  {"to":"copilot","text":"   "}
]}
"""#
let parsed = MainActor.assumeIsolated { Crew.messages(block) }
check("addressed messages are read", parsed.count == 3)
check("a bare handle resolves", parsed.first?.to == .kimi)
check("an @ prefix resolves", parsed.dropFirst().first?.to == .personal)
check("text is trimmed", parsed.dropFirst().first?.text == "is TUNING.city.SEED stable across reloads?")
check("a model suffix on a question is ignored, not refused", parsed.last?.to == .kimi)
check("an unknown handle is dropped", !parsed.contains { $0.text == "hello" })
check("an empty question is dropped", !parsed.contains { $0.to == .copilot })
check("junk is not a message",
      MainActor.assumeIsolated { Crew.messages("not json at all") }.isEmpty)
check("the wrong shape is not a message", MainActor.assumeIsolated {
    Crew.messages(#"{"assignments":[{"to":"kimi","task":"x"}]}"#)
}.isEmpty)

// --- the two fences are not each other ---
// A delegate that could emit `ai-delegate` would be handing out work, which is
// the lead's job. A lead whose plan was read as a message would send its plan
// to one agent as a question.
let asks = """
Done — src/city/*.

```ai-message
{"messages":[{"to":"claude-p","text":"which module owns the collider type?"}]}
```
"""
let asked = MainActor.assumeIsolated { Crew.split(asks, at: Crew.messageFence) }
let askedAsPlan = MainActor.assumeIsolated { Crew.split(asks, at: Crew.fence) }
check("a message block is found under its own fence", asked.1 != nil)
check("and is invisible to the delegation fence", askedAsPlan.1 == nil)

let plans = """
Splitting it three ways.

```ai-delegate
{"assignments":[{"to":"kimi","task":"the city"}]}
```
"""
let planned = MainActor.assumeIsolated { Crew.split(plans, at: Crew.fence) }
let plannedAsMessage = MainActor.assumeIsolated { Crew.split(plans, at: Crew.messageFence) }
check("a plan is found under its own fence", planned.1 != nil)
check("and is not read as a message", plannedAsMessage.1 == nil)
check("prose survives the split", asked.0 == "Done — src/city/*.")

// --- roster lines ---
check("a task becomes one line", MainActor.assumeIsolated {
    Crew.gist("Build the procedural city. Use TUNING.city for every constant.")
} == "Build the procedural city")
check("a long unpunctuated task is cut, not dropped", MainActor.assumeIsolated {
    Crew.gist(String(repeating: "x", count: 400))
}.hasSuffix("…"))

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
