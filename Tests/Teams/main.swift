// A crew, kept.
//
// The team control exists so nobody has to know that `@kimi#2:k3` is the
// spelling. Making somebody reassemble the same four agents in the next session
// hands that back to them one indirection along — they don't have to type the
// grammar, they have to remember what they typed it as.
//
// What is worth checking is the round trip and the two subtractions. A saved
// team that comes back with a different model, a different instance number, or
// one fewer agent than went in is worse than none: it looks like the team you
// saved, and the work that agent was going to do simply doesn't happen.

import Foundation

var failures = 0
func check(_ label: String, _ ok: Bool) {
    print((ok ? "  ok   " : "  FAIL ") + label)
    if !ok { failures += 1 }
}

// This suite reaches the app's real preference domain, so it works under a name
// nothing else would use and clears up after itself at the end.
let stamp = UUID().uuidString.prefix(8)
func scratch(_ name: String) -> String { "honeycode-test-\(stamp)-\(name)" }

MainActor.assumeIsolated {
    let team = [
        AgentMention.Pick(seat: Seat(.kimi), model: "k3", effort: nil),
        AgentMention.Pick(seat: Seat(.kimi, 2), model: "k3", effort: nil),
        AgentMention.Pick(seat: Seat(.copilot), model: nil, effort: nil),
        AgentMention.Pick(seat: Seat(.work), model: "opus", effort: .max),
    ]

    let saved = TeamStore.save(scratch("frontend"), team)
    check("a team is saved", saved != nil)

    guard let saved else {
        print("\n1 failed"); exit(1)
    }

    let restored = TeamStore.picks(of: saved)
    check("everyone comes back", restored.picks.count == 4)
    check("and nobody was dropped", restored.dropped == 0)

    // The whole point. A restored team that runs different models is a team
    // that looks right and behaves differently.
    check("seats survive, instance numbers included",
          restored.picks.map(\.seat) == team.map(\.seat))
    check("a second instance is still the second instance",
          restored.picks[1].seat == Seat(.kimi, 2))
    check("and is not the first", restored.picks[1].seat != Seat(.kimi))
    check("models survive", restored.picks.map(\.model) == team.map(\.model))
    check("including the absence of one", restored.picks[2].model == nil)
    check("reasoning effort survives", restored.picks[3].effort == .max)

    // The grammar the bar exists to compose. Round-tripping through it is what
    // says a saved team and a typed one are the same thing.
    check("a restored team writes the same mentions",
          restored.picks.map(\.mention) == team.map(\.mention))
    check("and that spelling still parses as a crew",
          AgentMention.parse(restored.picks.map(\.mention).joined(separator: " ") + " do it")
              .crew.map(\.seat) == team.map(\.seat))

    // --- saving over a name ---
    let again = TeamStore.save(saved.name, [AgentMention.Pick(seat: Seat(.personal),
                                                              model: nil, effort: nil)])
    check("saving the same name keeps one team",
          TeamStore.all.filter { $0.name == saved.name }.count == 1)
    check("and keeps its identity rather than making a new one", again?.id == saved.id)
    check("but takes the new members",
          again.map { TeamStore.picks(of: $0).picks.count } == 1)

    // Case and padding are how the same name gets typed twice, not how two
    // teams get told apart.
    TeamStore.save("  " + saved.name.uppercased() + "  ", team)
    check("a name differing by case and spacing is the same name",
          TeamStore.all.filter { $0.name.caseInsensitiveCompare(saved.name) == .orderedSame }
              .count == 1)

    // --- what is refused ---
    check("a team with no name is not saved", TeamStore.save("   ", team) == nil)
    check("a team with nobody on it is not saved",
          TeamStore.save(scratch("empty"), []) == nil)

    // --- renaming ---
    TeamStore.rename(saved.id, to: scratch("renamed"))
    check("renaming keeps the members",
          TeamStore.all.first { $0.id == saved.id }?.members.count == 4)
    check("and changes the name",
          TeamStore.all.first { $0.id == saved.id }?.name == scratch("renamed"))
    check("an empty rename is ignored rather than blanking the row",
          { TeamStore.rename(saved.id, to: "  ")
            return TeamStore.all.first { $0.id == saved.id }?.name == scratch("renamed") }())

    // --- an account that has gone ---
    //
    // `Account(id:)` is total and hands back a `.custom` for a definition that
    // no longer exists, which is right for an orphaned session — its transcript
    // has to stay readable. It is wrong here: this list is about to be sent
    // work, and a phantom launches nothing while occupying a row that says it
    // will. Dropped, and counted, so a caller can say three of four came back.
    let ghost = SavedTeam(id: UUID().uuidString, name: scratch("ghost"), members: [
        SavedTeam.Member(account: .kimi, index: 1, model: nil, effort: nil),
        SavedTeam.Member(account: .custom("no-such-account-\(stamp)"),
                         index: 1, model: nil, effort: nil),
    ])
    let thinned = TeamStore.picks(of: ghost)
    check("an account that no longer exists is dropped", thinned.picks.count == 1)
    check("and the loss is counted, not silent", thinned.dropped == 1)
    check("the survivor is the real one", thinned.picks.first?.seat == Seat(.kimi))

    // A seat number a decoder should never have been able to write. `Seat`
    // clamps in its initialiser and is deliberately not `Codable`, so the way
    // back in goes through the clamp.
    let absurd = SavedTeam(id: UUID().uuidString, name: scratch("absurd"), members: [
        SavedTeam.Member(account: .kimi, index: 99, model: nil, effort: nil),
        SavedTeam.Member(account: .copilot, index: 0, model: nil, effort: nil),
    ])
    let clamped = TeamStore.picks(of: absurd)
    check("an impossible seat number is clamped, not addressed",
          clamped.picks.first?.seat.index == Seat.limit)
    check("and neither is a zeroth seat", clamped.picks.last?.seat.index == 1)

    // --- the one-line summary the list shows ---
    check("a team reads as its mentions",
          TeamStore.summary(of: ghost).contains("@kimi"))

    // --- clean up ---
    for team in TeamStore.all where team.name.hasPrefix("honeycode-test-\(stamp)") {
        TeamStore.remove(team.id)
    }
    check("nothing is left behind",
          !TeamStore.all.contains { $0.name.hasPrefix("honeycode-test-\(stamp)") })
}

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
