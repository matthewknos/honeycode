import Foundation

/// What Tab would put on the line.
struct Completion: Equatable {

    /// In the order they should be offered, and never empty — no candidates is
    /// spelled as no `Completion` at all.
    let candidates: [String]
    /// The stretch of the line these replace, in character offsets rather than
    /// `String.Index`, because the editor holds the line as `[Character]` and
    /// every offset here is one it can subscript.
    let range: Range<Int>

    /// As much as can be typed without choosing between the candidates. Equal
    /// to the only candidate when there is one, which is why the editor doesn't
    /// need to special-case that.
    var shared: String {
        guard var prefix = candidates.first else { return "" }
        for candidate in candidates.dropFirst() {
            while !candidate.hasPrefix(prefix) {
                prefix = String(prefix.dropLast())
                if prefix.isEmpty { return "" }
            }
        }
        return prefix
    }

    /// The line and cursor after Tab, or nil when there is nothing left to
    /// insert — the caller shows the candidates instead.
    ///
    /// Here rather than in the editor because it is the half of pressing Tab
    /// that can be checked. The editor's job is to decode the keypress and draw
    /// the result; deciding where the caret ends up is arithmetic, and
    /// arithmetic belongs where a test can reach it.
    func applied(to line: [Character]) -> (line: [Character], cursor: Int)? {
        let typed = String(line[range])
        let best = shared
        guard best.count > typed.count else { return nil }

        var out = line
        out.replaceSubrange(range, with: Array(best))
        var at = range.lowerBound + best.count

        // A settled choice is followed by a space, because that is what you
        // were going to type. Except after a directory, which is a step on the
        // way somewhere — and except where the space is already there, which is
        // what completing a mention in the middle of a sentence looks like.
        if candidates.count == 1, !best.hasSuffix("/"),
           at == out.count || !out[at].isWhitespace {
            out.insert(" ", at: at)
            at += 1
        }
        return (out, at)
    }
}

/// Tab, worked out.
///
/// Pure, and kept that way deliberately: everything below is a function of the
/// line, the cursor and a directory, so `Tests/CLI` can ask it questions
/// without a terminal, an account or a running crew. The editor is the part
/// that can't be tested here, so the less of this that lives in it the better.
enum Completions {

    /// - Parameter directory: what a bare or relative path is relative to.
    ///   Passed rather than read from the process so a test can point it at a
    ///   folder it built.
    static func of(_ line: String, at cursor: Int, directory: URL) -> Completion? {
        let characters = Array(line)
        guard cursor >= 0, cursor <= characters.count else { return nil }

        var start = cursor
        while start > 0, !characters[start - 1].isWhitespace { start -= 1 }
        let token = String(characters[start..<cursor])

        // A slash is a command only at the start of the line. Anywhere else it
        // is a path, or prose, and completing `and/or` to `/accounts` would be
        // a strange thing for a program to do.
        if token.hasPrefix("/"), start == 0 {
            return offer(Commands.spellings.map { "/" + $0 },
                         matching: token, over: start..<cursor)
        }
        if token.hasPrefix("@") {
            return mention(token, over: start..<cursor)
        }
        return path(token, over: start..<cursor, directory: directory)
    }

    // MARK: - Who

    /// `@cla` → the handles; `@kimi:k` → what that account can be asked for.
    private static func mention(_ token: String, over range: Range<Int>) -> Completion? {
        let body = Array(token.dropFirst())

        // A qualifier. `@claude-p:opus:max` is legal and means the same as
        // `@claude-p:max:opus`, so the account is whatever precedes the first
        // colon and the thing being typed is whatever follows the last.
        if let lastColon = body.lastIndex(of: ":") {
            let firstColon = body.firstIndex(of: ":") ?? lastColon
            let head = String(body[..<firstColon])
            let typed = String(body[(lastColon + 1)...])
            // +1 for the `@`, +1 to sit after the colon.
            let from = range.lowerBound + 1 + lastColon + 1
            return offer(qualifiers(for: head), matching: typed, over: from..<range.upperBound)
        }

        return offer(handles().map { "@" + $0 }, matching: token, over: range)
    }

