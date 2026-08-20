// The project's own opinion of the work.
//
// A crew used to end on three accounts of itself and all three were somebody's:
// the delegates said what they did, the lead read that and assembled, and the
// ledger counted files — which is measured, but only says bytes moved. A file
// can be written, counted, reported and not compile. The tell was that after
// the first real crew run the person who asked for it left the app and ran
// `npx tsc --noEmit` by hand.
//
// Most of what is checked here is judgement about what a command's exit status
// *means*, because that is where this can be wrong in the expensive direction:
// reporting a missing compiler as "your work doesn't build" sends the lead off
// to rewrite code that was fine. The last section runs real processes, because
// the deadline is the one part whose failure mode is a crew run that never
// ends, and nothing short of running it would establish that it works.

import Foundation

var failures = 0
func check(_ label: String, _ ok: Bool) {
    print((ok ? "  ok   " : "  FAIL ") + label)
    if !ok { failures += 1 }
}

let fm = FileManager.default
let root = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("honeycode-checks-\(UUID().uuidString)")
try? fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }

func write(_ name: String, _ contents: String = "") {
    try? contents.write(to: root.appendingPathComponent(name),
                        atomically: true, encoding: .utf8)
}
func remove(_ name: String) {
    try? fm.removeItem(at: root.appendingPathComponent(name))
}

// --- what a project declares for itself ---
//
// A file in the repository rather than a setting on one machine, so a team that
// clones this gets the same check as the person who set it up.
write(Verification.manifest, """
# how this project is checked — see the README
npm run typecheck
npm run lint
""")
check("the declared command is read",
      Verification.declared(in: root) == "npm run typecheck")
check("a comment is not a command",
      Verification.declared(in: root)?.hasPrefix("#") == false)
check("and only the first one is taken",
      Verification.declared(in: root) != "npm run lint")

// A file that is nothing but comments declares nothing, rather than declaring
// a comment.
write(Verification.manifest, "# nothing yet\n\n")
check("a file with no command in it declares none", Verification.declared(in: root) == nil)
remove(Verification.manifest)
check("no file at all declares none", Verification.declared(in: root) == nil)

// --- what a manifest implies ---
check("an empty directory implies no check", Verification.detected(in: root) == nil)

write("tsconfig.json", "{}")
check("a tsconfig means a typecheck",
      Verification.detected(in: root)?.display == "tsc --noEmit")
// Not `npm run build`: a crew's output is to be inspected, not installed, and
// a build on a half-finished tree writes artefacts and can publish.
check("and it is a check, not a build",
      Verification.detected(in: root)?.command.contains("--noEmit") == true)
// Without this a project with a tsconfig and no local TypeScript quietly
// downloads a compiler in the middle of a run.
check("and it will not install anything to do it",
      Verification.detected(in: root)?.command.contains("--no-install") == true)
remove("tsconfig.json")

write("Package.swift", "")
check("a Swift package means swift build",
      Verification.detected(in: root)?.display == "swift build")
remove("Package.swift")

write("Cargo.toml", "")
check("a cargo manifest means cargo check",
      Verification.detected(in: root)?.display == "cargo check")
remove("Cargo.toml")

write("go.mod", "")
check("a go module means go build",
      Verification.detected(in: root)?.display == "go build ./...")
remove("go.mod")

// --- which source wins ---
write("tsconfig.json", "{}")
write(Verification.manifest, "make verify")
check("a declared check beats a detected one",
      Verification.check(for: root)?.source == .declared)

Verification.setCommand("swift build", for: root)
check("a configured check beats a declared one",
      Verification.check(for: root)?.source == .configured)
check("and it is the configured command that would run",
      Verification.check(for: root)?.command == "swift build")

// Off has to be storable. Without it, a person who turns the check off finds it
// guessed again from the tsconfig on the next run, which is a setting that
// doesn't stay set.
Verification.setCommand("", for: root)
check("an empty command turns checking off rather than falling through",
      Verification.check(for: root) == nil)

Verification.setCommand(nil, for: root)
check("clearing it returns to what the project declares",
      Verification.check(for: root)?.source == .declared)
remove(Verification.manifest)
check("and then to what the manifest implies",
      Verification.check(for: root)?.source == .detected)
remove("tsconfig.json")

// --- reading an exit status ---
//
// The distinction this whole type turns on. A check that *ran* and failed has
// an opinion about the code; a check that could not run has none, and calling
// the second one a failure is the expensive mistake.
func result(_ status: Int32, out: String = "", err: String = "",
            timedOut: Bool = false) -> Shell.Result {
    Shell.Result(status: status, out: out, err: err, timedOut: timedOut)
}

