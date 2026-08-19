import Foundation

/// One model a session can run.
///
/// A struct rather than the fixed three-case enum this replaces, because the
/// three accounts genuinely differ: a work seat is entitled to a different set
/// than a personal subscription, and Copilot's list arrives over the wire with
/// its own ids and its own pricing. A hardcoded enum could only ever be right
/// for one of them.
struct AgentModel: Identifiable, Hashable, Codable {
    /// What goes on the wire — `--model` for Claude, `modelId` for ACP.
    let id: String
    let title: String
    let blurb: String
    /// Vendor, for grouping. Copilot offers twenty models across five vendors
    /// and a flat list of that is a scroll rather than a choice.
    var family: String = "Anthropic"

    /// Copilot's quota multiplier as a number — `0` for the free ones, `15` for
    /// Opus 5. Nil where the account doesn't report one, which is every Claude
    /// account: a subscription bills in dollars and the CLI says so per turn.
    ///
    /// The same fact as `blurb`, which is the rendered version of it. Kept
    /// separately because "which of these is cheapest" is a comparison, and
    /// comparing prose means parsing it back out again — which is exactly what
    /// `ai` was about to do to offer `@copilot:cheap`.
    var usage: Double?

    /// Derived from the id, because ACP doesn't say who makes what.
    static func family(of id: String) -> String {
        switch id.components(separatedBy: CharacterSet(charactersIn: "-.")).first ?? id {
        case "auto":   return "Recommended"
        case "claude": return "Anthropic"
        case "gpt":    return "OpenAI"
        case "gemini": return "Google"
        case "kimi":   return "Moonshot"
        case "mai":    return "Microsoft"
        default:       return "Other"
        }
    }
}

/// Which models each account can actually use.
enum ModelCatalog {

    /// Used when nothing better can be determined — the alias every Claude
    /// install understands.
    static let fallback = AgentModel(id: "opus", title: "Opus", blurb: "Default model")

    static func models(for account: Account) -> [AgentModel] {
        guard let configDir = account.configDir else { return remembered(for: account) }
        return claudeModels(configDir: configDir)
    }

    // MARK: ACP accounts

    /// What to show before the agent has connected.
    ///
    /// Both ACP agents announce their real list on `session/new`, so anything
    /// written here is a placeholder that exists for the second or so before the
    /// process answers — and, more importantly, for the very first session on a
    /// machine. The last live list is cached per account rather than hardcoded,
    /// because a list written into this file goes stale the week it's written.
    static func remembered(for account: Account) -> [AgentModel] {
        if let data = Prefs.store.data(forKey: cacheKey(account)),
           let cached = try? JSONDecoder().decode([AgentModel].self, from: data),
           !cached.isEmpty {
            return cached
        }
        return builtInFallback(for: account)
    }

    /// Whether the last live list is on disk, as opposed to the built-in
    /// placeholder.
    ///
    /// The difference matters to anyone deciding whether to *wait*: a cached
    /// list is the real one the agent sent last time, so it can be used at
    /// once, while the built-in three are a guess worth six seconds to replace.
    static func hasRemembered(for account: Account) -> Bool {
        guard let data = Prefs.store.data(forKey: cacheKey(account)),
              let cached = try? JSONDecoder().decode([AgentModel].self, from: data)
        else { return false }
        return !cached.isEmpty
    }

    static func remember(_ models: [AgentModel], for account: Account) {
        guard !models.isEmpty, let data = try? JSONEncoder().encode(models) else { return }
        Prefs.store.set(data, forKey: cacheKey(account))
    }

    private static func cacheKey(_ account: Account) -> String {
        "models." + account.rawValue
    }

    private static func builtInFallback(for account: Account) -> [AgentModel] {
        switch account {
        case .kimi:
            return [AgentModel(id: "kimi-code/kimi-for-coding", title: "K2.7 Coding",
                               blurb: "", family: "Moonshot")]
        default:
            return copilotFallback
        }
    }

    // MARK: Claude

    /// Models Honeycode knows how to present, best first. Entitlement filters this
    /// list; it never extends it. The CLI's cache also carries older dated
    /// builds — `claude-3-opus-20240229` and friends — and surfacing a dozen
    /// entries in a picker to be thorough makes it useless to actually pick from.
    private static let known: [AgentModel] = [
        AgentModel(id: "claude-opus-5", title: "Opus 5",
                   blurb: "For complex tasks"),
        AgentModel(id: "claude-opus-4-8", title: "Opus 4.8",
                   blurb: "Previous generation, still strong"),
        AgentModel(id: "claude-sonnet-5", title: "Sonnet 5",
                   blurb: "Most efficient for everyday tasks"),
        AgentModel(id: "claude-sonnet-4-6", title: "Sonnet 4.6",
                   blurb: "Previous generation"),
        AgentModel(id: "claude-haiku-4-5", title: "Haiku 4.5",
                   blurb: "Fastest for quick answers"),
    ]

