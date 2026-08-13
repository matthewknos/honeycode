import Foundation

/// Who a message is addressed to.
///
/// The names are the ones already in the user's shell aliases — `@claude-p`,
/// `@claude-w` — rather than the `Account` raw values, because those are a
/// storage detail (`work` is labelled Enterprise everywhere a person looks) and
/// nobody should have to learn a second vocabulary to use the same accounts.
enum Mention {

    /// Every spelling that resolves, longest-first so `@claude-w` is never read
    /// as `@claude` followed by stray text.
    static let names: [(String, Account)] = [
        ("claude-personal", .personal), ("claude-p", .personal), ("personal", .personal),
        ("claude-work", .work), ("claude-w", .work), ("enterprise", .work), ("work", .work),
        ("kimi", .kimi),
        ("copilot", .copilot),
    ].sorted { $0.0.count > $1.0.count }

    /// The crew named in a message, in the order named, and the message with
    /// the mentions taken out.
    ///
    /// Order is the whole point: the first one named leads. Duplicates collapse
    /// to their first appearance, so `@kimi fix it, @kimi really` is one agent
    /// and not two copies racing each other in the same directory.
    static func parse(_ text: String) -> (crew: [Account], prompt: String) {
        var crew: [Account] = []
        var out = text

        // Word-boundary matching on `@name`. A bare `@` followed by anything
        // else — an email address, a file mention — is left exactly as typed.
        let pattern = "(?<![\\w@])@([A-Za-z][A-Za-z0-9-]*)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return ([], text)
        }
        let range = NSRange(text.startIndex..., in: text)
        var cuts: [Range<String.Index>] = []

        for match in regex.matches(in: text, range: range) {
            guard let whole = Range(match.range, in: text),
                  let wordRange = Range(match.range(at: 1), in: text) else { continue }
            let word = String(text[wordRange]).lowercased()
            guard let account = names.first(where: { $0.0 == word })?.1 else { continue }
            if !crew.contains(account) { crew.append(account) }
            cuts.append(whole)
        }

        // Removed back to front so earlier indices stay valid.
        for cut in cuts.reversed() { out.removeSubrange(cut) }
        // Cutting `@kimi` out of the middle of a sentence leaves the spaces
        // that were either side of it. One pass of a literal two-space replace
        // doesn't do it — three mentions in a row leave a longer run than that.
        out = out.replacingOccurrences(of: "[ \\t]{2,}", with: " ",
                                       options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (crew, out)
    }

    /// `@claude-p` — the canonical spelling, for prompts and labels.
    static func handle(_ account: Account) -> String {
        switch account {
        case .personal: return "claude-p"
        case .work:     return "claude-w"
        case .kimi:     return "kimi"
        case .copilot:  return "copilot"
        }
    }

    static func account(forHandle handle: String) -> Account? {
        names.first { $0.0 == handle.lowercased() }?.1
    }
}
