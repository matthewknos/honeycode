// Two agents given the same file.
//
// The lead's briefing carries exactly one rule stated as an absolute — "Two
// agents must never be given the same file" — and the reason beside it: nothing
// locks a file, so the second write wins and the first agent's work is gone
// with no error in either transcript. Nothing checked that the rule held, which
// made it the one part of a plan that could be wrong in a way no one would ever
// find out about: the lead assembles believing both pieces landed, and the
// ledger counts both agents as having written files, because both did.
//
// Checked in both directions, because they answer different questions. The plan
// can be read before anyone starts, which is the only moment where knowing is
// free. What was actually written can only be counted afterwards, and catches
// the overlap nobody declared.

import Foundation

var failures = 0
func check(_ label: String, _ ok: Bool) {
    print((ok ? "  ok   " : "  FAIL ") + label)
    if !ok { failures += 1 }
}

// --- what counts as the same path ---
//
// Almost nothing is done here on purpose, and the one thing that is *not* done
// matters most: `~` is left alone. Both adapters record an edited file as the
// absolute path with $HOME written back as `~`, so measured paths already agree
// across agents running on different CLIs, and expanding them would only make a
// report harder to read.
MainActor.assumeIsolated {
    check("a plain path is left as it is",
          Crew.comparable("src/city/mesh.ts") == "src/city/mesh.ts")
    check("a leading ./ is not a different file",
          Crew.comparable("./src/city/mesh.ts") == "src/city/mesh.ts")
    check("a path quoted in prose is the same path",
          Crew.comparable("`src/city/mesh.ts`,") == "src/city/mesh.ts")
    check("a trailing slash is dropped",
          Crew.comparable("src/city/") == "src/city")
    check("a tilde is preserved, not expanded",
          Crew.comparable("~/Desktop/skyline/a.ts") == "~/Desktop/skyline/a.ts")
}

// --- the plan, read before anyone starts ---
MainActor.assumeIsolated {
    func piece(_ seat: Seat, _ task: String) -> CrewAssignment {
        CrewAssignment(to: seat, task: task, model: nil, effort: nil)
    }

    // The shape this exists for: a lead that splits by subsystem and gives two
    // of them the same shared types file to "add your types to".
    let clash = [
        piece(Seat(.kimi), "Build the city mesh in src/city/mesh.ts. "
                         + "Add your types to src/shared/types.ts."),
        piece(Seat(.copilot), "Build the character animator in src/character/animator.ts. "
                            + "Add your types to src/shared/types.ts."),
    ]
    let found = Crew.overlaps(in: clash)
    check("a file two pieces both name is found", found.count == 1)
    check("and it is the shared one, not the pieces' own files",
          found.first?.file == "src/shared/types.ts")
    check("both holders are named", found.first?.seats == [Seat(.kimi), Seat(.copilot)])

    // The ordinary plan, which is most of them.
    let clean = [
        piece(Seat(.kimi), "Build src/city/mesh.ts."),
        piece(Seat(.copilot), "Build src/character/animator.ts."),
    ]
    check("a plan that splits cleanly reports nothing", Crew.overlaps(in: clean).isEmpty)

    // A task naming its own file more than once is not in conflict with itself.
    // Getting this wrong would warn on almost every plan, and a warning that
    // fires constantly is one nobody reads.
    let repeated = [piece(Seat(.kimi), "Write src/a.ts. Then re-read src/a.ts and check it.")]
    check("one task naming a file twice is not a collision",
          Crew.overlaps(in: repeated).isEmpty)

    // Two spellings of one path are one path.
    let spelled = [
        piece(Seat(.kimi), "Edit ./src/shared/types.ts"),
        piece(Seat(.copilot), "Edit `src/shared/types.ts`"),
    ]
    check("the same file written two ways still collides",
          Crew.overlaps(in: spelled).count == 1)

    // Three of them on one file is one overlap naming three, not three overlaps.
    let crowd = [
        piece(Seat(.kimi), "src/shared/types.ts"),
        piece(Seat(.kimi, 2), "src/shared/types.ts"),
        piece(Seat(.copilot), "src/shared/types.ts"),
    ]
    let many = Crew.overlaps(in: crowd)
    check("three on one file is one finding", many.count == 1)
    check("naming all three", many.first?.seats.count == 3)

    // A file named because it must be *read* collides with one named because
    // it must be written, and nothing here can tell them apart. Recorded rather
    // than fixed: this is what the first live run did — the lead kept the shared
    // types file and told all three delegates to ask it about that file, so all
    // three tasks named it and none of them was going to touch it. It is why
    // the plan-time finding is worded as "named in more than one piece" and
    // reported as a note, while the measured one is stated as fact.
    let referenced = [
        piece(Seat(.kimi), "Write src/render.ts. Ask the lead about src/shared/types.ts "
                         + "rather than guessing what it exposes."),
        piece(Seat(.copilot), "Write src/report.ts. Ask the lead about src/shared/types.ts "
                            + "rather than guessing what it exposes."),
    ]
    check("a file two pieces merely refer to is found too — known, and why the "
          + "wording is careful",
          Crew.overlaps(in: referenced).count == 1)

    // Seats, not accounts. Two Kimis are two agents, and the whole reason a
    // plan can say "four ways" is that they are told apart everywhere else.
    let siblings = [
        piece(Seat(.kimi), "Edit src/shared/types.ts"),
        piece(Seat(.kimi, 2), "Edit src/shared/types.ts"),
    ]
    check("two instances of one subscription can collide with each other",
          Crew.overlaps(in: siblings).count == 1)
}

