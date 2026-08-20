import Foundation

/// Who a message is addressed to.
///
/// The names are the ones already in the user's shell aliases — `@claude-p`,
/// `@claude-w` — rather than the `Account` raw values, because those are a
/// storage detail (`work` is labelled Enterprise everywhere a person looks) and
/// nobody should have to learn a second vocabulary to use the same accounts.
enum AgentMention {

    /// Every spelling that resolves, longest-first so `@claude-w` is never read
    /// as `@claude` followed by stray text.
    static let names: [(String, Account)] = [
        ("claude-personal", .personal), ("claude-p", .personal), ("personal", .personal),
        ("claude-work", .work), ("claude-w", .work), ("enterprise", .work), ("work", .work),
        ("kimi", .kimi),
        ("copilot", .copilot),
    ].sorted { $0.0.count > $1.0.count }

    /// One agent, and optionally how it should run.
    ///
    /// Both qualifiers come off the same `:`-separated tail and are told apart
    /// by what they say rather than by position, so `@claude-p:opus:max` and
    /// `@claude-p:max:opus` mean the same thing. Position would be the smaller
    /// rule to implement and the worse one to use: nobody remembers which of
    /// two colons is which, and getting it backwards would silently run an
    /// effort level as a model hint.
    struct Pick: Equatable {
        /// Which conversation, not merely which subscription. `@kimi` and
        /// `@kimi#2` are two picks on one account — see `Seat`.
        let seat: Seat
        /// Whatever followed the colon and isn't an effort level — `free`,
        /// `haiku`, `gpt-5-mini`. Resolved later, against the list that account
        /// actually offers.
        let model: String?
        /// `@claude-p:max`. Only Claude accounts have reasoning effort at all;
        /// on one that doesn't, `max` is read as a model hint instead, because
        /// on that account that is the only thing it could have meant.
        var effort: EffortChoice?

        /// Which subscription pays, and whose model catalogue applies. Several
        /// picks can share one.
        var account: Account { seat.account }

        init(seat: Seat, model: String?, effort: EffortChoice? = nil) {
            self.seat = seat
            self.model = model
            self.effort = effort
        }

        /// The seat-1 spelling, for every caller that predates seats and means
        /// "this account's own conversation".
        init(account: Account, model: String?, effort: EffortChoice? = nil) {
            self.init(seat: Seat(account), model: model, effort: effort)
        }

        /// `@kimi#2:k3` — this pick, written as the grammar `parse` reads.
        ///
        /// Deliberately here rather than in the view that needs it. The team
        /// control exists so nobody has to know this spelling, and the price of
        /// that is a second writer of it — so the writer lives beside the
        /// reader, where a change to one is in front of whoever changes the
        /// other, and the suite round-trips this string back through `parse`.
        /// The two disagreeing would not break anything loudly: the control
        /// would compose a line, the parser would find no crew in it, and the
        /// message would go to one agent with nothing to say it had been.
        var mention: String {
            var out = seat.mention
            if let model { out += ":" + model }
            if let effort { out += ":" + effort.rawValue }
            return out
        }
    }

    /// What a mention's `:`-separated tail means for this account.
    ///
    /// First of each kind wins, matching the rule one level up: a mention is
    /// one instruction, not a conversation with itself.
    static func qualify(_ parts: [String], for account: Account) -> (model: String?, effort: EffortChoice?) {
        var model: String?
        var effort: EffortChoice?
        for part in parts where !part.isEmpty {
            if account.hasEffort, effort == nil,
               let level = EffortChoice(rawValue: part.lowercased()) {
                effort = level
                continue
            }
            if model == nil { model = part }
        }
        return (model, effort)
    }

    /// The crew named in a message, in the order named, and the message with
    /// the mentions taken out.
    ///
    /// Order is the whole point: the first one named leads. Duplicates collapse
    /// to their first appearance, so `@kimi fix it, @kimi really` is one agent
    /// and not two copies racing each other in the same directory.
    ///
    /// **Duplicates collapse by seat, not by account.** `@kimi#1 @kimi#2` is
    /// two agents on one subscription and always was meant to be sayable; it is
    /// `@kimi @kimi` that is one agent said twice. The distinction is the whole
    /// point of the `#` — an accidental repetition and a deliberate second
    /// instance no longer look identical, so neither has to be guessed at.
    static func parse(_ text: String) -> (crew: [Pick], prompt: String) {
        var crew: [Pick] = []
        var out = text

        // Word-boundary matching on `@name`, an optional `#seat`, then any
        // number of `:qualifier` segments. A bare `@` followed by anything
        // else — an email address, a file mention — is left exactly as typed.
        //
        // The tail is captured whole rather than as repeated groups, because a
        // repeated capture group in NSRegularExpression only ever hands back
        // its last match — `@kimi:k3:max` would arrive as `max` with `k3`
        // silently gone.
        //
        // The seat digits are bounded in the pattern as well as clamped in
        // `Seat`. `@kimi#900` should fail to be a nine-hundredth agent at the
        // grammar, not quietly become the fourth one.
        let pattern = "(?<![\\w@])@([A-Za-z][A-Za-z0-9-]*)(?:#([0-9]{1,2}))?((?::[A-Za-z0-9._-]+)*)"
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
            let number = Range(match.range(at: 2), in: text)
                .flatMap { Int(text[$0]) }
            // Out of range is refused rather than clamped here, and left in the
            // prose as typed. Silently turning `@kimi#7` into the fourth seat
            // would spend a subscription the person didn't ask for; leaving it
            // visible in the prompt is how they find out it meant nothing.
            if let number, number < 1 || number > Seat.limit { continue }
            let seat = Seat(account, number ?? 1)
            let tail = Range(match.range(at: 3), in: text).map { String(text[$0]) } ?? ""
            let parts = tail.split(separator: ":").map(String.init)
            let qualifiers = qualify(parts, for: account)
            // First mention wins, and it's the one that carries the
            // qualifiers — a second `@kimi` later in the same sentence is the
            // same agent, not a chance to change its mind halfway through a
            // request.
            if !crew.contains(where: { $0.seat == seat }) {
                crew.append(Pick(seat: seat,
                                 model: qualifiers.model, effort: qualifiers.effort))
            }
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

    /// `kimi#2` — the written form of a seat, back into one.
    ///
    /// `nil` for a name nobody goes by, and for a seat number outside the
    /// range, which are different mistakes with the same answer: this doesn't
    /// address anybody. The caller decides what to say about it — a plan
    /// refuses the assignment and tells the lead, a message is dropped.
    static func seat(forHandle handle: String) -> Seat? {
        let text = handle.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "@ "))
        let parts = text.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard let name = parts.first.map(String.init),
              let account = account(forHandle: name) else { return nil }
        guard parts.count == 2 else { return Seat(account) }
        guard let number = Int(parts[1]), number >= 1, number <= Seat.limit else { return nil }
        return Seat(account, number)
    }
}