    /// Every spelling of every account you have, canonical first.
    ///
    /// Aliases are included rather than tidied away, because they exist for
    /// people who already type them: somebody whose fingers know `@work` should
    /// get `@work`, not a list of the two names this program prefers.
    static func handles() -> [String] {
        let enabled = Account.enabled
        let known = Set(enabled)
        var names = enabled.map { AgentMention.handle($0) }
        for (name, account) in AgentMention.names.sorted(by: { $0.0 < $1.0 })
        where known.contains(account) && !names.contains(name) {
            names.append(name)
        }
        return names
    }

    /// What can follow a colon: the intents, the effort levels on the accounts
    /// that have them, and any model this account has actually reported.
    ///
    /// Reported, not guessed. `ModelCatalog.remembered` is what `/models` last
    /// learned, so the ids offered here are ids that exist — an account nobody
    /// has asked yet simply completes the intents, which is honest and is also
    /// the answer most people want.
    static func qualifiers(for handle: String) -> [String] {
        var options = ModelPick.intents
        guard let account = AgentMention.account(forHandle: handle) else { return options }
        switch account {
        case .personal, .work: options += EffortChoice.allCases.map(\.rawValue)
        case .kimi, .copilot, .custom: break
        }
        options += ModelCatalog.remembered(for: account).map(\.id)
        return options
    }

    // MARK: - What

    /// Files, relative to where the work is happening.
    ///
    /// Offered for a bare word as well as for something with a slash in it,
    /// which is a judgement call: it means Tab in the middle of a sentence can
    /// complete a word to a filename. That trade is worth making because the
    /// sentences typed here are mostly about files, and the cost of a wrong
    /// guess is one undo of a key you pressed on purpose.
    private static func path(_ token: String, over range: Range<Int>,
                             directory: URL) -> Completion? {
        guard !token.isEmpty else { return nil }

        var lead = ""
        var partial = token
        if let slash = token.lastIndex(of: "/") {
            lead = String(token[...slash])
            partial = String(token[token.index(after: slash)...])
        }

        let folder: URL
        if lead.hasPrefix("~/") {
            folder = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(String(lead.dropFirst(2)))
        } else if lead.hasPrefix("/") {
            folder = URL(fileURLWithPath: lead)
        } else {
            folder = directory.appendingPathComponent(lead)
        }

        guard let entries = try? FileManager.default
            .contentsOfDirectory(atPath: folder.path) else { return nil }

        // A dotfile is offered once you have said you want one. Otherwise the
        // first Tab in a repository is a screenful of .git.
        let wantsHidden = partial.hasPrefix(".")
        let candidates = entries
            .filter { wantsHidden || !$0.hasPrefix(".") }
            .sorted()
            .map { name -> String in
                var isFolder: ObjCBool = false
                let full = folder.appendingPathComponent(name).path
                let found = FileManager.default.fileExists(atPath: full, isDirectory: &isFolder)
                return lead + name + (found && isFolder.boolValue ? "/" : "")
            }
        return offer(candidates, matching: token, over: range)
    }

    // MARK: -

    /// Filter, and say nothing rather than nothing useful.
    ///
    /// Case-insensitive on the way in and untouched on the way out: `@CL`
    /// should find `@claude-p`, and what lands on the line is the account's
    /// name rather than a rewriting of what was typed.
    private static func offer(_ candidates: [String], matching typed: String,
                              over range: Range<Int>) -> Completion? {
        let wanted = typed.lowercased()
        let matches = candidates.filter { $0.lowercased().hasPrefix(wanted) }
        guard !matches.isEmpty else { return nil }
        return Completion(candidates: matches, range: range)
    }
}
