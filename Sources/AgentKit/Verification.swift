import Foundation

/// Whether the work actually holds together, asked of the project rather than
/// of the agents that did it.
///
/// A crew currently ends on three accounts of itself, and all three are
/// somebody's opinion. The delegates say what they did. The lead reads what
/// they said and assembles. `Crew.ledger` counts files, which is measured but
/// says only that bytes moved — a file can be written, counted, reported, and
/// not compile.
///
/// The missing fact is the one the project can answer for itself. After the
/// first real crew run the person who asked for it ran `npx tsc --noEmit` by
/// hand, which is the tell: the run had produced a confident summary and the
/// only way to find out whether it was true was to leave the app and check.
///
/// **The baseline is the part that makes this worth having.** A check run once
/// at the end reports the state of the repository, not the work of the crew —
/// and a repository that was already failing produces an alarming report about
/// problems nobody in this run created. Reported that way twice, the person
/// learns to ignore it, and then it is worse than nothing because it is noise
/// that looks like signal. So the same check is run at dispatch, while the
/// delegates work and therefore for free in wall-clock terms, and what gets
/// reported is the *difference*.
enum Verification {

    // MARK: What to run

    /// One check, and where it came from.
    struct Check: Equatable, Sendable {
        /// What to call it when saying it is running.
        let display: String
        /// The command line, handed to `sh -c`.
        let command: String
        let source: Source

        /// Which of the three answers won. Reported, because "the check you
        /// configured" and "a check this app guessed at from a tsconfig" earn
        /// different amounts of trust when one of them fails.
        enum Source: String, Equatable, Sendable {
            /// Set for this directory in settings.
            case configured
            /// A `.honeycode-check` file in the project, which is the way a
            /// team puts one under version control alongside the code it
            /// checks.
            case declared
            /// Inferred from a manifest.
            case detected

            var blurb: String {
                switch self {
                case .configured: return "the check configured for this project"
                case .declared:   return "the check this project declares in .honeycode-check"
                case .detected:   return "a check inferred from this project's manifest"
                }
            }
        }
    }

    /// The file a project uses to say how it should be checked.
    static let manifest = ".honeycode-check"

    /// How long a check gets before it is killed.
    ///
    /// Generous, because a typecheck of a large project is genuinely minutes,
    /// and short of `Crew.patience` because a check is not the work — a run
    /// that spends its whole budget deciding whether the work compiled has
    /// spent it badly.
    static let patience: TimeInterval = 300

    /// What to run in this directory, or nil if nothing should be.
    ///
    /// Three sources, most specific first. A person who set a command means
    /// that command; a project that declares one means it for everybody who
    /// clones it; detection is the guess of last resort.
    static func check(for directory: URL) -> Check? {
        if let configured = configured(for: directory) {
            // An empty string is a deliberate "don't", stored so that turning
            // the check off survives a relaunch and isn't re-guessed each run.
            guard !configured.isEmpty else { return nil }
            return Check(display: configured, command: configured, source: .configured)
        }
        if let declared = declared(in: directory) {
            return Check(display: declared, command: declared, source: .declared)
        }
        return detected(in: directory)
    }

    /// The command a project declares for itself.
    ///
    /// First line that isn't blank and isn't a comment, so the file can explain
    /// itself to whoever opens it next.
    static func declared(in directory: URL) -> String? {
        let url = directory.appendingPathComponent(manifest)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// A manifest this app recognises, and the cheapest question to ask of it.
    ///
    /// Every one of these is a check rather than a build wherever the language
    /// offers the distinction. A crew's output should be inspected, not
    /// installed: `npm run build` writes artefacts, can publish, and on a
    /// half-finished tree can do harm that the thing asking the question was
    /// only ever meant to detect.
    ///
    /// `npx --no-install` for the same reason. Without it, a project with a
    /// tsconfig and no local TypeScript quietly downloads a compiler mid-run.
    private static let detectors: [(marker: String, display: String, command: String)] = [
        ("Package.swift", "swift build", "swift build"),
        ("tsconfig.json", "tsc --noEmit", "npx --no-install tsc --noEmit"),
        ("Cargo.toml", "cargo check", "cargo check --quiet"),
        ("go.mod", "go build ./...", "go build ./..."),
    ]

    static func detected(in directory: URL) -> Check? {
        for detector in detectors
        where FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(detector.marker).path) {
            return Check(display: detector.display, command: detector.command,
                         source: .detected)
        }
        return nil
    }

