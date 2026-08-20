// What a delegate did, as against what it said it did.
//
// The run that prompted this handed `@kimi#2` the character and animation
// system. It replied "I'll start by reading the shared config and types files",
// wrote no files, and the lead assembled around it and never mentioned the
// subsystem again — a quarter of its own plan missing, with a paragraph in the
// report where the evidence should have been. So the report now carries a count
// this app takes itself, and the only thing worth checking here is that the
// count is honest: nothing written and nothing run must be distinguishable from
// work, at the point where the two look identical in prose.

import Foundation

var failures = 0
func check(_ label: String, _ ok: Bool) {
    print((ok ? "  ok   " : "  FAIL ") + label)
    if !ok { failures += 1 }
}

MainActor.assumeIsolated {
    let s = Session(account: .kimi, directory: URL(fileURLWithPath: "/tmp"), name: "t")

    // A turn that talked and did nothing. This is `@kimi#2`, verbatim.
    s.items = [.assistant(id: UUID(),
                          text: "I'll start by reading the shared config and types files.")]
    let idle = Crew.work(of: s, from: 0)
    check("prose alone is not work", idle.isEmpty)
    check("and no files are claimed", idle.files.isEmpty)
    check("nothing was built", idle.wroteNothing)

    // The case the first version of this missed. `@kimi#2` said it would start
    // by reading the shared config and types files, did exactly that, and was
    // not retried — reads are tool calls, so "wrote nothing AND ran nothing"
    // was false, so a whole module stayed missing. Reading is not building.
    let reader = Session(account: .kimi, directory: URL(fileURLWithPath: "/tmp"), name: "r")
    reader.items = [
        .assistant(id: UUID(), text: "I'll start by reading the shared config and types files."),
        .tool(id: UUID(), toolUseID: "1", name: "Read", target: "src/config/tuning.ts",
              detail: "", state: .applied),
        .tool(id: UUID(), toolUseID: "2", name: "Read", target: "src/core/types.ts",
              detail: "", state: .applied),
    ]
    let read = Crew.work(of: reader, from: 0)
    check("reading is running something", !read.isEmpty)
    check("but reading is not building", read.wroteNothing)

    // A file written by shell redirection leaves no diff to count, so it must
    // not be mistaken for idleness — paying twice for work already on disk is
    // the one mistake this must not make on its own.
    let redirect = Session(account: .kimi, directory: URL(fileURLWithPath: "/tmp"), name: "w")
    redirect.items = [.tool(id: UUID(), toolUseID: "3", name: "Bash",
                            target: "cat > src/character/poses.ts <<EOF",
                            detail: "", state: .applied)]
    check("a redirect counts as possibly having written",
          !Crew.work(of: redirect, from: 0).wroteNothing)

    // An ordinary command is not a write, or nothing would ever be retried.
    let checked = Session(account: .kimi, directory: URL(fileURLWithPath: "/tmp"), name: "c")
    checked.items = [.tool(id: UUID(), toolUseID: "4", name: "Bash",
                           target: "npx tsc --noEmit", detail: "", state: .applied)]
    check("running the typechecker is not writing",
          Crew.work(of: checked, from: 0).wroteNothing)

    // A turn that wrote.
    let mark = s.items.count
    s.items.append(.diff(id: UUID(), toolUseID: "a", file: "/p/src/city/lod.ts",
                         rows: [], state: .applied))
    s.items.append(.tool(id: UUID(), toolUseID: "b", name: "Bash", target: "npx tsc",
                         detail: "", state: .applied))
    s.items.append(.diff(id: UUID(), toolUseID: "c", file: "/p/src/city/chunk.ts",
                         rows: [], state: .applied))
    // The same file twice is one file — an agent that edits `lod.ts` four times
    // has changed one thing, and counting four would flatter it.
    s.items.append(.diff(id: UUID(), toolUseID: "d", file: "/p/src/city/lod.ts",
                         rows: [], state: .applied))

    let did = Crew.work(of: s, from: mark)
    check("files are counted", did.files.count == 2)
    check("the same file twice is one file", Set(did.files).count == did.files.count)
    check("order is the order they were touched", did.files.first?.hasSuffix("lod.ts") == true)
    check("commands are counted apart from files", did.tools == 1)
    check("that is not empty", !did.isEmpty)

    // The mark is what separates one turn from the last. A delegate that worked
    // and then answered a question must not have its work forgotten, nor the
    // previous turn's counted twice.
    check("everything before the mark is somebody else's turn",
          Crew.work(of: s, from: s.items.count).isEmpty)
    check("from zero, the whole session counts", Crew.work(of: s, from: 0).files.count == 2)

    // Ran commands but recorded no edits — a real case (shell redirection
    // writes no diff item) and deliberately *not* reported as having done
    // nothing, because that claim would be false.
    let shell = Session(account: .kimi, directory: URL(fileURLWithPath: "/tmp"), name: "u")
    shell.items = [.tool(id: UUID(), toolUseID: "x", name: "Bash",
                         target: "cat > src/character/rig.ts <<EOF",
                         detail: "", state: .applied)]
    let redirected = Crew.work(of: shell, from: 0)
    check("a shell write is not counted as a file", redirected.files.isEmpty)
    check("but it is not nothing either", !redirected.isEmpty)
}

