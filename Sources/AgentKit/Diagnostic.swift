import Foundation

/// A dying CLI's last words, as something a person can read.
///
/// When an agent process exits non-zero, whatever it wrote to stderr is the
/// only account of why — so it has to be kept. What it must not do is arrive
/// looking like the agent's answer, and before this it did exactly that. A Kimi
/// delegate whose ACP session was closed mid-run printed a Node object dump:
///
///     Error handling request {
///       method: 'session/prompt',
///       id: 10,
///       params: { prompt: [ [Object] ], sessionId: 'session_8fdb10e2…' },
///       jsonrpc: '2.0'
///     } {
///       code: -32603,
///       message: 'Internal error',
///       data: { details: 'Session is closed' }
///     }
///
/// Twelve lines went into the transcript verbatim and were then shown as the
/// delegate's report, under its name, where its work should have been. Two
/// facts were lost in that: that the agent had said nothing at all, and — buried
/// in the middle of the dump — the four words that actually explain it.
///
/// Every agent CLI here is a Node program, so `util.inspect` is the format
/// their crashes come in. That is what this reads: the quoted `message` and
/// `details` fields, which are the two a JSON-RPC error puts the sentence in.
/// Anything it doesn't recognise falls back to the first line, which is where
/// a program that isn't doing this puts its complaint.
enum Diagnostic {

    /// Deliberately lossy, and only ever used beside a sentence naming the
    /// process. This is the *gist* of a crash; the whole of it belongs in a log,
    /// not in a conversation.
    static func summarise(_ stderr: String) -> String {
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }

        // `message: 'Internal error'` and `details: 'Session is closed'` — in
        // that order, because the first names the class of failure and the
        // second says which one, and read together they are a sentence.
        var found: [String] = []
        for key in ["message", "details"] {
            guard let value = field(key, in: text), !value.isEmpty,
                  !found.contains(value) else { continue }
            found.append(value)
        }
        if !found.isEmpty { return cap(found.joined(separator: " — ")) }

        // Nothing recognisable. The first non-empty line is where a program
        // that isn't dumping an object puts its complaint — and the last line
        // of an object dump is `}`, which is why this isn't the last one.
        let first = text.components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? text
        return cap(first.trimmingCharacters(in: .whitespaces))
    }

    /// `key: 'value'`, `key: "value"`, `"key": "value"` — the three spellings
    /// that turn up between `util.inspect` and raw JSON.
    private static func field(_ key: String, in text: String) -> String? {
        let pattern = "[\"']?\(key)[\"']?\\s*:\\s*[\"']([^\"']*)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text,
                                           range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespaces)
    }

    /// Long enough for a real error message, short enough that a crash can't
    /// take over a transcript.
    private static func cap(_ text: String, limit: Int = 200) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }
}

// MARK: - Is this account ready to run

/// Whether an account can actually do anything, and if not, what to do.
///
/// `tools/doctor.sh` has answered this from a terminal since the beginning, and
/// the window has never answered it at all — so the first run on a new machine
/// looked identical whether an agent CLI was installed or not, and the failure
/// arrived as a spawn error after you had typed a message. That is the wrong
/// end of the interaction to find out at.
///
/// Checked in the same places `ACPAgent.binaryCandidates` and
/// `ClaudeAdapter` look, rather than by a `PATH` search: an app launched from
/// Finder inherits launchd's `PATH`, which contains neither Homebrew nor nvm,
/// so a search would report every account missing on a machine where all four
/// work perfectly.
struct AccountReadiness: Equatable, Sendable, Identifiable {
    let account: Account
    /// The CLI exists and is executable.
    let hasCLI: Bool
    /// The config directory holds an actual login. Only meaningful for the
    /// Claude accounts, which are the two whose credentials this app knows
    /// where to look for. Nil for anything speaking ACP, and nil means
    /// *unknown* rather than *no*: those CLIs keep their credentials
    /// somewhere private to each of them, and guessing at a path would mean
    /// telling somebody who is perfectly well signed in that they aren't.
    let hasLogin: Bool?

    var id: String { account.id }

    var isReady: Bool { hasCLI && hasLogin != false }

    /// The one thing to do next about this account.
    ///
    /// A single value rather than a handful of booleans for each caller to
    /// unpick, because there is only ever one next step and three places were
    /// quietly deriving their own answer to it: setup had a ladder of `if`s,
    /// `remedy` had another, and `tools/doctor.sh` a third that disagreed with
    /// both about what counts as a login. The button on a row is this value,
    /// rendered — so the app can now *do* the next step rather than describe
    /// it, and there is one place to be right about what it is.
    enum Step: Equatable, Sendable {
        /// Not on this Mac. The string is the command that installs it.
        case install(String)
        /// Installed, and its config directory holds no login.
        case signIn
        /// Installed, and whether it is signed in cannot be seen from here —
        /// every ACP agent, for the reason `hasLogin` gives. Not a problem,
        /// just not a promise.
        case unknownLogin
        /// Nothing left to do.
        case ready
        /// Not on this Mac, and there is no line this app could run to change
        /// that — an added agent that ships its own binary, or one whose
        /// runner (`npx`, `uvx`) isn't installed. `remedy` says where to go.
        case get
        /// An added account with no command yet. Nothing to install, because
        /// nobody has said what it is.
        case configure
    }

    var next: Step {
        guard hasCLI else {
            // An added account has no install line of its own. It has either a
            // command nobody has typed yet, or a command that isn't here — and
            // those are different problems with different sentences.
            if case .custom = account {
                let command = account.custom?.command.trimmingCharacters(in: .whitespaces)
                return (command?.isEmpty ?? true) ? .configure : .get
            }
            return .install(Self.installCommand(account))
        }
        switch hasLogin {
        case .some(false): return .signIn
        case .some(true):  return .ready
        case .none:        return .unknownLogin
        }
    }

