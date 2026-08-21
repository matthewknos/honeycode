import Foundation

/// Running a command-line tool and waiting for it.
///
/// Synchronous on purpose. Every caller is already on a detached task, and an
/// async wrapper around a process that returns in thirty milliseconds buys
/// nothing but a continuation to get wrong.
enum Shell {

    struct Result {
        let status: Int32
        let out: String
        let err: String
        /// Killed at the deadline rather than having finished and failed.
        ///
        /// The difference matters to anything deciding what to *say*: a command
        /// that failed has an opinion about your code, and one that ran out of
        /// time has none. Defaulted, so nothing that predates timeouts changes.
        var timedOut: Bool = false

        var ok: Bool { status == 0 }

        /// The line to show a person. `git` and `gh` both write failures to
        /// stderr and say nothing on stdout, so the useful text is whichever
        /// one isn't empty.
        var message: String {
            (err.isEmpty ? out : err).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var trimmedOut: String {
            out.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Absolute paths, in the order these tools are usually installed.
    ///
    /// Looked up by path rather than by searching `PATH`, because an app
    /// launched from Finder doesn't inherit the shell's `PATH` at all — it gets
    /// launchd's, which is `/usr/bin:/bin:/usr/sbin:/sbin` and contains no
    /// Homebrew. This is the same reason `UsageStore` hunts for `claude` by
    /// hand rather than trusting the environment.
    ///
    /// Memoised, including the misses. `Git.run` asks on every single
    /// invocation, and the project chip fires a handful of those each time the
    /// window comes forward — so this was up to four `access` calls per `git`
    /// command to re-answer a question about where a binary is installed.
    /// Nothing here changes while the app is running that isn't already going to
    /// need a relaunch.
    nonisolated(unsafe) private static var located: [String: String?] = [:]
    private static let locateLock = NSLock()

    static func locate(_ tool: String) -> String? {
        locateLock.lock()
        if let known = located[tool] { locateLock.unlock(); return known }
        locateLock.unlock()

        let found = ["/opt/homebrew/bin/", "/usr/local/bin/", "/usr/bin/",
                     NSHomeDirectory() + "/.local/bin/"]
            .map { $0 + tool }
            .first { FileManager.default.isExecutableFile(atPath: $0) }

        locateLock.lock()
        located[tool] = found
        locateLock.unlock()
        return found
    }

    /// The `PATH` a child process gets, since it can't have the shell's.
    ///
    /// The same prefixes `locate` searches, in the same order, so that the app
    /// and anything it launches agree about which copy of a tool is *the* copy.
    ///
    /// `~/.local/bin` is the one that matters and the one that was missing.
    /// This app finds binaries by absolute path, so it kept working while every
    /// child it spawned was blind to that directory — and on a machine with no
    /// Homebrew it is where `gh`, `az`, `azd`, `uv` and the agent CLIs
    /// themselves live. The visible symptom was an agent surveying the machine
    /// it is running on, finding only what ships in `/usr/bin`, and reporting a
    /// fully equipped Mac as a bare one.
    static var toolPath: String {
        ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
         NSHomeDirectory() + "/.local/bin",
         "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
    }

    /// A `.command` file that runs one interactive tool, for the caller to
    /// hand to `NSWorkspace.open`.
    ///
    /// A file to open rather than an Apple Event to Terminal. The sign-in flows
    /// this exists for — `gh auth login`, `az login` — are interactive prompts
    /// with a menu, a browser hand-off and a device code to paste, so they need
    /// a terminal a person can type into; and driving one by AppleScript under
    /// the hardened runtime costs an `automation.apple-events` entitlement and
    /// a permission dialog to accomplish what double-clicking a `.command` does
    /// for nothing. It also gets the right app for free: whatever you open
    /// `.command` files with is, by definition, your terminal.
    ///
    /// The second banner line is fixed rather than passed in. Both callers said
    /// the same sentence because it's the same fact about this app, and a third
    /// one would want it too.
    ///
    /// - Parameters:
    ///   - name: the temporary file's stem, which is what the terminal's title
    ///     bar ends up showing.
    ///   - announcing: the first line printed, before the tool takes over.
    ///   - preamble: shell run before the tool — environment the tool needs and
    ///     won't set for itself.
    static func terminalScript(named name: String, announcing: String,
                               preamble: String = "",
                               run binary: String, _ arguments: [String] = []) -> URL? {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name).command")
        // Quoted, both of them: a path can carry a space, and this is a shell.
        let command = (["\"\(binary)\""] + arguments.map { "\"\($0)\"" })
            .joined(separator: " ")
        let script = """
        #!/bin/sh
        \(preamble)echo "\(announcing)"
        echo "When it's done, go back to Honeycode."
        echo
        exec \(command)
        """
        guard (try? script.write(to: file, atomically: true, encoding: .utf8)) != nil,
              (try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                      ofItemAtPath: file.path)) != nil
        else { return nil }
        return file
    }