check("a clean exit passed", Verification.outcome(of: result(0)) == .passed)
check("a deadline is not a failure",
      Verification.outcome(of: result(15, timedOut: true)) == .timedOut)

if case .failed(let text) = Verification.outcome(of: result(2, out: "src/a.ts(3,1): error TS2304")) {
    check("a real failure carries its output", text.contains("TS2304"))
} else {
    check("a real failure carries its output", false)
}

if case .unavailable = Verification.outcome(of: result(127, err: "sh: tsc: command not found")) {
    check("a missing tool is unavailable, not failed", true)
} else {
    check("a missing tool is unavailable, not failed", false)
}
if case .unavailable = Verification.outcome(
    of: result(1, err: "npm error could not determine executable to run")) {
    check("npm's spelling of the same thing is also unavailable", true)
} else {
    check("npm's spelling of the same thing is also unavailable", false)
}

// --- how much output is worth carrying ---
//
// Head rather than tail: a compiler reports the first error first, and the
// first error is usually the cause of the next forty. A tail would hand the
// lead the consequences and cut off the reason.
let many = (1...400).map { "src/file\($0).ts(1,1): error TS1005: ';' expected." }
    .joined(separator: "\n")
let cut = Verification.excerpt(of: result(2, out: many), limit: 500)
check("a long report is cut down", cut.count < many.count)
check("and it is the beginning that is kept", cut.contains("file1.ts"))
check("not the end", !cut.contains("file400.ts"))
check("and it says what it dropped", cut.contains("not shown"))
check("a short report is left whole",
      Verification.excerpt(of: result(2, out: "one error")) == "one error")
// Half an error message reads as a different error message.
check("the cut lands on a line boundary",
      cut.split(separator: "\n").dropLast().allSatisfy { $0.hasSuffix("expected.") })

// --- actually running one ---
//
// The deadline is the part worth measuring rather than asserting. Its failure
// mode is a crew run that never ends, and the second-order one is a compiler
// left running with nobody reading it, holding the lock the next run wants.
let passing = Verification.Check(display: "true", command: "exit 0", source: .detected)
check("a command that succeeds passes",
      Verification.outcome(of: Verification.run(passing, in: root)) == .passed)

let failing = Verification.Check(display: "false",
                                 command: "echo 'src/a.ts: error' >&2; exit 1",
                                 source: .detected)
if case .failed(let text) = Verification.outcome(of: Verification.run(failing, in: root)) {
    check("a command that fails is read from stderr", text.contains("src/a.ts: error"))
} else {
    check("a command that fails is read from stderr", false)
}

let missing = Verification.Check(display: "nope",
                                 command: "honeycode-no-such-tool-\(UUID().uuidString)",
                                 source: .detected)
if case .unavailable = Verification.outcome(of: Verification.run(missing, in: root)) {
    check("a command that isn't installed is unavailable", true)
} else {
    check("a command that isn't installed is unavailable", false)
}

let began = Date()
// A duration nothing else on this machine would be sleeping for, so the check
// below is asking about this process and not somebody else's.
let marker = "31.\(Int.random(in: 100000...999999))"
let hanging = Verification.Check(display: "sleep", command: "sleep \(marker)",
                                 source: .detected)
let stopped = Verification.run(hanging, in: root, timeout: 1)
let waited = Date().timeIntervalSince(began)
check("a command that hangs is stopped", Verification.outcome(of: stopped) == .timedOut)
check("at roughly the deadline, not thirty seconds later", waited < 10)

// Returning in time is not the same as the command having died, and it is the
// weaker of the two things worth knowing: an orphaned compiler holds the build
// lock the next run wants. `/bin/sh -c` with a single command execs it, which is
// what makes SIGTERM to the child reach the compiler — measured here rather
// than assumed, because an earlier version tried to guarantee it with `exec` and
// broke two other cases doing it.
let survivors = Shell.run("/usr/bin/pgrep", ["-f", "sleep \(marker)"])
check("and the command itself is dead, not orphaned", survivors.trimmedOut.isEmpty)

// The working directory is the project's, not this process's — a check run
// anywhere else is checking somebody else's code.
write("marker.txt", "here")
let pwd = Verification.Check(display: "ls", command: "ls marker.txt", source: .detected)
check("it runs in the project directory",
      Verification.outcome(of: Verification.run(pwd, in: root)) == .passed)

// Leave no preference behind. The test binary reaches the app's real domain.
Verification.setCommand(nil, for: root)
check("nothing is left in preferences", Verification.configured(for: root) == nil)

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
