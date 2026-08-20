// Where a turn starts, and who counts as a crew.
//
// Both were wrong once in ways nothing caught: `lastTurn` read back to the last
// `.user` item, which the app's lead often doesn't have, and a session that
// mentioned its own handle tried to delegate to itself.

import Foundation

var failures = 0
func check(_ label: String, _ ok: Bool) {
    print((ok ? "  ok   " : "  FAIL ") + label)
    if !ok { failures += 1 }
}

MainActor.assumeIsolated {
    let s = Session(account: .personal, directory: URL(fileURLWithPath: "/tmp"), name: "t")

    // A turn with no `.user` item in front of it — the app's lead, whose
    // briefing is plumbing the person never typed.
    s.items = [.assistant(id: UUID(), text: "old answer")]
    let mark = s.items.count
    s.items.append(.assistant(id: UUID(), text: "the plan"))
    s.items.append(.notice(id: UUID(), text: "a notice in the middle"))
    s.items.append(.assistant(id: UUID(), text: "and the rest"))

    check("mark excludes the earlier turn",
          Crew.lastTurn(of: s, from: mark) == "the plan\n\nand the rest")
    check("a mark at the end reads nothing",
          Crew.lastTurn(of: s, from: s.items.count) == "")
    check("mark 0 reads everything",
          Crew.lastTurn(of: s, from: 0).hasPrefix("old answer"))
    // A mark left over from a cleared transcript must not trap.
    s.items = []
    check("a stale mark past the end is survivable", Crew.lastTurn(of: s, from: 99) == "")

    // The GUI rule: mentions are delegates, the session leads, self-mentions drop.
    func delegates(_ text: String, in account: Account) -> [Account] {
        AgentMention.parse(text).crew.map(\.account).filter { $0 != account }
    }
    check("a self-mention is not a crew",
          delegates("@claude-p tidy this", in: .personal).isEmpty)
    check("another agent is",
          delegates("@kimi tidy this", in: .personal) == [.kimi])
    check("the lead's own handle drops out of the crew",
          delegates("@claude-w and @kimi", in: .work) == [.kimi])
    check("a file mention is not an agent",
          delegates("look at @Sources/AgentKit/Crew.swift", in: .personal).isEmpty)
    check("plain prose is not a crew",
          delegates("what does this do", in: .personal).isEmpty)
}

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