    /// The line that installs an account's CLI, in the form somebody would
    /// paste.
    ///
    /// One copy of it. Setup printed an `npm install` line, `remedy` said
    /// "Install Claude Code — claude.com/claude-code", and `tools/doctor.sh`
    /// printed a project URL: three answers to one question, which was
    /// survivable while all the app did was show them. `Setup.installScript`
    /// now *runs* this, so it had better be the true one and there had better
    /// be one — and `tools/doctor.sh` prints these, so a machine the doctor
    /// clears is a machine the button would have made.
    static func installCommand(_ account: Account) -> String {
        switch account {
        case .personal, .work: return "npm install -g @anthropic-ai/claude-code"
        case .kimi:            return "npm install -g @moonshotai/kimi-cli"
        case .copilot:         return "npm install -g @github/copilot"
        // Whatever an added account runs, somebody else installed. There is no
        // command this could name that wouldn't be a guess.
        case .custom:          return ""
        }
    }

    /// One short phrase. Not a sentence — this sits in a row beside three
    /// others, and a paragraph per account is a wall rather than a status.
    var summary: String {
        switch next {
        case .install, .get: return "not installed"
        case .signIn:        return "not signed in"
        case .configure:     return "no command set"
        // Deliberately not "ready", which is what this said before and was the
        // most misleading word in the app: for Kimi and Copilot it meant "the
        // binary is on disk", and it was read as "this works" right up until
        // the first message failed to send.
        case .unknownLogin:  return "installed"
        case .ready:         return "ready"
        }
    }

    /// What actually fixes it, for the tooltip.
    ///
    /// Nil when there is nothing wrong — and `unknownLogin` counts as nothing
    /// wrong. A tooltip telling you to go and sign in, on a row showing a tick,
    /// is the app second-guessing a state it has already admitted it cannot
    /// see. Setup offers the sign-in there as an option; everywhere else it
    /// would be a warning about nothing.
    var remedy: String? {
        switch next {
        case .install(let command): return command
        // Whatever this account needs, in the order somebody would want it.
        // The runners are worth naming: an `npx` agent that reports itself
        // missing has nothing wrong with it at all — the machine has no Node.
        case .get:
            // A catalogue entry now carries either a page to open or a command
            // to run — see `CatalogueAgent.site`, which stopped being optional
            // when these stopped installing themselves. Told apart by whether
            // it parses as a link, because "Get it from npm i -g …" reads as a
            // typo and "Run https://…" reads as worse.
            if let site = account.custom?.site {
                return site.hasPrefix("http") ? "Get it from \(site)"
                                              : "Install it: \(site)"
            }
            switch account.custom?.command {
            case "npx":
                return "`npx` comes with Node.js. Install Node, then install "
                     + "the agent's package — nothing here fetches it for you."
            case "uvx":
                return "`uvx` comes with uv — docs.astral.sh/uv. There is nothing "
                     + "else to install; uvx fetches the agent."
            case let command?:
                return "`\(command)` isn't in ~/.local/bin, Homebrew, or your nvm "
                     + "versions, which is everywhere this app looks."
            case nil:
                return nil
            }
        case .signIn:
            return "Run `claude` once in a terminal with CLAUDE_CONFIG_DIR set to "
                + (account.configDir ?? "this account's directory")
        case .configure:
            return "Set this account's command in Settings ▸ Accounts"
        case .unknownLogin, .ready:
            return nil
        }
    }
}

extension Diagnostic {

    /// Every account you have, checked. Off the main thread, please — this
    /// stats a dozen paths and may walk the nvm tree.
    ///
    /// The ones switched off in setup are not "not ready", they are not yours:
    /// a roster reporting Copilot missing on a Mac belonging to somebody who
    /// has never had Copilot is noise wearing a warning's clothes.
    nonisolated static func readiness() -> [AccountReadiness] {
        Account.enabled.map(readiness(of:))
    }

    /// Every account that exists, switched off ones included. Setup needs this:
    /// the whole point of that step is deciding which you have, and you cannot
    /// decide about a row you cannot see.
    nonisolated static func readinessOfAll() -> [AccountReadiness] {
        Account.allCases.map(readiness(of:))
    }

    nonisolated static func readiness(of account: Account) -> AccountReadiness {
        let manager = FileManager.default
        let candidates: [String]
        switch account.protocolKind {
        case .claudeStreamJSON:
            candidates = [NSHomeDirectory() + "/.local/bin/claude",
                          "/opt/homebrew/bin/claude",
                          "/usr/local/bin/claude"]
        case .acp(let agent):
            candidates = agent.binaryCandidates
        }
        let hasCLI = candidates.contains { manager.isExecutableFile(atPath: $0) }

        // A directory is not a login, and this used to accept one that held
        // anything at all. Two things put a file in there that isn't a
        // credential: `Setup.claudeLoginScript` runs `mkdir -p` before handing
        // over, so a sign-in you started and cancelled leaves a directory
        // behind; and the CLI writes settings of its own the first time it is
        // run for any reason. Both read as signed in, and the tick they earned
        // was the last thing the app said before the first message failed.
        //
        // These are the two `tools/doctor.sh` looks for, which is the point of
        // choosing them: a doctor that clears a machine the app then fails on
        // is worse than no doctor at all.
        var hasLogin: Bool?
        if let directory = account.configDir {
            hasLogin = manager.fileExists(atPath: directory + "/.credentials.json")
                    || manager.fileExists(atPath: directory + "/projects")
        }
        return AccountReadiness(account: account, hasCLI: hasCLI, hasLogin: hasLogin)
    }
}
