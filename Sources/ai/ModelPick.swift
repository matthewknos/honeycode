import Foundation

/// Choosing a model without having to remember what any of them are called.
///
/// `gpt-5.6-sol` is not a thing anyone should have to type from memory, and a
/// feature that requires it is a feature that goes unused. So there are three
/// ways in, and the useful one is first:
///
/// - **By intent** — `@copilot:free`, `:cheap`, `:best`. Resolved from the
///   quota multiplier the agent itself reports, so it stays right as the
///   line-up changes. `:free` is the one that matters: Copilot has models at
///   `0×` that don't draw down the quota at all.
/// - **By any part of the name** — `@copilot:mini`, `:haiku`, `:gemini`.
///   Subsequence matching, so `:g35f` finds Gemini 3.5 Flash.
/// - **By exact id**, for when you know precisely what you want.
///
/// And `/models` lists them, so the answer to "what can I write here" is a
/// command rather than a memory.
enum ModelPick {

    enum Outcome {
        case chosen(AgentModel)
        /// Nothing matched. Carries what was available, for the message.
        case unknown(hint: String, options: [AgentModel])
    }

    static let intents = ["free", "cheap", "best", "fast", "auto"]

    static func resolve(_ hint: String, from models: [AgentModel]) -> Outcome {
        let needle = hint.lowercased().trimmingCharacters(in: .whitespaces)
        guard !models.isEmpty else { return .unknown(hint: hint, options: []) }

        // 1. Exact id, for people who know what they want.
        if let exact = models.first(where: { $0.id.lowercased() == needle }) {
            return .chosen(exact)
        }

        // 2. Intent. Priced models sort by what they actually cost; where no
        //    price is reported — every Claude account, which bills in dollars —
        //    fall back to what the name says, since `haiku` and `opus` are a
        //    reliable ordering even when nothing numeric is.
        switch needle {
        case "auto":
            if let auto = models.first(where: { $0.id.lowercased() == "auto" }) {
                return .chosen(auto)
            }
        case "free":
            if let free = priced(models).first(where: { ($0.usage ?? 1) == 0 }) {
                return .chosen(free)
            }
            // No free tier here. Say so rather than silently billing for the
            // nearest thing — "free" is a request about money, not about speed.
            return .unknown(hint: hint, options: models)
        case "cheap", "fast":
            if let cheapest = priced(models).first { return .chosen(cheapest) }
            if let named = byReputation(models, cheap: true) { return .chosen(named) }
        case "best":
            if let dearest = priced(models).last { return .chosen(dearest) }
            if let named = byReputation(models, cheap: false) { return .chosen(named) }
        default:
            break
        }

        // 3. Any part of the name. Title first — it's what `/models` shows, so
        //    it's what you'll have just read.
        let ranked = models.compactMap { model -> (AgentModel, Int)? in
            let onTitle = Fuzzy.score(needle, in: model.title)
            let onID = Fuzzy.score(needle, in: model.id)
            guard let best = [onTitle, onID].compactMap({ $0 }).min() else { return nil }
            return (model, best)
        }.sorted { $0.1 < $1.1 }

        if let winner = ranked.first { return .chosen(winner.0) }
        return .unknown(hint: hint, options: models)
    }

    /// Models that report a price, cheapest first.
    private static func priced(_ models: [AgentModel]) -> [AgentModel] {
        models.filter { $0.usage != nil }.sorted { ($0.usage ?? 0) < ($1.usage ?? 0) }
    }

    /// The ordering the names imply, for accounts that report no price.
    private static func byReputation(_ models: [AgentModel], cheap: Bool) -> AgentModel? {
        let small = ["haiku", "mini", "flash", "lite", "small"]
        let large = ["opus", "sol", "pro", "max"]
        let wanted = cheap ? small : large
        for token in wanted {
            if let hit = models.first(where: { $0.id.lowercased().contains(token) }) {
                return hit
            }
        }
        return nil
    }

    /// One line per model, for `/models`.
    static func describe(_ model: AgentModel, current: Bool) -> String {
        let mark = current ? "•" : " "
        let price: String
        if let usage = model.usage {
            price = usage == 0 ? "free" : (usage == floor(usage)
                ? "\(Int(usage))×" : String(format: "%g×", usage))
        } else {
            price = ""
        }
        let name = model.title.padding(toLength: max(28, model.title.count),
                                       withPad: " ", startingAt: 0)
        return "  \(mark) \(name)\(price.padding(toLength: 7, withPad: " ", startingAt: 0))\(Console.dim(model.id))"
    }
}
