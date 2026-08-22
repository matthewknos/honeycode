import Foundation

/// Every ACP-speaking agent this app knows how to add, and what to run.
///
/// Honeycode has always been able to drive any CLI that speaks the Agent Client
/// Protocol — that is the whole of what `CustomAccount` is for — and the only
/// route to one was a form with six fields, four of which you had to go and
/// look up first. So the honest answer to "what else does this work with" was a
/// shrug and a link to somebody else's documentation, which is a poor answer to
/// give on the second screen of a first run.
///
/// This is that list, taken from the protocol's own registry. Adding one is a
/// click: the entry already holds the command, its arguments, whether it is a
/// Node program and any environment it needs, and the rest of an account — a
/// handle, a colour — has a sensible answer that can be changed afterwards.
///
/// Two kinds are in here. Most are fetched on demand by `npx` or `uvx`, so
/// there is nothing to install and the row works the moment it is added; the
/// first launch pays for the download, and `ACPAdapter` queues anything typed
/// before the handshake finishes. The rest ship a binary you install yourself,
/// and for those this holds the name it lands on your PATH as, and a `site` to
/// go and get it from.
///
/// **Generated, not fetched.** `tools/acp-catalogue.py` rewrites
/// `AgentCatalogue+Generated.swift` from the registry, and the app makes no
/// request of its own — the first-run flow says in as many words that nothing
/// leaves this Mac except through the agent CLIs themselves, and a list of
/// names is not worth making that sentence false. The cost is that the script
/// has to be re-run; the benefit is that the list can be read in a diff.
enum AgentCatalogue {}

/// One entry: what it is called, and what to launch.
struct CatalogueAgent: Identifiable, Hashable, Sendable {
    /// The registry's id, and what a saved account records to say where it
    /// came from. Stable across regenerations.
    let id: String
    let name: String
    /// What it would answer to after an `@`, before anything already taken is
    /// worked around — see `AgentCatalogue.draft`.
    let handle: String
    /// The registry's own one-line description, trimmed. Not rewritten: these
    /// are other people's tools and their own words for them are the ones that
    /// will match what you read elsewhere.
    let blurb: String

    let command: String
    let arguments: [String]
    let isNode: Bool
    let environment: [String: String]

    /// Where to get it, for one that ships a binary. Nil means `npx` or `uvx`
    /// fetches it, so there is nothing to install and nowhere to send you.
    let site: String?

    /// Whether adding it is the whole of the job.
    var isFetched: Bool { site == nil }
}

extension AgentCatalogue {

    /// This entry as an account, ready to save.
    ///
    /// The two fields the registry can't decide are decided here rather than
    /// asked about. A handle that is already taken gets a number, because the
    /// alternative is a form that refuses to save and a person working out why;
    /// and the colour is whichever is least used, because the only job a colour
    /// does is telling one row from another.
    static func draft(_ agent: CatalogueAgent,
                      existing: [CustomAccount]) -> CustomAccount {
        CustomAccount(title: agent.name,
                      shortTitle: agent.name,
                      handle: freeHandle(agent.handle, existing: existing),
                      tint: leastUsedTint(existing),
                      command: agent.command,
                      arguments: agent.arguments,
                      isNode: agent.isNode,
                      // `standard` for everything. The one agent known to speak
                      // the other dialect is Kimi, which ships built in — and
                      // guessing wrong here is recoverable in the editor, while
                      // guessing wrong and saying so confidently is not.
                      dialect: .standard,
                      // Nothing is asked of an agent nobody has checked. See
                      // `ACPAgent.UsageKind` for why `/usage` is not free.
                      usageReports: .none,
                      environment: agent.environment,
                      catalogue: agent.id)
    }

    /// The entry an account came from, if it came from here.
    static func entry(_ id: String?) -> CatalogueAgent? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    /// Everything, with the ones already added marked rather than removed.
    ///
    /// Marked, because a list that silently shortens as you use it is one you
    /// cannot check your work in: the question "did I already add Gemini" has a
    /// better answer than the row being gone.
    static func added(_ agent: CatalogueAgent, in existing: [CustomAccount]) -> Bool {
        existing.contains { $0.catalogue == agent.id }
    }

    /// Name, handle and blurb, case- and punctuation-insensitively.
    static func search(_ query: String) -> [CatalogueAgent] {
        let needle = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return all }
        return all.filter {
            $0.name.lowercased().contains(needle)
                || $0.handle.contains(needle)
                || $0.blurb.lowercased().contains(needle)
        }
    }

    /// A handle nothing already answers to.
    private static func freeHandle(_ wanted: String,
                                   existing: [CustomAccount]) -> String {
        func taken(_ handle: String) -> Bool {
            AgentMention.builtInNames.contains { $0.0 == handle }
                || existing.contains { $0.handle.lowercased() == handle }
        }
        guard taken(wanted) else { return wanted }
        // Two is where a second one starts. Bounded because an unbounded loop
        // over a name somebody could have taken a hundred times is a hang.
        for suffix in 2...99 where !taken("\(wanted)-\(suffix)") {
            return "\(wanted)-\(suffix)"
        }
        return wanted
    }

    private static func leastUsedTint(_ existing: [CustomAccount]) -> CustomAccount.Tint {
        var counts: [CustomAccount.Tint: Int] = [:]
        for account in existing { counts[account.tint, default: 0] += 1 }
        // `min(by:)` keeps the first of equals, and `allCases` has a fixed
        // order, so an empty roster always starts at the same colour.
        return CustomAccount.Tint.allCases
            .min { counts[$0, default: 0] < counts[$1, default: 0] } ?? .teal
    }
}
