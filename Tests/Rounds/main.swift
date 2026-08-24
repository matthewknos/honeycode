// The two things that let a crew stop being one-shot.
//
// A run used to be plan, delegate, assemble, and then everybody went home. That
// is not a limitation a lead worked around — it is one the lead *planned for*.
// Told it has a single chance to hand anything out, a lead keeps every file it
// might conceivably need to touch, and the run that prompted this spent 28% of
// its wall clock with three agents working in parallel and 72% with one agent
// working alone while three paid seats sat idle.
//
// So two changes, and both of them are parsing rather than orchestration:
//
// - a delegation block may carry a `brief`, the part every piece shares, so the
//   lead writes the project preamble once instead of once per delegate;
// - the block itself is now read from the assembly reply as well as the
//   planning one, which is a change to `Crew` proper and not testable here.
//
// What *is* checkable without four live subscriptions is the boundary the brief
// has to hold: it must reach everything that reads a piece for what it contains
// — the tenancy check above all — and reach nothing that reads a piece for what
// it is called. Getting that backwards in the safe-looking direction sends the
// organisation's material past a gate that never saw it.

import Foundation

var failures = 0
func check(_ label: String, _ ok: Bool) {
    print((ok ? "  ok   " : "  FAIL ") + label)
    if !ok { failures += 1 }
}

// --- the shared brief ---

let shared = "PROJECT: a plain HTML5 canvas game. No build step, no ES modules."

