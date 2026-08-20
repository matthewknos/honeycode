// Where a turn starts, who counts as a crew, and what a turn that died says.
//
// The first two were wrong once in ways nothing caught: `lastTurn` read back to
// the last `.user` item, which the app's lead often doesn't have, and a session
// that mentioned its own handle tried to delegate to itself. The third is a
// turn that produced no words at all, whose only account of itself is whatever
// its CLI wrote to stderr on the way out.

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

// --- what a dead process is allowed to say ---
//
// Verbatim from the run this came out of: a Kimi delegate whose ACP session was
// closed under it. Twelve lines of Node object dump went into the transcript
// and were then shown as the delegate's report, in place of its work.
let crash = """
Error handling request {
  method: 'session/prompt',
  id: 10,
  params: {
    prompt: [ [Object] ],
    sessionId: 'session_8fdb10e2-d16b-4ae3-965a-0e7fb1f6d149'
  },
  jsonrpc: '2.0'
} {
  code: -32603,
  message: 'Internal error',
  data: { details: 'Session is closed' }
}
"""
let gist = Diagnostic.summarise(crash)
check("the sentence buried in the dump is what comes out",
      gist == "Internal error — Session is closed")
check("and the dump itself does not", !gist.contains("jsonrpc"))
check("nor does the session id", !gist.contains("session_8fdb10e2"))
check("a plain complaint is passed through as written",
      Diagnostic.summarise("kimi: command not found") == "kimi: command not found")
check("a program that says nothing is quoted as saying nothing",
      Diagnostic.summarise("   \n  ").isEmpty)
check("and nothing is allowed to take over a transcript",
      Diagnostic.summarise(String(repeating: "x", count: 900)).count <= 200)

// JSON spelling of the same thing, since these are two wire formats away from
// each other and both reach this function.
check("quoted JSON keys read the same as bare ones",
      Diagnostic.summarise(#"{"code":-32603,"message":"Internal error"}"#) == "Internal error")

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
