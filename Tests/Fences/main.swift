// Keeping the wire off the screen.
//
// `ai-delegate` and `ai-message` are transport. Both are rendered properly
// somewhere else — a plan as a labelled list, a question as `@kimi#2 →
// @claude-p — …` — so the raw JSON on screen is never the only copy, just the
// worst one. Four assignments of three hundred words each is what that costs
// when it goes wrong.
//
// The streaming half is where the real risk is: a reply arrives split wherever
// the network split it, so every one of these markers has to be recognised
// having been cut in half first. That is what most of this file is about.

import Foundation

var failures = 0
func check(_ label: String, _ ok: Bool) {
    print((ok ? "  ok   " : "  FAIL ") + label)
    if !ok { failures += 1 }
}

// --- the names match the fences Crew actually writes ---
// Two files, one grammar. If `Crew.fence` were renamed and this weren't, the
// blocks would simply reappear on screen with nothing failing.
check("the delegation fence is one of them",
      MainActor.assumeIsolated { CrewFence.names.contains(Crew.fence) })
check("so is the message fence",
      MainActor.assumeIsolated { CrewFence.names.contains(Crew.messageFence) })

// --- whole-text stripping, for the card renderer ---
let plan = """
Splitting it four ways. I'll keep the swing.

```ai-delegate
{"assignments":[{"to":"kimi#1","task":"the city"}]}
```
"""
check("a delegation block leaves the prose alone",
      CrewFence.hidden(from: plan) == "Splitting it four ways. I'll keep the swing.")

let asks = """
Done — src/city/*.

```ai-message
{"messages":[{"to":"claude-p","text":"which module owns the collider type?"}]}
```
"""
check("so does a message block", CrewFence.hidden(from: asks) == "Done — src/city/*.")

let both = """
One.

```ai-message
{"messages":[]}
```

Two.
"""
check("prose after a block survives", CrewFence.hidden(from: both) == "One.\n\n\nTwo.")

// An ordinary code fence is the whole reason this is by name and not by
// backticks: agents write code, and hiding it would be catastrophic rather
// than untidy.
let code = """
Use this:

```swift
let x = 1
```

That's it.
"""
check("an ordinary code fence is untouched", CrewFence.hidden(from: code) == code)
check("a fence with no marker at all is untouched",
      CrewFence.hidden(from: "```\nplain\n```") == "```\nplain\n```")
check("text with no fences is returned as it came",
      CrewFence.hidden(from: "just prose") == "just prose")

// A turn that stopped mid-block has no prose after it to lose.
check("an unclosed block runs to the end",
      CrewFence.hidden(from: "Prose.\n```ai-delegate\n{\"assign") == "Prose.")

// --- the partial-line rule ---
check("a bare backtick could still become an opener", CrewFence.mightOpen("`"))
check("and so could three", CrewFence.mightOpen("```"))
check("and a half-written name", CrewFence.mightOpen("```ai-mes"))
check("a complete opener is still held until its newline",
      CrewFence.mightOpen("```ai-message"))
check("another language is released at once", !CrewFence.mightOpen("```swift"))
check("prose is never held", !CrewFence.mightOpen("that's it."))
check("nothing is not something", !CrewFence.mightOpen(""))
check("nothing longer than an opener is ever held",
      !CrewFence.mightOpen("```ai-message-with-more"))

// --- streaming, one byte at a time ---
//
// The worst split there is: every marker cut at every character. What comes out
// must be what `hidden` would have produced from the whole thing.
func streamed(_ text: String, chunk: Int) -> String {
    let scrollback = MainActor.assumeIsolated { Scrollback(.cli(speaker: "kimi")) }
    let id = UUID()
    var sent = ""
    var out = ""
    let characters = Array(text)
    var index = 0
    while index < characters.count {
        let end = min(index + chunk, characters.count)
        sent += String(characters[index..<end])
        index = end
        let runs = MainActor.assumeIsolated {
            scrollback.drain(items: [.assistant(id: id, text: sent)])
        }
        out += runs.filter { $0.style == .prose }.map(\.text).joined()
    }
    return out
}

let reply = """
Done — src/city/*, 9 files. The collider set is exported.

```ai-message
{"messages":[{"to":"claude-p","text":"which module owns CityChunkHandle?"}]}
```
"""
for chunk in [1, 2, 3, 7, 13, 14, 500] {
    let got = streamed(reply, chunk: chunk).trimmingCharacters(in: .whitespacesAndNewlines)
    let want = "Done — src/city/*, 9 files. The collider set is exported."
    check("split every \(chunk) character\(chunk == 1 ? "" : "s"), the block never shows",
          got == want)
}

// The same guarantee for code, from the other direction: nothing of it may be
// eaten, at any split.
let withCode = "Here:\n\n```swift\nlet x = 1\n```\n\ndone.\n"
for chunk in [1, 3, 8] {
    check("code survives a split every \(chunk)",
          streamed(withCode, chunk: chunk) == withCode)
}

// Two blocks in one turn, and prose between them.
let twice = """
First.

```ai-message
{"messages":[{"to":"kimi#2","text":"a"}]}
```

Second.

```ai-message
{"messages":[{"to":"kimi#3","text":"b"}]}
```
"""
check("a second block is hidden as readily as the first",
      streamed(twice, chunk: 5).contains("First.")
        && streamed(twice, chunk: 5).contains("Second.")
        && !streamed(twice, chunk: 5).contains("messages"))

// --- the fast path ---
//
// `hidden` is guarded by a scan for "```ai-" so that a reply full of ordinary
// code fences — which is most of what a coding agent writes — doesn't split and
// rejoin its whole text on every redraw to rebuild the string it was given.
// What matters is that narrowing the guard didn't narrow the behaviour.
let ordinary = """
Here is the fix.

```swift
let x = 1
```

And an indented one:

    ```ai-delegate-lookalike
"""
check("a reply with only ordinary code fences comes back unchanged",
      CrewFence.hidden(from: ordinary) == ordinary)
check("text with no fence at all comes back unchanged",
      CrewFence.hidden(from: "just prose, no fences") == "just prose, no fences")
check("an empty string survives", CrewFence.hidden(from: "") == "")
check("text shorter than the opener survives", CrewFence.hidden(from: "``") == "``")

// And the guard must not let a real transport block through.
let transport = """
Splitting it three ways.

```ai-delegate
{"assignments":[{"to":"kimi","task":"the city"}]}
```
"""
check("a transport block is still taken out",
      !CrewFence.hidden(from: transport).contains("assignments"))
check("while the prose above it stays",
      CrewFence.hidden(from: transport).hasPrefix("Splitting it three ways."))
// The opener has to be a line of its own, which is what `opens` requires — the
// byte scan only decides whether it is worth looking.
check("an opener mentioned mid-sentence hides nothing",
      CrewFence.hidden(from: "I would write ```ai-delegate here") ==
      "I would write ```ai-delegate here")

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