// --- what was written, counted afterwards ---
MainActor.assumeIsolated {
    var evidence: [Seat: Crew.Work] = [:]
    evidence[Seat(.kimi)] = Crew.Work(files: ["~/p/src/city/mesh.ts",
                                              "~/p/src/shared/types.ts"], tools: 4)
    evidence[Seat(.copilot)] = Crew.Work(files: ["~/p/src/character/animator.ts",
                                                 "~/p/src/shared/types.ts"], tools: 3)
    let order = [Seat(.kimi), Seat(.copilot)]

    let written = Crew.overlaps(inWork: evidence, over: order)
    check("a file both of them wrote is found", written.count == 1)
    check("and it is the shared one", written.first?.file == "~/p/src/shared/types.ts")
    check("in roster order", written.first?.seats == order)

    // Nobody overlapping is the common case and must be silent.
    var apart: [Seat: Crew.Work] = [:]
    apart[Seat(.kimi)] = Crew.Work(files: ["a.ts"], tools: 1)
    apart[Seat(.copilot)] = Crew.Work(files: ["b.ts"], tools: 1)
    check("separate files report nothing",
          Crew.overlaps(inWork: apart, over: order).isEmpty)

    // A confined delegate has a scratch directory of its own, so two of them
    // writing the same *name* are writing two different files. Excluded rather
    // than compared — their absolute paths would already say so, and this does
    // not depend on that staying true of every adapter.
    var confined: [Seat: Crew.Work] = [:]
    confined[Seat(.kimi)] = Crew.Work(files: ["notes.md"], tools: 1)
    confined[Seat(.copilot)] = Crew.Work(files: ["notes.md"], tools: 1)
    check("two confined delegates writing one filename are not in conflict",
          Crew.overlaps(inWork: confined, over: order,
                        excluding: [Seat(.kimi), Seat(.copilot)]).isEmpty)
    check("but the same two unconfined are",
          Crew.overlaps(inWork: confined, over: order).count == 1)

    // A seat that reported nothing cannot collide with anyone.
    var lonely: [Seat: Crew.Work] = [:]
    lonely[Seat(.kimi)] = Crew.Work(files: ["a.ts"], tools: 1)
    check("a seat with no evidence is skipped rather than crashed into",
          Crew.overlaps(inWork: lonely, over: order).isEmpty)
}

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
