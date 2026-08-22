// What Tab offers, what the slash commands parse to, and what the up-arrow
// remembers.
//
// These are the three parts of the terminal client that are logic rather than
// escape codes, and they are here because the rest of it can't be. A line
// editor is a loop over `read(2)` against a tty in raw mode: there is no tty in
// a test run, and a fake one would be testing the fake. So the editor is kept
// as thin as it can be — it decodes a keypress and calls one of these — and
// everything it calls is a pure function of a string, a cursor and a directory.
//
// The account-facing half runs against a scratch preferences domain, for the
// reason `Tests/Setup` gives at more length: `Account.enabled` reads the domain
// the Honeycode you are using right now writes, and a suite that proved
// completion works by switching your Copilot off would be a poor trade.

import Foundation

var failures = 0
func check(_ label: String, _ ok: Bool) {
    print((ok ? "  ok   " : "  FAIL ") + label)
    if !ok { failures += 1 }
}

let work = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("honeycode-cli-\(ProcessInfo.processInfo.processIdentifier)")
try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }

// --- the slash commands ---

check("a bare command parses", Commands.parse("/help")?.command.name == "help")
check("and carries no argument", Commands.parse("/help")?.argument == "")
check("an argument comes through", Commands.parse("/models copilot")?.argument == "copilot")
check("so does one with spaces around it",
      Commands.parse("/models   copilot  ")?.argument == "copilot")
check("aliases reach the same command", Commands.parse("/q")?.command.name == "quit")
check("case doesn't matter", Commands.parse("/HELP")?.command.name == "help")
check("a name nobody has is not a command", Commands.parse("/nope") == nil)
check("and neither is prose", Commands.parse("hello") == nil)

// The one that matters. A message may perfectly well start with a path, and
// eating it as an unknown command would lose the message.
check("a path is not a command", Commands.parse("/usr/bin/env is a path") == nil)

check("every command is spelled somewhere in help",
      Commands.all.allSatisfy { command in
          Help.lines.contains { $0.contains(command.usage) }
      })

// --- longest common prefix ---

func offer(_ candidates: [String]) -> Completion {
    Completion(candidates: candidates, range: 0..<0)
}
check("one candidate is its own prefix", offer(["/models"]).shared == "/models")
check("a shared prefix is found", offer(["abcd", "abce"]).shared == "abc")
check("nothing shared is nothing offered", offer(["abc", "xyz"]).shared == "")
check("a candidate that is a prefix of another wins",
      offer(["ab", "abc"]).shared == "ab")

// --- completing a command ---

let commands = Completions.of("/mod", at: 4, directory: work)
check("a command completes", commands?.candidates == ["/models"])
check("over the whole token", commands?.range == 0..<4)
check("and lands on the full name", commands?.shared == "/models")
check("a lone slash offers all of them",
      Completions.of("/", at: 1, directory: work)?.candidates.count == Commands.spellings.count)

// A slash is only a command at the start of a line. `and/or` must not become
// `/accounts`, and the second word of a sentence is not a command either.
check("a slash mid-line is not a command",
      Completions.of("do /mod", at: 7, directory: work)?.candidates.contains("/models") != true)

// --- completing a handle ---

let domain = "com.matthewquigley.honeycode.tests.cli"
let scratch = UserDefaults(suiteName: domain)!
scratch.removePersistentDomain(forName: domain)
Setup.store = scratch
defer { scratch.removePersistentDomain(forName: domain) }
for account in [Account.personal, .work, .kimi, .copilot] {
    Account.setEnabled(true, for: account)
}

let handles = Completions.of("@cl", at: 3, directory: work)
check("a handle completes", handles?.candidates.contains("@claude-p") == true)
check("including the other one", handles?.candidates.contains("@claude-w") == true)
check("and the aliases somebody may already type",
      handles?.candidates.contains("@claude-personal") == true)
check("as far as they agree", handles?.shared.hasPrefix("@claude-") == true)
check("over the whole mention", handles?.range == 0..<3)
check("an account switched off is not offered", {
    Account.setEnabled(false, for: .copilot)
    defer { Account.setEnabled(true, for: .copilot) }
    return Completions.of("@cop", at: 4, directory: work)?
        .candidates.contains("@copilot") != true
}())

// Mid-sentence, which is where mentions actually get typed.
let late = Completions.of("a site for a dentist @kim", at: 25, directory: work)
check("a mention completes where it sits", late?.candidates.contains("@kimi") == true)
check("replacing only the mention", late?.range == 21..<25)

// --- completing a qualifier ---

let intent = Completions.of("hi @kimi:fr", at: 11, directory: work)
check("an intent completes", intent?.candidates.contains("free") == true)
check("over the qualifier alone, not the mention", intent?.range == 9..<11)

check("effort levels are offered on a Claude account",
      Completions.of("@claude-p:ma", at: 12, directory: work)?
        .candidates.contains("max") == true)
check("and not on one that has none",
      Completions.of("@kimi:ma", at: 8, directory: work)?
        .candidates.contains("max") != true)
check("a second qualifier completes after the first",
      Completions.of("@claude-p:opus:ma", at: 17, directory: work)?.range == 15..<17)