    /// A buffer two threads can touch.
    ///
    /// stdout and stderr have to be drained *concurrently*: a pipe holds 64KB
    /// and then blocks the writer, so reading one to the end before starting on
    /// the other deadlocks the moment a `git push` is chatty enough. Which it
    /// is, because push reports progress on stderr.
    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ more: Data) { lock.lock(); data.append(more); lock.unlock() }
        var text: String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func raise() { lock.lock(); value = true; lock.unlock() }
        var raised: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// - Parameter timeout: how long to wait before killing it. Nil waits
    ///   forever, which is right for `git` — every command this was written for
    ///   returns in milliseconds, and one that doesn't has hung on something a
    ///   deadline wouldn't fix. It is wrong for anything a *project* supplies:
    ///   a check command is arbitrary code from a repository, and a crew run
    ///   that never ends because someone's build script waits on a prompt is a
    ///   run nobody can get an answer out of.
    static func run(_ binary: String, _ arguments: [String],
                    in directory: URL? = nil, stdin: String? = nil,
                    timeout: TimeInterval? = nil) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }

        var env = ProcessInfo.processInfo.environment
        // `gh` shells out to `git`, and `git push` shells out to a credential
        // helper — none of which are findable on launchd's PATH. Handing down
        // the usual install prefixes is what makes a push from the app behave
        // like a push from a terminal.
        env["PATH"] = toolPath
        // There is no terminal here. Anything that would stop to ask a question
        // or open an editor would simply hang forever, with no visible cause.
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_EDITOR"] = "true"
        env["GIT_PAGER"] = "cat"
        env["GH_PAGER"] = "cat"
        env["GH_PROMPT_DISABLED"] = "1"
        env["GH_NO_UPDATE_NOTIFIER"] = "1"
        env["NO_COLOR"] = "1"
        process.environment = env

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe = Pipe()
        if stdin != nil { process.standardInput = inPipe }

        do { try process.run() } catch {
            return Result(status: 127, out: "", err: error.localizedDescription)
        }

        // Terminating the process closes its pipes, which is what unblocks the
        // reads below — so this needs no cooperation from the thing being
        // killed. It reaches the *child*, not its descendants: `/bin/sh -c` with
        // a single command execs it, so a check is killed directly, but a
        // compound one can leave its current step running. See `Verification.run`.
        let expired = Flag()
        var deadline: DispatchWorkItem?
        if let timeout {
            let work = DispatchWorkItem {
                guard process.isRunning else { return }
                expired.raise()
                process.terminate()
            }
            deadline = work
            DispatchQueue.global(qos: .utility)
                .asyncAfter(deadline: .now() + timeout, execute: work)
        }

        if let stdin {
            // Small enough to fit the pipe buffer in one write, so this can't
            // block before anyone is draining the other end.
            try? inPipe.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
            try? inPipe.fileHandleForWriting.close()
        }

        let errors = Buffer()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            errors.append(errPipe.fileHandleForReading.readDataToEndOfFile())
            drained.signal()
        }
        let out = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(),
                         as: UTF8.self)
        drained.wait()
        process.waitUntilExit()
        deadline?.cancel()

        if expired.raised {
            let seconds = Int((timeout ?? 0).rounded())
            return Result(status: process.terminationStatus, out: out,
                          err: "gave up waiting after \(seconds)s", timedOut: true)
        }
        return Result(status: process.terminationStatus, out: out, err: errors.text)
    }
}