// --- how many questions a run may spend ---
//
// Measured on the run this came from: eight questions asked, five refused, and
// four of the five from the one agent doing the most coordinating. Every
// question it got to ask landed something concrete; then a flat cap of eight —
// two each across four delegates — cut it off for the rest of the run. A budget
// that binds before the per-agent allowance does isn't a budget, it's a
// ceiling nobody could see.
func cap(_ n: Int) -> Int { MainActor.assumeIsolated { Crew.mailCap(for: n) } }
check("a solo run keeps the old floor", cap(0) == 8)
check("and so does a pair", cap(1) == 8)
check("four delegates get more than four questions", cap(4) > 8)
check("it scales with the crew, counting the lead",
      cap(4) == 15 && cap(2) == 9)
check("it never shrinks as the crew grows",
      (0...8).allSatisfy { cap($0) <= cap($0 + 1) })

// --- where a re-issued piece goes ---
//
// A delegate that produced nothing gets its piece handed out once more, and
// preferably to a fresh instance: the first attempt ended without doing
// anything, and whatever state its CLI is in is the state that produced that.
// A new seat is a new process. When there is no room the original is asked
// again, which is better than dropping the piece.
func spare(_ taken: [Seat]) -> Seat? {
    MainActor.assumeIsolated { Crew.spareSeat(on: .kimi, taken: Set(taken)) }
}
check("a fresh instance is found beside the ones running",
      spare([Seat(.kimi), Seat(.kimi, 2)]) == Seat(.kimi, 3))
check("a gap is reused rather than climbed past",
      spare([Seat(.kimi), Seat(.kimi, 3)]) == Seat(.kimi, 2))
check("a full account has none to spare",
      spare((1...Seat.limit).map { Seat(.kimi, $0) }) == nil)
check("another subscription's seats are not this one's",
      spare([Seat(.copilot), Seat(.copilot, 2), Seat(.work)]) == Seat(.kimi))
check("the lead's own seat counts as taken",
      MainActor.assumeIsolated {
          Crew.spareSeat(on: .personal, taken: [Seat(.personal)])
      } == Seat(.personal, 2))
check("nothing running means the first instance",
      spare([]) == Seat(.kimi))

// --- the files a task names ---
//
// The lead is required to name the exact files each delegate owns, so the task
// text says what the piece is in a form that can be checked against a disk.
// This is what tells "nothing to do" from "did nothing" — a distinction a live
// run cost real money to discover.
let task = """
Build the camera for SKYLINE at /Users/x/skyline. You own ONLY these files:
src/camera/springArm.ts, src/camera/index.ts and src/input/keyboard.ts.
Import from src/config/tuning.ts, never edit it. Verify with npx tsc --noEmit.
"""
let named = MainActor.assumeIsolated { Crew.namedFiles(in: task) }
check("the files it owns are found", named.contains("src/camera/springArm.ts"))
check("and the ones it must import from", named.contains("src/config/tuning.ts"))
check("a bare command is not a file", !named.contains { $0.contains("tsc") })
check("nothing without a slash is taken for a path",
      named.allSatisfy { $0.contains("/") })
check("a plain sentence names no files",
      MainActor.assumeIsolated { Crew.namedFiles(in: "Write the animator, please.") }.isEmpty)
check("duplicates collapse", MainActor.assumeIsolated {
    Crew.namedFiles(in: "edit a/b.ts then a/b.ts again")
} == ["a/b.ts"])

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