check("an unknown handle still offers the intents",
      Completions.qualifiers(for: "nobody").contains("free"))

// --- completing a path ---

let alphabet = work.appendingPathComponent("alphabet")
try? FileManager.default.createDirectory(at: alphabet, withIntermediateDirectories: true)
for (name, at) in [("alpha.txt", work), ("beta.txt", work), (".hidden", work),
                   ("inner.txt", alphabet), (".secret", alphabet)] {
    _ = FileManager.default.createFile(atPath: at.appendingPathComponent(name).path,
                                       contents: Data("x".utf8))
}

let paths = Completions.of("al", at: 2, directory: work)
check("a bare word completes to a file", paths?.candidates.contains("alpha.txt") == true)
check("a directory is marked as one", paths?.candidates.contains("alphabet/") == true)
check("as far as the names agree", paths?.shared == "alpha")
check("an empty token completes to nothing at all",
      Completions.of("", at: 0, directory: work) == nil)

// The hidden-file rule only bites where the prefix filter wouldn't have caught
// it anyway: inside a directory, where everything matches the token so far.
check("a path descends", Completions.of("alphabet/", at: 9, directory: work)?
        .candidates == ["alphabet/inner.txt"])
check("and leaves the dotfiles in it alone",
      Completions.of("alphabet/", at: 9, directory: work)?
        .candidates.contains("alphabet/.secret") != true)
check("until you ask for one",
      Completions.of("alphabet/.", at: 10, directory: work)?
        .candidates == ["alphabet/.secret"])
check("which goes for the top level too",
      Completions.of(".", at: 1, directory: work)?.candidates == [".hidden"])
check("a partial inside a directory narrows",
      Completions.of("alphabet/in", at: 11, directory: work)?.shared == "alphabet/inner.txt")
check("a name nothing matches offers nothing",
      Completions.of("zzz", at: 3, directory: work) == nil)

// --- what Tab then does to the line ---

/// The editor's whole Tab handler, minus the drawing.
///
/// Returned as one string with the caret written into it, so a failure says
/// where the cursor actually landed instead of just that it didn't match.
func tab(_ line: String, at cursor: Int) -> String? {
    guard let completion = Completions.of(line, at: cursor, directory: work),
          let applied = completion.applied(to: Array(line)) else { return nil }
    var out = applied.line
    out.insert("|", at: applied.cursor)
    return String(out)
}

check("a lone candidate is completed and spaced", tab("@kim", at: 4) == "@kimi |")
check("an ambiguous one goes as far as it can, and no further",
      tab("@cl", at: 3) == "@claude-|")
check("a fork between two files stops at the fork", tab("al", at: 2) == "alpha|")
check("a directory gets its slash and no space",
      tab("alphabet", at: 8) == "alphabet/|")
check("a qualifier completes in place",
      tab("hi @kimi:fr", at: 11) == "hi @kimi:free |")
check("a command completes to a command", tab("/mod", at: 4) == "/models |")
check("a second qualifier completes too",
      tab("@claude-p:opus:ma", at: 17) == "@claude-p:opus:max |")

// The one that was wrong before this moved out of the editor: a mention
// completed mid-sentence used to gain a space it already had.
check("completing mid-line keeps the tail, and adds no second space",
      tab("ask @kim about the plan", at: 8) == "ask @kimi| about the plan")
check("nothing to offer changes nothing", tab("zzz", at: 3) == nil)
check("a prefix with nothing left to add inserts nothing", tab("@claude-", at: 8) == nil)

// --- history ---

let file = work.appendingPathComponent("history")
let history = History(file: file)
history.add("one")
history.add("two")
history.add("two")
check("history keeps what was typed", history.entries == ["one", "two"])
check("and not the same thing twice in a row", history.entries.count == 2)
history.add("   ")
check("blank lines are not history", history.entries == ["one", "two"])

check("up walks back", history.previous(from: "draft") == "two")
check("and keeps walking", history.previous(from: "two") == "one")
check("and stops at the end", history.previous(from: "one") == nil)
check("down walks forward", history.next() == "two")
check("and returns what you were typing", history.next() == "draft")
check("and stops there", history.next() == nil)

check("a new prompt starts at the bottom", {
    history.rewind()
    return history.previous(from: "") == "two"
}())

check("history survives the process", History(file: file).entries == ["one", "two"])

check("a pasted newline does not become two entries", {
    let pasted = History(file: work.appendingPathComponent("pasted"))
    pasted.add("first\nsecond")
    return pasted.entries == ["first second"]
}())

check("history is capped", {
    let long = History(file: work.appendingPathComponent("long"))
    for index in 0..<600 { long.add("line \(index)") }
    return long.entries.count == 500 && long.entries.first == "line 100"
}())

// The file holds everything anybody has ever asked an agent to do. It is not
// a secret store and does not pretend to be one, but it has no business being
// world-readable either.
check("history is owner-only", {
    let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
    return (attributes?[.posixPermissions] as? NSNumber)?.intValue == 0o600
}())

print(failures == 0 ? "  all good" : "  \(failures) failed")
exit(failures == 0 ? 0 : 1)
