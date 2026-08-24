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
check("a bare handle resolves", parsed.first?.to == Seat(.kimi))
check("an @ prefix resolves", parsed.dropFirst().first?.to == Seat(.personal))
check("text is trimmed", parsed.dropFirst().first?.text == "is TUNING.city.SEED stable across reloads?")
check("a model suffix on a question is ignored, not refused", parsed.last?.to == Seat(.kimi))
check("an unknown handle is dropped", !parsed.contains { $0.text == "hello" })
check("an empty question is dropped", !parsed.contains { $0.to == Seat(.copilot) })

// --- a question reaches one instance, not whichever answers first ---
//
// The seat is not a qualifier. Two Kimis in a run hold two different pieces,
// and a question about the collider type has a right answer only from the one
// that wrote it.
let addressed = MainActor.assumeIsolated {
    Crew.messages(#"""
    {"messages":[
      {"to":"kimi#2","text":"which module owns the collider type?"},
      {"to":"kimi#9","text":"and this one goes nowhere"}
    ]}
    """#)
}
check("a numbered instance is addressable", addressed.first?.to == Seat(.kimi, 2))
check("and is not the same agent as the bare handle", addressed.first?.to != Seat(.kimi))
check("an instance that can't exist is dropped rather than redirected",
      addressed.count == 1)
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

// --- the interface a delegate signs off with ---
//
// A third fence, and the only one of the three that is written for a person to
// read rather than for this app to parse. It is split off the reply so assembly
// can be handed it whole while the prose around it is bounded — which is the
// point: the list is the contract the lead writes code against, and the prose
// is an account of the work.
let signed = """
Built the animator. It reads TUNING.character for every constant.

```ai-interface
play(name: String, loop: Bool) -> Handle
stop(handle: Handle) -> Void
changed: renamed `run` to `play`; did not build `blend`
```
"""
let interface = MainActor.assumeIsolated { Crew.split(signed, at: Crew.interfaceFence) }
check("an interface block is found under its own fence", interface.1 != nil)
check("and the names survive the split",
      interface.1?.contains("play(name: String, loop: Bool)") == true)
check("including what it renamed, which is the line nothing else can detect",
      interface.1?.contains("changed:") == true)
check("the prose is what is left", interface.0.hasPrefix("Built the animator."))
check("and the block is not in it", !interface.0.contains("changed:"))
check("a plan is not read as an interface", MainActor.assumeIsolated {
    Crew.split(plans, at: Crew.interfaceFence)
}.1 == nil)
check("nor is an interface read as a plan", MainActor.assumeIsolated {
    Crew.split(signed, at: Crew.fence)
}.1 == nil)

// --- a report that runs long ---
//
// Both ends kept, unlike `Verification.excerpt`, and for the opposite reason: a
// compiler puts its cause first, an agent writing up its own work puts the
// caveat last. "I stubbed the parser because the spec was ambiguous" is the
// sentence the lead most needs and the one a head-only trim would cut.
let short = "Wrote the three files. Nothing surprising."
check("a short report is passed through untouched",
      MainActor.assumeIsolated { Crew.condensed(short) } == short)

let rambling = "OPENING. " + String(repeating: "middle ", count: 900) + "CLOSING CAVEAT."
let cut = MainActor.assumeIsolated { Crew.condensed(rambling, limit: 300) }
check("a long one is cut down", cut.count < rambling.count)
check("its opening survives", cut.hasPrefix("OPENING."))
check("and so does its last sentence, which is where the caveat lives",
      cut.hasSuffix("CLOSING CAVEAT."))
check("and it says that something was taken out", cut.contains("not shown"))

// --- roster lines ---
check("a task becomes one line", MainActor.assumeIsolated {
    Crew.gist("Build the procedural city. Use TUNING.city for every constant.")
} == "Build the procedural city")
check("a long unpunctuated task is cut, not dropped", MainActor.assumeIsolated {
    Crew.gist(String(repeating: "x", count: 400))
}.hasSuffix("…"))

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
