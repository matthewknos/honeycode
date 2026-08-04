import Foundation

// MARK: - Who you're signed in to GitHub as

/// One account `gh` is holding credentials for.
///
/// Read from `gh` rather than kept here, for the same reason `GitHubPullRequests`
/// drives the CLI instead of the REST API: the tokens live in the keychain,
/// `gh` already knows about enterprise hosts and SSO, and an app that stored its
/// own copy would be a second place for a credential to go stale or leak.
struct GitHubAccount: Equatable, Sendable, Identifiable {
    let host: String
    let login: String
    /// The account `gh` — and so every pull request this app opens — is
    /// currently acting as, on that host.
    var isActive: Bool = false
    /// `gh` lists accounts whose token has expired or been revoked alongside
    /// the working ones. Switching to one of those succeeds and then everything
    /// afterwards fails, so it's marked rather than hidden: "signed out" is a
    /// thing you want to see, and the fix is `gh auth login`.
    var isValid: Bool = true

    var id: String { "\(host)/\(login)" }

    /// The host only when it isn't the obvious one — `github.com` on every row
    /// is noise, `ghe.corp` on one of them is the whole point.
    var hostNote: String? { host == "github.com" ? nil : host }
}

/// The accounts `gh` holds, and the switch between them.
enum GitHubAuth {

    private static var binary: String? { Shell.locate("gh") }

    static var isInstalled: Bool { binary != nil }

    /// Every account `gh auth status` reports, across every host.
    ///
    /// Off the main thread, please — it reads the keychain.
    nonisolated static func accounts() -> [GitHubAccount] {
        guard let binary else { return [] }
        let result = Shell.run(binary, ["auth", "status"])
        // Not gated on the exit status. `gh` exits non-zero when *any* account
        // has a bad token, and that's exactly the case where the list matters
        // most — it's how you find out which one to switch away from.
        return parse(result.out + "\n" + result.err)
    }

    /// Make `account` the one `gh` acts as.
    ///
    /// This is machine-wide, not per-session: it rewrites `gh`'s own config, so
    /// a terminal in another window is switched too. That's a deliberate
    /// choice over setting `GH_*` variables for the app alone — the point of
    /// the control is to answer "which account am I about to push as", and an
    /// answer that only holds inside this app would be a different, more
    /// confusing thing.
    nonisolated static func select(_ account: GitHubAccount) throws {
        guard let binary else {
            throw CommandFailure(summary: "`gh` isn't installed",
                                 detail: "brew install gh")
        }
        let result = Shell.run(binary, ["auth", "switch",
                                        "--hostname", account.host,
                                        "--user", account.login])
        guard result.ok else {
            throw CommandFailure(summary: "Couldn't switch to \(account.login)",
                                 detail: result.message)
        }
    }

    /// A script that runs `gh auth login` in whatever terminal this Mac opens
    /// `.command` files with, or nil if there's no `gh` to run.
    ///
    /// A file to open rather than an Apple Event to Terminal. `gh auth login`
    /// is an interactive prompt — a menu, a browser hand-off and a device code
    /// to paste — so it needs a terminal a person can type into; and driving
    /// one by AppleScript under the hardened runtime costs an
    /// `automation.apple-events` entitlement and a permission dialog to
    /// accomplish what double-clicking a `.command` does for nothing. It also
    /// gets the right app for free: whatever you open `.command` files with is,
    /// by definition, your terminal.
    ///
    /// `gh auth login` *adds* an account rather than replacing the signed-in
    /// one, which is the whole reason this row exists.
    nonisolated static func loginScript() -> URL? {
        guard let binary else { return nil }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("honeycode-gh-login.command")
        // Quoted: the path can carry a space, and this is a shell.
        let script = """
        #!/bin/sh
        echo "Adding a GitHub account to gh."
        echo "When it's done, reopen Honeycode's View menu to switch to it."
        echo
        exec "\(binary)" auth login
        """
        guard (try? script.write(to: file, atomically: true, encoding: .utf8)) != nil,
              (try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                      ofItemAtPath: file.path)) != nil
        else { return nil }
        return file
    }

    // MARK: The output format

    /// `gh auth status`, which has no `--json`.
    ///
    /// The shape, per host, is a header line and then one indented block per
    /// account:
    ///
    ///     github.com
    ///       ✓ Logged in to github.com account octocat (keyring)
    ///       - Active account: true
    ///
    /// Both the tick line and its failed twin carry the host and the login, so
    /// they're what's matched — the unindented host header is decoration, and
    /// relying on indentation to know where a block ends would break the first
    /// time `gh` reflows its output. `Active account:` attaches to whichever
    /// account was named last, which is the only ordering this format promises.
    static func parse(_ text: String) -> [GitHubAccount] {
        var accounts: [GitHubAccount] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)

            if let account = account(in: line) {
                accounts.append(account)
            } else if line.hasPrefix("- Active account:"), !accounts.isEmpty {
                accounts[accounts.count - 1].isActive =
                    line.hasSuffix("true")
            }
        }
        return accounts
    }

    /// `… to <host> account <login> (<source>)`, if this line is one.
    private static func account(in line: String) -> GitHubAccount? {
        let valid: Bool
        if line.contains("Logged in to") { valid = true }
        else if line.contains("Failed to log in to") { valid = false }
        else { return nil }

        let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
        // The last "to" before "account" is the one carrying the host: "Failed
        // to log in to ghe.corp" has three of them, and taking the first gives
        // you a host called "log".
        guard let marker = words.firstIndex(of: "account"),
              marker >= 2, marker + 1 < words.count else { return nil }
        let host = words[marker - 1]
        let login = words[marker + 1]
        guard !host.isEmpty, !login.isEmpty else { return nil }
        return GitHubAccount(host: host, login: login, isValid: valid)
    }
}