let plan = MainActor.assumeIsolated {
    Crew.assignments(#"""
    {"brief":"PROJECT: a plain HTML5 canvas game. No build step, no ES modules.",
     "assignments":[
       {"to":"kimi","task":"Write world.js — terrain and resources."},
       {"to":"kimi#2","task":"Write player.js — inventory and crafting."}
     ]}
    """#)
} ?? Crew.Plan()

check("a block with a brief still parses", plan.assignments.count == 2)
check("and refuses nothing over it", plan.refused.isEmpty)

guard plan.assignments.count == 2 else {
    print("\n\(failures + 1) failed"); exit(1)
}
let world = plan.assignments[0]
let player = plan.assignments[1]

check("every piece carries it", world.brief == shared && player.brief == shared)

// The whole point of keeping the two apart. `task` is what a piece is *called*
// — the roster line each delegate reads, the plan the person skims — and three
// entries that all open with the same four hundred words of preamble are a plan
// nobody can skim.
check("the task itself is untouched", world.task == "Write world.js — terrain and resources.")
check("and stays different from its neighbour's", world.task != player.task)
check("so the one-line gist is still about this piece",
      MainActor.assumeIsolated { Crew.gist(world.task) }.contains("world.js"))
check("and not about the preamble",
      !MainActor.assumeIsolated { Crew.gist(world.task) }.contains("PROJECT"))

// The gist is the roster line every delegate reads to learn what its
// colleagues own, and it used to end the sentence at the first full stop —
// which in "Create the single file .../world.js" is the one inside the
// filename. Three delegates were told their neighbours owned `.../world`,
// `.../player` and `.../entities`.
let named = MainActor.assumeIsolated {
    Crew.gist("Create the single file src/world.js and nothing else. Other rules follow.")
}
check("a full stop inside a filename does not end the sentence",
      named == "Create the single file src/world.js and nothing else")
check("but a real sentence break still does",
      MainActor.assumeIsolated {
          Crew.gist("Build the city. Use TUNING.city for every constant.")
      } == "Build the city")
check("a trailing full stop still ends it",
      MainActor.assumeIsolated { Crew.gist("Write src/player.js.") }
          == "Write src/player.js")
check("and a task with no sentence break is unchanged",
      MainActor.assumeIsolated { Crew.gist("write the parser") } == "write the parser")
check("while an over-long one is still cut to the limit",
      MainActor.assumeIsolated { Crew.gist(String(repeating: "x", count: 400)) }.count == 110)

// `wire` is what a piece *contains*: what the delegate is actually sent, and
// what every check that reads the text has to see.
check("the wire form leads with the brief", world.wire.hasPrefix(shared))
check("and still ends with the task", world.wire.hasSuffix(world.task))
check("with the two kept apart", world.wire.contains("\n\n"))

// No brief is the common case and has to cost nothing — not an empty line, not
// a leading newline, nothing.
let plain = MainActor.assumeIsolated {
    Crew.assignments(#"{"assignments":[{"to":"kimi","task":"just this"}]}"#)
} ?? Crew.Plan()
check("a block with no brief still parses", plain.assignments.count == 1)
check("and its wire form is exactly the task",
      plain.assignments.first?.wire == "just this")
check("with no brief recorded", plain.assignments.first?.brief == nil)

// A brief of whitespace is no brief. It arrives from a model, so the empty
// string is a thing that happens, and prepending it would put a blank line at
// the top of every task for ever.
let blank = MainActor.assumeIsolated {
    Crew.assignments(#"{"brief":"   \n ","assignments":[{"to":"kimi","task":"just this"}]}"#)
} ?? Crew.Plan()
check("a blank brief is no brief", blank.assignments.first?.brief == nil)
check("and doesn't reach the wire", blank.assignments.first?.wire == "just this")

// --- the boundary the brief must not slip past ---
//
// This is the one that matters. `Tenancy` inspects the text of a piece before
// it leaves the organisation, and a lead writing to a shared brief will put the
// project's description — which is exactly where an internal hostname or a
// customer's name lands — in the half that is written once. A gate reading
// `task` alone would wave all of it through while reporting that it checked.

let secret = "Internal: the acme-prod cluster at acme.internal, customer Northwind."
let crossing = MainActor.assumeIsolated {
    Crew.assignments(#"""
    {"brief":"Internal: the acme-prod cluster at acme.internal, customer Northwind.",
     "assignments":[{"to":"kimi","task":"Write a retry helper."}]}
    """#)
} ?? Crew.Plan()

guard let piece = crossing.assignments.first else {
    print("\n\(failures + 1) failed"); exit(1)
}
check("material in the brief is not in the task", !piece.task.contains("acme.internal"))
check("but is in what gets inspected", piece.wire.contains("acme.internal"))
check("all of it", piece.wire.contains(secret))

// --- and the boundary it must not cross the other way ---
//
// The collision check reads the tasks and *not* the brief, which is the
// opposite of the tenancy gate and for a reason that only shows up once a lead
// actually uses a brief. A brief is common ground: every file named in it is
// named in every piece, so it can never tell "two agents independently claimed
// this" from "the lead wrote the layout down once".
//
// The first real plan to use one put its nine-file script load order in the
// brief. Reading it here announced all nine as contested and wrote a ten-line
// "somebody else has this too" warning into all three delegates' instructions —
// a warning that is worth something only while it is rare.
let layout = MainActor.assumeIsolated {
    Crew.assignments(#"""
    {"brief":"Load order: js/state.js, js/world.js, js/ui.js. The lead owns js/state.js.",
     "assignments":[
       {"to":"kimi","task":"Own js/world.js"},
       {"to":"kimi#2","task":"Own js/ui.js"}
     ]}
    """#)
} ?? Crew.Plan()
let quiet = MainActor.assumeIsolated { Crew.overlaps(in: layout.assignments) }
check("a file list in the brief contests nothing", quiet.isEmpty)

// The check still has to work. Two tasks naming one file is the thing it
// exists for, and a brief present must not suppress it.
let clash = MainActor.assumeIsolated {
    Crew.assignments(#"""
    {"brief":"Load order: js/state.js, js/world.js.",
     "assignments":[
       {"to":"kimi","task":"Own js/world.js and js/shared.js"},
       {"to":"kimi#2","task":"Own js/ui.js and js/shared.js"}
     ]}
    """#)
} ?? Crew.Plan()
let real = MainActor.assumeIsolated { Crew.overlaps(in: clash.assignments) }
check("two tasks claiming one file is still caught", real.count == 1)
check("on the file they both named", real.first?.file.contains("shared.js") == true)
check("with both agents on it", real.first?.seats.count == 2)

// --- the grammar still holds with a brief present ---
//
// The brief is a sibling of `assignments`, not a replacement for anything, so
// every refusal the parser made before it existed has to survive it.
let mixed = MainActor.assumeIsolated {
    Crew.assignments(#"""
    {"brief":"shared context",
     "assignments":[
       {"to":"kimi:k3","task":"the city"},
       {"to":"kimi","task":"a second piece for the same seat"},
       {"to":"nobody","task":"who?"},
       {"to":"kimi#2","task":""}
     ]}
    """#)
} ?? Crew.Plan()
check("one piece per seat still holds under a brief", mixed.assignments.count == 1)
check("and the qualifier still resolves", mixed.assignments.first?.model == "k3")
check("a doubled seat is still refused, not dropped",
      mixed.refused.contains { $0.why.contains("already has a piece") })
check("an unknown handle is still refused",
      mixed.refused.contains { $0.to == "nobody" })
check("an empty task is still refused",
      mixed.refused.contains { $0.why == "no task" })
check("and a refused piece carries no brief anywhere",
      mixed.assignments.allSatisfy { $0.brief == "shared context" })

// --- the queue: pieces with no owner ---
//
// The lead cannot tell which piece is the long one. Run 2 of the tower-defence
// measurement split the job three files against four, which looks fair and was
// not: 343 seconds against 667, and the fast delegate then sat idle for 446 of
// the run's 840 while the other worked alone. `queue` is the answer that does
// not require the lead to estimate — extra pieces with no `to`, handed out as
// seats come free.

let queued = MainActor.assumeIsolated {
    Crew.assignments(#"""
    {"brief":"PROJECT: a canvas game.",
     "assignments":[{"to":"kimi#2","task":"Write js/state.js"}],
     "queue":[{"task":"Write js/render.js"},{"task":"Write js/ui.js"}]}
    """#)
} ?? Crew.Plan()
check("a plan may carry both a roster and a queue",
      queued.assignments.count == 1 && queued.backlog.count == 2)
check("the queue keeps the lead's order",
      queued.backlog.map(\.task) == ["Write js/render.js", "Write js/ui.js"])
check("a queued piece refuses nothing", queued.refused.isEmpty)
check("and the brief is carried for it", queued.brief == "PROJECT: a canvas game.")

// A queued piece has no addressee, so the only thing that can carry the brief
// to it is the plan. Losing it here would send an unowned piece out with none
// of the shared context every addressed piece gets.
check("a plan with no brief reports none",
      (MainActor.assumeIsolated {
          Crew.assignments(#"{"assignments":[{"to":"kimi","task":"x"}]}"#)
      } ?? Crew.Plan()).brief == nil)

// Empty entries are noise from a model, not instructions. Dropping them is
// what stops an empty task being handed to a delegate as a whole turn.
let ragged = MainActor.assumeIsolated {
    Crew.assignments(#"""
    {"assignments":[{"to":"kimi","task":"real"}],
     "queue":[{"task":"  "},{"task":"also real"},{"task":""}]}
    """#)
} ?? Crew.Plan()
check("blank queued pieces are dropped", ragged.backlog.map(\.task) == ["also real"])

// `to` on a queued piece is the lead misreading its own grammar. The piece is
// still work, so it runs unowned rather than being refused over a stray field.
let addressed = MainActor.assumeIsolated {
    Crew.assignments(#"""
    {"assignments":[{"to":"kimi","task":"real"}],
     "queue":[{"to":"kimi#3","task":"still work"}]}
    """#)
} ?? Crew.Plan()
check("an addressee on a queued piece is ignored, not refused",
      addressed.backlog.map(\.task) == ["still work"] && addressed.refused.isEmpty)

// --- the files a piece declares ---
//
// The field that turns three regex guesses into facts. Parsed on both halves of
// a plan, because a queued piece is checked against its own files exactly like
// an addressed one.
let declared = MainActor.assumeIsolated {
    Crew.assignments(#"""
    {"assignments":[{"to":"kimi","task":"Write it","writes":["src/a.ts","./src/b.ts"]}],
     "queue":[{"task":"And this","writes":["src/c.ts"]}]}
    """#)
} ?? Crew.Plan()
check("an assignment carries the files it declares",
      declared.assignments.first?.writes == ["src/a.ts", "src/b.ts"])
check("and so does a queued piece, which is checked the same way",
      declared.backlog.first?.writes == ["src/c.ts"])
check("a piece that declares nothing carries an empty list, not a missing one",
      plain.assignments.allSatisfy { $0.writes.isEmpty })

// The declared list reaches the agent. Checking somebody against a list they
// were never shown is marking a paper they did not sit.
check("the declared files go down the wire with the task",
      declared.assignments.first?.wire.contains("src/a.ts") == true)

// The common case, and it has to cost nothing: no queue at all.
check("a plan with no queue has an empty backlog", plan.backlog.isEmpty)
check("and the old grammar is unchanged", plain.backlog.isEmpty)

// --- the round the lead is told it has ---
//
// The cap is a number in two places that must agree: what `Crew` enforces and
// what the briefing promises. A briefing that offers a round the run won't
// dispatch is worse than one that offers none — the lead plans a first round
// around work it intends to hand out later.
let cap = MainActor.assumeIsolated { Crew.waveCap }
check("more than one round is on offer", cap > 1)
check("and it is bounded", cap <= 5)

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
