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

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
