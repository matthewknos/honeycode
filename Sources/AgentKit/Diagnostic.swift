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
    /// A config directory with something in it. Only meaningful for the Claude
    /// accounts, which are the two that can be installed and not logged in —
    /// the ACP agents keep their credentials elsewhere and report a sign-in
    /// problem when they start, which is the only place it can be seen.
    let hasLogin: Bool?

    var id: String { account.id }

    var isReady: Bool { hasCLI && hasLogin != false }

    /// One short phrase. Not a sentence — this sits in a row beside three
    /// others, and a paragraph per account is a wall rather than a status.
    var summary: String {
        if !hasCLI { return "not installed" }
        if hasLogin == false { return "not signed in" }
        return "ready"
    }

    /// What actually fixes it, for the tooltip.
    var remedy: String? {
        if !hasCLI {
            switch account {
            case .personal, .work: return "Install Claude Code — claude.com/claude-code"
            case .kimi:            return "npm install -g @moonshotai/kimi-cli"
            case .copilot:         return "npm install -g @github/copilot"
            case .custom:          return "Set this account's command in Settings ▸ Accounts"
            }
        }
        if hasLogin == false {
            return "Run `claude` once in a terminal with CLAUDE_CONFIG_DIR set to "
                + (account.configDir ?? "this account's directory")
        }
        return nil
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

        // A directory that exists but holds nothing is a directory somebody
        // made by hand, or one this app created and never logged into. Both
        // read as "not signed in", which is what they are.
        var hasLogin: Bool?
        if let directory = account.configDir {
            let contents = (try? manager.contentsOfDirectory(atPath: directory)) ?? []
            hasLogin = !contents.isEmpty
        }
        return AccountReadiness(account: account, hasCLI: hasCLI, hasLogin: hasLogin)
    }
}