/// The subset of git this app drives.
///
/// Deliberately small and deliberately conservative: it branches, it commits
/// named paths, and it pushes. It never forces, never rebases, never resets and
/// never touches a file the session didn't write. An agent that edits your code
/// is already asking for a lot of trust; an agent that rewrites your history
/// would be asking for more than this app is willing to spend.
enum Git {

    static var binary: String? { Shell.locate("git") }

    @discardableResult
    static func run(_ arguments: [String], in directory: URL) -> Shell.Result {
        guard let binary else {
            return Shell.Result(status: 127, out: "", err: "git isn't installed")
        }
        return Shell.run(binary, arguments, in: directory)
    }

    // MARK: Reading

    /// The work tree a directory sits in, or nil if it isn't in one.
    static func root(of directory: URL) -> URL? {
        let result = run(["rev-parse", "--show-toplevel"], in: directory)
        guard result.ok, !result.trimmedOut.isEmpty else { return nil }
        return URL(fileURLWithPath: result.trimmedOut)
    }

    static func currentBranch(in root: URL) -> String {
        run(["rev-parse", "--abbrev-ref", "HEAD"], in: root).trimmedOut
    }

    static func remote(in root: URL) -> String? {
        let result = run(["remote", "get-url", "origin"], in: root)
        guard result.ok, !result.trimmedOut.isEmpty else { return nil }
        return result.trimmedOut
    }

    /// What the remote considers home.
    ///
    /// `origin/HEAD` is a local symref that only exists if the clone bothered to
    /// set it, and plenty don't. The fallbacks look for branches that actually
    /// exist rather than assuming `main` — which has been the wrong guess on
    /// every repository older than 2020. Nothing here touches the network; the
    /// answer is a starting point in an editable field, not a commitment.
    static func defaultBranch(in root: URL) -> String {
        let symref = run(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: root)
        if symref.ok, let name = symref.trimmedOut.split(separator: "/").last,
           !name.isEmpty {
            return String(name)
        }
        for candidate in ["main", "master", "develop", "trunk"]
        where exists("refs/remotes/origin/" + candidate, in: root) {
            return candidate
        }
        return "main"
    }

    static func exists(_ ref: String, in root: URL) -> Bool {
        run(["rev-parse", "--verify", "--quiet", ref], in: root).ok
    }

    static func branchExists(_ name: String, in root: URL) -> Bool {
        exists("refs/heads/" + name, in: root)
    }

    /// Paths with uncommitted changes, relative to the root.
    static func dirtyPaths(in root: URL) -> Set<String> {
        let result = run(["status", "--porcelain=v1", "--untracked-files=all"], in: root)
        guard result.ok else { return [] }
        var paths: Set<String> = []
        for line in result.out.split(separator: "\n") where line.count > 3 {
            var path = String(line.dropFirst(3))
            // A rename prints `old -> new`. The new name is the one on disk.
            if let arrow = path.range(of: " -> ") { path = String(path[arrow.upperBound...]) }
            // Paths with spaces or non-ASCII come back quoted.
            if path.hasPrefix("\"") && path.hasSuffix("\"") {
                path = String(path.dropFirst().dropLast())
            }
            paths.insert(path)
        }
        return paths
    }