    // MARK: Running it

    /// Run a check and wait for it.
    ///
    /// Through `sh` because a check is a command line, not a binary and a list
    /// of arguments — `npx --no-install tsc --noEmit` has to resolve `npx`, and
    /// a project that declares `make verify && ./scripts/lint` means the `&&`.
    ///
    /// An earlier version put `exec` in front, to stop the shell outliving the
    /// thing it launched and orphaning it at the deadline. That was wrong twice
    /// and a test caught both: `exec` refuses a builtin, and in `a; b` it
    /// replaces the shell with `a` so `b` never runs. It was also unnecessary
    /// for the case it was written for — `/bin/sh -c` with a single command
    /// already execs it, which is measurable and was measured, so the deadline
    /// reaches the compiler directly for all four detected checks.
    ///
    /// What remains true: a *compound* declared check that hangs can leave its
    /// current step running after the deadline. The run still ends, which is
    /// what the deadline is for; the stray step is not chased.
    ///
    /// Nonisolated on purpose: this blocks for as long as a typecheck takes and
    /// must never be called on the main actor. `Crew.verify` is what puts it on
    /// a background queue.
    nonisolated static func run(_ check: Check, in directory: URL,
                                timeout: TimeInterval = patience) -> Shell.Result {
        Shell.run("/bin/sh", ["-c", check.command], in: directory, timeout: timeout)
    }

    /// What a finished check actually established.
    enum Outcome: Equatable {
        case passed
        /// It ran, and the project has something to say. Carries the output,
        /// already trimmed to something a prompt can hold.
        case failed(String)
        /// It never got to have an opinion — the tool isn't installed, the
        /// script isn't there, the command is a typo. Deliberately *not*
        /// `failed`: reporting a missing compiler as "your work doesn't build"
        /// is a lie in the most expensive direction, since the lead would then
        /// go and rewrite working code.
        case unavailable(String)
        case timedOut
    }

    static func outcome(of result: Shell.Result) -> Outcome {
        if result.timedOut { return .timedOut }
        if result.ok { return .passed }

        // 127 is the shell's own "no such command". The rest are the ways the
        // usual runners spell it, all of which arrive with a non-zero status
        // that is otherwise indistinguishable from a real failure.
        let text = (result.err + "\n" + result.out).lowercased()
        let missing = result.status == 127
            || text.contains("command not found")
            || text.contains("could not determine executable")
            || text.contains("npm error could not determine")
            || text.contains("no such file or directory")
        if missing { return .unavailable(excerpt(of: result, limit: 300)) }
        return .failed(excerpt(of: result))
    }

    /// As much of a failing check's output as is worth putting in a prompt.
    ///
    /// Head rather than tail. Compilers report the first error first, and the
    /// first error is usually the cause of the next forty — a tail would hand
    /// the lead the consequences and cut off the reason.
    static func excerpt(of result: Shell.Result, limit: Int = 4000) -> String {
        // Both streams, because these tools disagree about which one to use and
        // the useful half is whichever isn't empty. `tsc` writes to stdout;
        // `swift build` and `cargo` write to stderr.
        let body = [result.out, result.err]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard body.count > limit else { return body }
        let head = String(body.prefix(limit))
        // Cut at a line boundary — half an error message reads as a different
        // error message.
        let clipped = head.lastIndex(of: "\n").map { String(head[..<$0]) } ?? head
        let dropped = body.count - clipped.count
        return clipped + "\n… \(dropped) more characters of output, not shown"
    }

    // MARK: What the person configured

    /// Per directory, because a check is a fact about a project rather than
    /// about this app — one window may be pointed at a Swift package and the
    /// next at a TypeScript repo, and a single global command would be wrong in
    /// one of them.
    private static func key(for directory: URL) -> String {
        "crew.check." + directory.standardizedFileURL.path
    }

    /// The configured command, "" for deliberately off, nil for never set.
    static func configured(for directory: URL) -> String? {
        Prefs.store.string(forKey: key(for: directory))
    }

    /// Nil clears it and returns this directory to declaration and detection.
    static func setCommand(_ command: String?, for directory: URL) {
        guard let command else {
            Prefs.store.removeObject(forKey: key(for: directory))
            return
        }
        Prefs.store.set(command.trimmingCharacters(in: .whitespaces), forKey: key(for: directory))
    }
}