    /// Read the CLI's own entitlement cache.
    ///
    /// `~/.claude*/.claude.json` holds `modelAccessCache` — an array of
    /// `{apiName, entitled}` the CLI keeps for exactly this purpose — plus
    /// `additionalModelOptionsCache` for models offered beyond the standard
    /// set. Reading it is how Honeycode can tell that a work seat has Opus 4.8 but
    /// *not* Opus 5, which no amount of hardcoding would have got right.
    private static func claudeModels(configDir: String) -> [AgentModel] {
        let url = URL(fileURLWithPath: configDir).appendingPathComponent(".claude.json")
        let json = (try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]

        var entitlement: [String: Bool] = [:]
        for entry in json?["modelAccessCache"] as? [[String: Any]] ?? [] {
            guard let name = entry["apiName"] as? String,
                  let allowed = entry["entitled"] as? Bool else { continue }
            entitlement[name] = allowed
        }

        /// Cache entries carry dated suffixes (`claude-haiku-4-5-20251001`), so
        /// this matches by prefix.
        ///
        /// An *empty* cache means no restrictions were ever recorded, which is
        /// what a personal subscription looks like — so everything is allowed.
        /// A populated cache that simply doesn't mention a model is treated as
        /// a no: on a restricted seat the cache is comprehensive, and guessing
        /// generously there would put a model in the picker that errors when
        /// you choose it.
        func entitled(_ id: String) -> Bool {
            guard !entitlement.isEmpty else { return true }
            let matches = entitlement.filter { $0.key.hasPrefix(id) }
            return matches.isEmpty ? false : matches.values.contains(true)
        }

        var models: [AgentModel] = []

        // Extras come first — they're offered precisely because they sit above
        // the standard set.
        for extra in json?["additionalModelOptionsCache"] as? [[String: Any]] ?? [] {
            guard let value = extra["value"] as? String else { continue }
            // Values can carry a context-window suffix: `claude-fable-5[1m]`.
            // Entitlement is recorded against the bare id.
            let base = value.components(separatedBy: "[").first ?? value
            guard entitled(base) else { continue }

            // Descriptions read "Fable 5 · Most capable for…" — the half before
            // the separator is a better title than the bare label ("Fable").
            let description = extra["description"] as? String ?? ""
            let parts = description.components(separatedBy: " · ")
            models.append(AgentModel(
                id: value,
                title: parts.count > 1 ? parts[0] : (extra["label"] as? String ?? base),
                blurb: parts.count > 1 ? parts[1] : ""))
        }

        models += known.filter { entitled($0.id) }
        return models.isEmpty ? [fallback] : models
    }

    // MARK: Copilot

    /// What to show before the agent has connected.
    ///
    /// Hardcoding this list was a mistake worth naming: Copilot offers twenty
    /// models across Anthropic, OpenAI, Google, Moonshot and Microsoft, and any
    /// list written here goes stale the week it's written. So the last live
    /// list is cached instead, and the built-in one only ever appears before
    /// the very first Copilot session on a machine.
    static var copilotFallback: [AgentModel] {
        [
            AgentModel(id: "claude-sonnet-5", title: "Claude Sonnet 5",
                       blurb: "1× usage", usage: 1),
            AgentModel(id: "claude-opus-5", title: "Claude Opus 5",
                       blurb: "15× usage", usage: 15),
            AgentModel(id: "claude-haiku-4.5", title: "Claude Haiku 4.5",
                       blurb: "0.33× usage", usage: 0.33),
        ]
    }

    /// Parse ACP's `models.availableModels`, and remember it.
    ///
    /// The usage multiplier is the useful part and it lives in `_meta` —
    /// Copilot bills by request against a quota, so Opus 5 costs 45× as much of
    /// it as Haiku, and Gemini 3.5 Flash costs 14× despite the name. That
    /// belongs in the picker, not buried.
    static func copilotModels(_ list: [[String: Any]]) -> [AgentModel] {
        let models: [AgentModel] = list.compactMap { entry in
            guard let id = entry["modelId"] as? String else { return nil }
            let meta = entry["_meta"] as? [String: Any]
            // Disabled models are listed alongside the rest; offering one is
            // offering an error. `auto` carries no `_meta` at all, so the
            // check has to tolerate its absence rather than require "enabled".
            if let enablement = meta?["copilotEnablement"] as? String,
               enablement != "enabled" { return nil }

            return AgentModel(id: id,
                              title: entry["name"] as? String ?? id,
                              blurb: usageLabel(meta) ?? (entry["description"] as? String ?? ""),
                              family: AgentModel.family(of: id),
                              usage: usageValue(meta))
        }
        remember(models, for: .copilot)
        return models
    }

    /// `"15x"` → `"15× usage"`. `"0x"` gets said plainly: it means the model
    /// doesn't draw down the quota at all, which is the most useful thing the
    /// row could tell you and reads as an error rendered literally.
    /// `"0.33x"` → `0.33`. The number behind the label.
    private static func usageValue(_ meta: [String: Any]?) -> Double? {
        guard let usage = meta?["copilotUsage"] as? String else { return nil }
        return Double(usage.replacingOccurrences(of: "x", with: ""))
    }

    private static func usageLabel(_ meta: [String: Any]?) -> String? {
        guard let usage = meta?["copilotUsage"] as? String else { return nil }
        if usage == "0x" { return "Free — doesn't use quota" }
        return usage.replacingOccurrences(of: "x", with: "× usage")
    }
}