    /// Whether a branch has anything the base doesn't.
    ///
    /// The case this exists for: the agent committed as it went, so there is
    /// nothing left to commit but there is still a pull request to open.
    static func hasCommits(on branch: String, beyond base: String, in root: URL) -> Bool {
        let result = run(["rev-list", "--count", "\(base)..\(branch)"], in: root)
        return result.ok && (Int(result.trimmedOut) ?? 0) > 0
    }

    // MARK: Writing

    /// Move to `branch`, creating it from where we are if it's new.
    ///
    /// Uncommitted work follows you across a checkout, which is exactly what's
    /// wanted here — the agent's edits are sitting in the tree and need to end
    /// up on the new branch. Git refuses the switch outright if it would
    /// clobber one of them, and that refusal is passed straight through rather
    /// than worked around.
    /// A branch name git would read as a flag.
    ///
    /// Everything here goes through `Process` with an argument array, so there's
    /// no shell and no command injection — but a value starting with `-` is
    /// still parsed as an option by the command it's handed to, and `branch`
    /// and `base` are free-text fields in the pull-request sheet. `commit`
    /// already terminates its paths with `--`; nothing else could, because `--`
    /// separates paths from revisions and these are revisions. Rejecting the
    /// shape is the equivalent that works for both.
    ///
    /// Self-inflicted rather than hostile — you type these — so this refuses
    /// with a readable message rather than sanitising behind your back.
    static func check(branch: String) throws {
        guard !branch.isEmpty else {
            throw CommandFailure(summary: "The branch name is empty", detail: "")
        }
        guard !branch.hasPrefix("-") else {
            throw CommandFailure(
                summary: "Branch names can't start with a dash",
                detail: "git would read “\(branch)” as an option rather than a branch.")
        }
    }

    static func switchTo(_ branch: String, in root: URL) throws {
        try check(branch: branch)
        guard branch != currentBranch(in: root) else { return }
        let result = branchExists(branch, in: root)
            ? run(["checkout", branch], in: root)
            : run(["checkout", "-b", branch], in: root)
        guard result.ok else { throw CommandFailure(summary: "Couldn't switch to \(branch)", detail: result.message) }
    }

    /// Commit exactly these paths and nothing else.
    ///
    /// Two steps because new files aren't committable by path until git knows
    /// they exist. The second command names the paths explicitly, which makes
    /// it a *partial* commit — git ignores the index entirely — so anything you
    /// had staged for your own reasons is still staged afterwards. Sweeping
    /// someone's half-prepared commit into an agent's pull request would be a
    /// genuinely bad way to find out how this feature works.
    ///
    /// Hooks are left on. A team that has a pre-commit hook has it for a
    /// reason, and `--no-verify` would mean this app quietly opts out of it.
    static func commit(paths: [String], title: String, body: String, in root: URL) throws {
        guard !paths.isEmpty else { return }
        let staged = run(["add", "--"] + paths, in: root)
        guard staged.ok else { throw CommandFailure(summary: "Couldn't stage the changes", detail: staged.message) }

        var arguments = ["commit", "-m", title]
        if !body.isEmpty { arguments += ["-m", body] }
        let result = run(arguments + ["--"] + paths, in: root)
        guard result.ok else { throw CommandFailure(summary: "The commit failed", detail: result.message) }
    }

    /// Push, setting upstream. Never forced.
    static func push(_ branch: String, in root: URL) throws {
        try check(branch: branch)
        let result = run(["push", "--set-upstream", "origin", branch], in: root)
        guard result.ok else { throw CommandFailure(summary: "The push failed", detail: result.message) }
    }
}

/// A command-line tool refused to do something.
///
/// Two strings rather than one: the summary is written for the sheet's headline
/// and the detail is the tool's own output, which goes in a monospaced box.
/// Paraphrasing git's error would lose the part that tells you what to do —
/// "would be overwritten by checkout" is a sentence you can act on, and
/// "couldn't switch branch" isn't.
struct CommandFailure: LocalizedError, Sendable {
    let summary: String
    let detail: String

    var errorDescription: String? { summary }
}
