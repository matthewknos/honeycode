import Foundation

/// `ai --describe` — what this tool can do, as JSON.
///
/// This exists because of a specific failure, and the failure is worth keeping
/// written down. A coding agent driving `ai` was asked which model `@kimi`
/// runs, and whether it could be changed. It grepped the filesystem, found
/// nothing — the catalogue lives in a compiled binary and in `UserDefaults` —
/// and told the user the model could neither be seen nor changed from the
/// command line. Both halves were wrong. `@kimi:k3` already worked, and K3 was
/// sitting in the cached catalogue on that same machine.
///
/// The lesson is not that it should have looked harder. It is that a tool whose
/// capabilities are discoverable only by reading its source will be described
/// wrongly by anything that cannot read its source, and that "I found no config
/// on disk" reads as "it cannot be done" to whoever asked. Silence gets
/// reported as absence.
///
/// So the tool answers for itself, in a form another program can parse, built
/// from the same types the run uses — `AgentMention` for the grammar,
/// `ModelPick` for the intent words, the live session for the catalogue. There
/// is no separate description to go stale, because there is no description: it
/// is generated from the behaviour it documents.
@MainActor
enum Describe {

    // MARK: The shape on the wire

    /// Deliberately its own type rather than encoding `AgentModel` directly.
    /// `AgentModel` is storage — it changes when the app needs it to. This is a
    /// contract something else parses, and it should only change on purpose.
    private struct Model: Encodable {
        let id: String
        let title: String
        let family: String
        /// Quota multiplier where the account reports one. `0` means it draws
        /// no quota at all; null means the account bills in dollars instead,
        /// which is every Claude seat.
        let usage: Double?

        init(_ model: AgentModel) {
            id = model.id
            title = model.title
            family = model.family
            usage = model.usage
        }
    }

    private struct AccountReport: Encodable {
        let handle: String
        let account: String
        let title: String
        let mention: String
        /// What this account will run if nothing overrides it.
        let current: Model?
        let models: [Model]
        /// Where this list came from, which decides how much to trust it.
        ///
        /// `entitlements` — read from the Claude CLI's own config on disk, so
        /// it is exactly what the seat is allowed to run.
        /// `live` — the ACP agent announced it, either just now or last session.
        /// `built-in` — the placeholder that stands in before any agent has
        /// ever connected. This one is a guess, and a hint resolved against it
        /// can miss a model the account genuinely offers.
        let catalogue: String
    }

    private struct Grammar: Encodable {
        let mention: String
        let model: String
        /// How to ask for a second agent on one subscription. Its own field
        /// rather than a line in `rules`, because it changes what a caller can
        /// *ask for* rather than how a request is spelled — and the failure
        /// this whole file exists to prevent was an agent concluding that
        /// something possible was impossible.
        let instance: String
        let maxInstances: Int
        let intents: [String]
        let matching: [String]
        let rules: [String]
    }

    private struct Report: Encodable {
        let tool: String
        let summary: String
        let invocation: [String]
        let grammar: Grammar
        let accounts: [AccountReport]
    }

    // MARK: Building it

    private static func grammar() -> Grammar {
        Grammar(
            mention: "@<handle>",
            model: "@<handle>:<model>",
            instance: "@<handle>#<n>",
            maxInstances: Seat.limit,
            intents: ModelPick.intents,
            matching: [
                "exact id — @kimi:kimi-code/k3",
                "any part of the title or id — @kimi:k3, @copilot:haiku, @copilot:g35f",
                "intent — @copilot:free, :cheap, :best, :fast, :auto",
                "reasoning effort, Claude accounts only — @claude-p:max, @claude-w:low",
                "both at once, in either order — @claude-p:opus:max, @claude-p:max:opus",
                "an instance number comes before the colons — @kimi#2:k3",
            ],
            rules: [
                "The first handle named leads: it plans, delegates to the rest, and assembles.",
                "One subscription can run several agents at once, numbered with #: @kimi#1 @kimi#2 @kimi#3. "
                    + "Each is a separate conversation running at the same time, up to \(Seat.limit) per handle.",
                "The bare handle is #1, so @kimi and @kimi#1 are the same agent.",
                "A handle named twice is one agent, not two — the first mention wins, and it carries the model. "
                    + "Number them to get two.",
                "Each instance costs a full share of that subscription. Three Kimis is three times the spend.",
                "A model set with a colon sticks for the rest of the session, until another colon changes it.",
                "For the bare handle it also becomes that account's default for new sessions, so a model chosen "
                    + "once stays chosen; a numbered instance's choice applies to that instance only.",
                "The same grammar works in the `to` field of a delegation: {\"to\": \"kimi:k3\"}, {\"to\": \"kimi#2:k3\"}.",
                "One task per instance per plan. A second task for the same handle *and number* is refused and "
                    + "reported, not queued — number a new instance to run it beside the first.",
                "A plan may number new instances of an agent it was given, but may not bring in a handle nobody named.",
                "With no handle at all, the message goes to whoever led last.",
                "An unresolvable model hint is refused rather than guessed at; the account keeps the model it had.",
                "The model binding is not a file. It is this catalogue plus the colon syntax — do not look for it on disk.",
            ]
        )
    }

    /// Walk every account, then print once.
    ///
    /// Sequential for the same reason `/models` is: the ACP accounts answer
    /// after a wait, and four overlapping waits would resolve in whatever order
    /// they happened to land, which for a machine-readable report means a
    /// different key order every run.
    static func run(_ crew: Crew, then finish: @escaping () -> Void) {
        var queue = Account.enabled
        var reports: [AccountReport] = []

        func next() {
            guard !queue.isEmpty else { emit(reports); finish(); return }
            let account = queue.removeFirst()
            crew.catalogue(for: account) { models, current in
                reports.append(AccountReport(
                    handle: AgentMention.handle(account),
                    account: account.id,
                    title: account.title,
                    mention: "@" + AgentMention.handle(account),
                    current: models.first { $0.id == current }.map(Model.init)
                        ?? models.first.map(Model.init),
                    models: models.map(Model.init),
                    catalogue: provenance(account, models)
                ))
                next()
            }
        }
        next()
    }

    /// Where an account's list came from, asked *after* the catalogue call.
    ///
    /// After, deliberately. `ModelCatalog.remember` stores a list at the moment
    /// a real one lands, so "is there a remembered list" is only a fair test of
    /// liveness once the connection has had its chance. Asked beforehand it
    /// reports `built-in` for every first run on a machine, including the ones
    /// that then connected perfectly well.
    private static func provenance(_ account: Account, _ models: [AgentModel]) -> String {
        guard account.protocolKind.isACP else { return "entitlements" }
        guard !models.isEmpty, ModelCatalog.hasRemembered(for: account) else { return "built-in" }
        return "live"
    }

    private static func emit(_ accounts: [AccountReport]) {
        let report = Report(
            tool: "ai",
            summary: "Runs several AI subscriptions as one crew. Name them in the "
                   + "message with @handles; the first one named leads.",
            invocation: [
                "ai                      interactive",
                "ai -p \"<message>\"       one message, printed, then exit",
                "ai --models [account]   what an account can run, and what it is on",
                "ai --describe           this",
            ],
            grammar: grammar(),
            accounts: accounts
        )

        let encoder = JSONEncoder()
        // Sorted keys so a diff between two runs shows what changed rather than
        // what got reordered, and pretty-printed because a person reads this
        // too — usually the one wondering why their hint didn't resolve.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(report) else {
            Console.failure("could not describe")
            return
        }
        Console.line(String(decoding: data, as: UTF8.self))
    }
}
