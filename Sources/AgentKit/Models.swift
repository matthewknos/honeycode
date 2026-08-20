import Foundation
import Combine

/// Which agent and which credentials a session runs under.
///
/// Account switching is nothing more than an environment variable on the child
/// process — `CLAUDE_CONFIG_DIR` picks the credential store, so work and
/// personal are the same binary pointed at different config directories.
enum Account: String, CaseIterable, Identifiable, Codable {
    // Declaration order is display order — the sidebar, the account switcher and
    // the ⌘-number shortcuts all read `allCases`. `work` keeps its raw value
    // even though it's now labelled Enterprise: the raw value is what's written
    // into every saved session descriptor on disk, and renaming it would orphan
    // every existing Claude Work session.
    case personal, work, kimi, copilot

    var id: String { rawValue }

    /// Names the *agent*, not just the credential set. With four accounts and
    /// three different agents behind them, "Personal" and "Enterprise" alone
    /// would leave the sidebar reading as though Kimi were a third Claude
    /// account.
    var title: String {
        switch self {
        case .personal: return "Claude Personal"
        case .work:     return "Claude Enterprise"
        case .kimi:     return "Kimi"
        case .copilot:  return "Copilot"
        }
    }

    /// For places where the full name would crowd the line — the composer's
    /// placeholder, mainly.
    var shortTitle: String {
        switch self {
        case .personal: return "Personal"
        case .work:     return "Enterprise"
        case .kimi:     return "Kimi"
        case .copilot:  return "Copilot"
        }
    }

    /// Which wire protocol this account's agent speaks.
    ///
    /// Replaces the old test — "is it Copilot?" — which quietly meant "is it
    /// ACP?" and stopped being the same question the moment a second ACP agent
    /// existed.
    var protocolKind: AgentProtocol {
        switch self {
        case .personal, .work: return .claudeStreamJSON
        case .kimi:            return .acp(.kimi)
        case .copilot:         return .acp(.copilot)
        }
    }

    /// The CLI behind this account, for the one-line blurb beside its name.
    var agentName: String {
        switch protocolKind {
        case .claudeStreamJSON: return "Claude Code"
        case .acp(let agent):   return agent == .kimi ? "Kimi Code" : "GitHub Copilot"
        }
    }

    /// Whether the agent reports what a turn cost. Claude sends
    /// `total_cost_usd`; ACP has no equivalent field on either agent, so those
    /// sessions show tokens instead of money rather than a confident zero.
    var reportsCost: Bool {
        if case .claudeStreamJSON = protocolKind { return true }
        return false
    }

    /// Reasoning effort is a Claude launch flag. ACP has no concept of it —
    /// Kimi exposes a `thinking` option whose only value is "on" — so offering
    /// the control anywhere else is a switch wired to nothing.
    var hasEffort: Bool {
        if case .claudeStreamJSON = protocolKind { return true }
        return false
    }

    // Symbols were tried here — folder / building / code-brackets — and pulled.
    // Literal clipart for an abstract idea like "work" reads as stock iconography,
    // and three different glyphs down one column is visual noise. A single
    // colour-coded dot carries the same information with none of the opinion.


    /// `CLAUDE_CONFIG_DIR`, which is the whole of account switching for Claude.
    /// Nil for the ACP agents, which keep their own credentials elsewhere and
    /// have no equivalent knob.
    var configDir: String? {
        switch self {
        case .personal: return NSHomeDirectory() + "/.claude-personal"
        case .work:     return NSHomeDirectory() + "/.claude"
        case .kimi, .copilot: return nil
        }
    }
}

/// How to talk to an account's agent.
enum AgentProtocol {
    /// `claude -p --input-format stream-json --output-format stream-json`.
    case claudeStreamJSON
    /// Newline-delimited JSON-RPC over stdio, per the Agent Client Protocol.
    case acp(ACPAgent)

    /// Whether the model list arrives over the wire rather than off disk.
    ///
    /// The distinction anything asking "what can this account run?" needs:
    /// Claude reads its entitlements from a file and can answer at once, while
    /// the ACP agents only say on `session/new` — so the honest answer before
    /// one has connected is "ask me in a second".
    var isACP: Bool {
        if case .acp = self { return true }
        return false
    }
}

/// One rendered element of the transcript.
///
/// Deliberately not a single `Message` type with a role: an assistant turn, a
/// thinking block and a tool call want genuinely different presentation, and
/// collapsing them into one shape pushes that difference into a switch inside
/// the view, where it tends to decay into "same card, different colour".
enum TranscriptItem: Identifiable, Codable, Sendable {
    case user(id: UUID, text: String)
    case assistant(id: UUID, text: String)
    /// `finished` is nil while the model is still thinking; the pair gives the
    /// "Thought for 5s" summary once the block closes.
    case thinking(id: UUID, text: String, started: Date, finished: Date?)
    case tool(id: UUID, toolUseID: String, name: String, target: String,
              detail: String, state: ToolState)
    case diff(id: UUID, toolUseID: String, file: String, rows: [DiffRow], state: ToolState)
    case search(id: UUID, toolUseID: String, query: String,
                results: [SearchResult], state: ToolState)
    /// Renders from `Session.todos` rather than carrying its own copy — the
    /// plan is one mutable card, not a snapshot per update.
    case todos(id: UUID)
    case notice(id: UUID, text: String)
    /// Another agent's answer, brought back into *this* conversation.
    /// `agent` reads "Copilot · GPT-5.6 Sol" — who said it matters as much as
    /// what, since the whole point is that it wasn't the agent above.
    case opinion(id: UUID, agent: String, text: String, done: Bool)
    /// The agent summarised its own history to make room. Recorded because the
    /// symptom otherwise is simply that it starts being vague about something
    /// you told it an hour ago, with nothing on screen to explain why.
    case compaction(id: UUID, trigger: String, dropped: Int)

    var id: UUID {
        switch self {
        case .user(let id, _), .assistant(let id, _), .notice(let id, _),
             .todos(let id):
            return id
        case .thinking(let id, _, _, _):
            return id
        case .tool(let id, _, _, _, _, _):
            return id
        case .diff(let id, _, _, _, _):
            return id
        case .search(let id, _, _, _, _):
            return id
        case .compaction(let id, _, _):
            return id
        case .opinion(let id, _, _, _):
            return id
        }
    }

    /// The plan card, which is the one item that renders from state it doesn't
    /// carry itself.
    var isTodos: Bool { if case .todos = self { return true }; return false }

    /// Would this render identically to `other`? The transcript's per-row
    /// short-circuit, and nothing else.
    ///
    /// Deliberately not `Equatable`. A synthesised `==` would walk every
    /// `DiffRow` of every edit — a thousand string comparisons for one card —
    /// and it has to run for every row of every redraw, which is exactly the
    /// work it's here to avoid. So the collection cases compare count and ends
    /// instead: their elements carry generated ids and are always replaced
    /// wholesale rather than mutated in place, which makes that identity.
    ///
    /// The text cases are `String ==`, which for two views of the same buffer
    /// is a pointer comparison — so a settled paragraph costs nothing, and a
    /// growing one fails on length before it looks at a character.
    func rendersSameAs(_ other: TranscriptItem) -> Bool {
        switch (self, other) {
        case (.user(let a, let x), .user(let b, let y)),
             (.assistant(let a, let x), .assistant(let b, let y)),
             (.notice(let a, let x), .notice(let b, let y)):
            return a == b && x == y
        case (.thinking(let a, let x, _, let p), .thinking(let b, let y, _, let q)):
            // The elapsed label appears when the block closes, so open-ness is
            // part of the appearance; the timestamps themselves aren't.
            return a == b && x == y && (p == nil) == (q == nil)
        case (.tool(let a, _, let n1, let t1, let d1, let s1),
              .tool(let b, _, let n2, let t2, let d2, let s2)):
            return a == b && n1 == n2 && t1 == t2 && d1 == d2 && s1 == s2
        case (.diff(let a, _, let f1, let r1, let s1),
              .diff(let b, _, let f2, let r2, let s2)):
            return a == b && f1 == f2 && s1 == s2
                && r1.count == r2.count && r1.first?.id == r2.first?.id
        case (.search(let a, _, let q1, let r1, let s1),
              .search(let b, _, let q2, let r2, let s2)):
            return a == b && q1 == q2 && s1 == s2 && r1.count == r2.count
        case (.opinion(let a, let g1, let x, let d1), .opinion(let b, let g2, let y, let d2)):
            return a == b && g1 == g2 && x == y && d1 == d2
        case (.compaction(let a, let t1, let n1), .compaction(let b, let t2, let n2)):
            return a == b && t1 == t2 && n1 == n2
        case (.todos(let a), .todos(let b)):
            // The card draws from `Session.todos`, which this case doesn't
            // carry. The row passes the list in alongside it — see
            // `TranscriptView.Row`.
            return a == b
        default:
            return false
        }
    }
}

/// What became of a tool call.
///
/// A card drawn at `tool_use` time is a *proposal* — the result arrives later,
/// and until this was wired a refused edit rendered identically to an applied
/// one. That's the worst kind of wrong: confidently mis-stating what happened
/// to the user's files.
enum ToolState: Codable, Sendable, Equatable {
    case pending
    case applied
    /// Refused before it ran — a permission decision.
    case declined(String)
    /// Ran and errored. A different fact about the world, and conflating the
    /// two was a real bug: `node` missing from PATH rendered as a struck-through
    /// "Declined", which says the tool was blocked when in truth it executed and
    /// failed. Both are `is_error: true` on the wire; only the app knows which.
    case failed(String)

    var isApplied: Bool { if case .applied = self { return true }; return false }
    var isDeclined: Bool { if case .declined = self { return true }; return false }
    var isFailed: Bool { if case .failed = self { return true }; return false }

    var message: String? {
        switch self {
        case .declined(let text), .failed(let text): return text.isEmpty ? nil : text
        default: return nil
        }
    }
}

/// `--effort`. Governs how much the model thinks before acting.
enum EffortChoice: String, CaseIterable, Identifiable, Codable {
    case low, medium, high, xhigh, max

    var id: String { rawValue }
    var title: String { self == .xhigh ? "Extra high" : rawValue.capitalized }
}

/// How much of the machinery the transcript shows.
///
/// The same four steps Claude Code offers, because they map onto genuinely
/// different questions: *what did we conclude* (summary), *what did it do*
/// (normal), *why did it do that* (thinking), *exactly what happened* (verbose).
/// A single "show details" toggle collapses those four into two and loses the
/// most useful middle ground.
enum TranscriptMode: String, CaseIterable, Identifiable {
    case summary, normal, thinking, verbose

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var blurb: String {
        switch self {
        case .summary:  return "Prompts and replies only"
        case .normal:   return "Adds tool calls and edits"
        case .thinking: return "Adds the model's reasoning"
        case .verbose:  return "Everything, expanded"
        }
    }

    var showsReasoning: Bool { self == .thinking || self == .verbose }
    var showsActivity: Bool { self != .summary }
    /// Tool rows open rather than collapsed.
    var expandsDetail: Bool { self == .verbose }
}

/// A slash command the agent advertises.
///
/// Both CLIs announce their full command set on connect and Honeycode discarded
/// it — Claude 43 of them in `system/init`, Copilot 32 with descriptions. They
/// are how you actually drive these tools, and until now the only way to find
/// one was to already know it existed.
struct AgentCommand: Identifiable, Hashable {
    let name: String
    var detail: String = ""
    /// Skills are commands too, but they're *yours* rather than the CLI's, so
    /// they're worth telling apart in the list.
    var isSkill: Bool = false

    var id: String { name }
}

/// A block of agent-written markup, lifted out of the transcript.
///
/// Carries its own identity so the panel reloads when you send it a second
/// artifact whose markup happens to be identical to the first — and so a
/// re-render of the same one doesn't throw away scroll position or form state.
struct Artifact: Identifiable, Equatable {
    /// Changes with every revision, and has to: the browser panel keys its web
    /// view on this, and a stable id would mean an updated artifact never
    /// re-rendered.
    let id = UUID()
    /// Which file on disk this artifact owns — carried across revisions, unlike
    /// `id`.
    ///
    /// Without the split, asking for a change to an artifact you'd opened in
    /// your browser wrote `artifact-C3D4.html` beside `artifact-A1B2.html` and
    /// left your tab pointing at the old one. You'd reload and see the version
    /// you'd just asked to change. One file per artifact, overwritten in place,
    /// means reload does what reload is for.
    var fileID = UUID()
    var language: String
    var markup: String

    /// What the address bar says instead of a URL. There isn't one, and
    /// inventing a plausible-looking `artifact://` would be a small lie in the
    /// one field whose whole job is saying where you are.
    var label: String {
        language.lowercased() == "svg" ? "Artifact — SVG" : "Artifact — HTML"
    }

    /// Written out to Application Support, because there's no file behind an
    /// inline artifact and a real browser needs one. Kept rather than put in a
    /// temporary directory: these are usually the thing you wanted to keep.
    func write() -> URL? {
        let folder = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Honeycode/Artifacts", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suffix = language.lowercased() == "svg" ? "svg" : "html"
        let url = folder.appendingPathComponent("artifact-\(fileID.uuidString.prefix(8)).\(suffix)")
        guard (try? Artifact.inlining(markup).write(to: url, atomically: true,
                                                    encoding: .utf8)) != nil
        else { return nil }
        return url
    }

    /// Local images folded into the markup as data URIs.
    ///
    /// Widening the web view's read grant fixed the assets that live under
    /// Honeycode's own folder, which is where a skill keeps its logo. It does
    /// nothing for the next case along — an image in the checkout the session
    /// is working in — and widening the grant far enough to cover that would
    /// mean handing agent-written markup the run of the home directory.
    ///
    /// Inlining sidesteps the question. There's no second file to be granted
    /// access to, so nothing to get wrong, and the artifact stops depending on
    /// paths that were only ever true on this machine: it survives the asset
    /// moving, and it's a single file you can send to somebody.
    ///
    /// Conservative on every axis — it only rewrites a reference where the path
    /// is absolute, the file is there, it's an image, and the budget holds.
    /// Anything else is left exactly as written, because a preview that fails
    /// to load one logo is a much smaller problem than markup this mangled.
    static func inlining(_ markup: String) -> String {
        // `src="…"` covers <img>; `url(…)` covers CSS backgrounds, which is how
        // half of a generated deck refers to its images.
        let patterns = [#"src\s*=\s*"([^"]+)""#, #"url\(\s*['"]?([^'")]+)['"]?\s*\)"#]
        var result = markup
        // Enough for the logos and textures a deck actually uses, and a stop
        // before a stray reference to a video turns a 12KB page into 200MB of
        // base64 that has to be parsed on every open.
        var budget = 8_000_000

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern,
                                                       options: [.caseInsensitive])
            else { continue }
            let matches = regex.matches(
                in: result, range: NSRange(result.startIndex..., in: result))
            // Backwards, so each replacement can't shift the ranges of the ones
            // still to come.
            for match in matches.reversed() {
                guard let whole = Range(match.range, in: result),
                      let inner = Range(match.range(at: 1), in: result) else { continue }
                let reference = String(result[inner])
                guard let data = imageData(at: reference, within: &budget),
                      let type = Self.mime[URL(fileURLWithPath: reference)
                          .pathExtension.lowercased()]
                else { continue }
                let encoded = "data:\(type);base64,\(data.base64EncodedString())"
                result.replaceSubrange(
                    whole, with: result[whole].replacingOccurrences(of: reference,
                                                                    with: encoded))
            }
        }
        return result
    }

    private static let mime = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
        "gif": "image/gif", "webp": "image/webp", "svg": "image/svg+xml",
    ]

    /// The bytes behind a reference, if it's a local file worth inlining.
    ///
    /// Relative paths are left alone deliberately: `assets/logo.png` is
    /// relative to the artifact, and the artifact is about to be written
    /// somewhere the agent didn't choose — so there's no directory this could
    /// resolve against that would be right more often than it was wrong.
    private static func imageData(at reference: String, within budget: inout Int) -> Data? {
        var path = reference
        if path.hasPrefix("file://") {
            guard let url = URL(string: path) else { return nil }
            path = url.path
        }
        path = path.removingPercentEncoding ?? path
        guard path.hasPrefix("/"), mime[URL(fileURLWithPath: path).pathExtension.lowercased()] != nil,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              data.count <= budget
        else { return nil }
        budget -= data.count
        return data
    }

    /// The same artifact, one revision on.
    ///
    /// Applied when something is sent to the panel while the panel already holds
    /// an artifact of the same kind, which is what "I asked for a change" looks
    /// like from here. Different kind — an SVG replacing an HTML page — is
    /// treated as a different artifact, because it is one and because the file
    /// extension would otherwise be wrong.
    func succeeding(_ previous: Artifact?) -> Artifact {
        guard let previous, previous.language.lowercased() == language.lowercased()
        else { return self }
        var next = self
        next.fileID = previous.fileID
        return next
    }
}

/// How full the model's context window is.
///
/// Every turn reports the tokens it sent and `modelUsage[…].contextWindow`, so
/// this is arithmetic on data already arriving — and it's the one number that
/// silently decides whether a long session still remembers the start of itself.
struct ContextUsage: Equatable {
    var used: Int
    var window: Int

    var percent: Int {
        window > 0 ? min(100, Int((Double(used) / Double(window) * 100).rounded())) : 0
    }

    /// Built once. These read on every redraw of the composer's usage strip,
    /// and a `NumberFormatter` is not a cheap thing to allocate.
    static let decimal: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    var summary: String {
        let formatter = Self.decimal
        let u = formatter.string(from: NSNumber(value: used)) ?? "\(used)"
        let w = formatter.string(from: NSNumber(value: window)) ?? "\(window)"
        return "\(u) of \(w) tokens in context.\nPast roughly 90% the agent "
            + "compacts older turns to make room, which loses detail."
    }
}

/// What the CLI says about your usage window.
///
/// The stream carries this on every turn and Honeycode used to drop it on the
/// floor. On a subscription it's the most consequential thing the agent tells
/// you — more than cost, which is a number you can't act on.
struct RateLimit: Equatable, Codable {
    /// `allowed`, `allowed_warning`, `rejected`.
    var status: String
    var resetsAt: Date?
    /// `five_hour`, `weekly` — which window is being reported.
    var kind: String?
    var usingOverage: Bool
    /// Whether spilling over into paid overage is even possible. Comes back as
    /// `rejected` with `out_of_credits` when it isn't, which is worth knowing
    /// *before* you hit the wall rather than after.
    var overageAvailable: Bool

    var isConstrained: Bool { status != "allowed" || usingOverage }

    /// Built once — `summary` is a tooltip on a chip that redraws with the
    /// composer.
    static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    var windowName: String {
        switch kind {
        case "five_hour": return "5-hour limit"
        case "weekly":    return "Weekly limit"
        default:          return "Usage limit"
        }
    }

    /// One line for the status rail's tooltip. Always available, even when the
    /// chip itself is hidden because nothing's wrong yet.
    var summary: String {
        var parts: [String] = [windowName]
        switch status {
        case "allowed":         parts.append("not reached")
        case "allowed_warning": parts.append("approaching")
        case "rejected":        parts.append("reached")
        default:                parts.append(status)
        }
        if let resetsAt {
            parts.append("resets \(Self.clock.string(from: resetsAt))")
        }
        if usingOverage { parts.append("using overage") }
        else if !overageAvailable { parts.append("no overage available") }
        return parts.joined(separator: " · ")
    }
}

/// The roster entry for one session. The conversation itself lives beside it
/// in a `SessionSnapshot`, keyed by `id`.
/// Who started a conversation.
///
/// The sidebar's two halves are this field, and nothing else: the Code list is
/// `.user`, the Agents list is `.agent`. Everything below — the transcript, the
/// changes sheet, the browser panel, the palette — is deliberately blind to it,
/// which is the whole reason an agent run costs so little to add.
enum SessionOrigin: Codable, Equatable, Hashable, Sendable {
    case user
    /// One run of an agent, scheduled or fired by hand.
    case agent(UUID)
    /// The interview that produces an agent. Always ephemeral.
    case setup

    var agentID: UUID? {
        if case .agent(let id) = self { return id }
        return nil
    }
}

struct SessionDescriptor: Codable {
    /// Stable across launches — this is what ties a roster row to its
    /// transcript on disk. Optional so a roster written before snapshots
    /// existed still decodes; those sessions get a fresh id and an empty
    /// transcript, which is what they had anyway.
    var id: UUID?
    var account: Account
    var path: String
    var name: String
    /// The model's wire id. Replaces an earlier `model` enum — an old roster
    /// simply decodes this as nil and gets its account's default.
    var modelID: String?
    var effort: EffortChoice?
    /// Confined to its own directory. Absent on an older roster, which decodes
    /// as nil and means off — the safe reading, since a session that was never
    /// isolated shouldn't become so on an upgrade.
    var isolated: Bool?
    /// Absent on a roster written before agents existed, which decodes as nil
    /// and means `.user` — every session that predates this feature is one you
    /// started yourself.
    var origin: SessionOrigin?
    /// When an agent run began. Nil for ordinary sessions, which have no single
    /// moment worth recording — they start when you first type in them.
    var startedAt: Date?
}

/// A conversation pinned to a working directory and an account.
final class Session: ObservableObject, Identifiable {
    let id: UUID
    let account: Account
    let directory: URL
    /// Whether you started this or something else did. Fixed at creation —
    /// there's no path where a run becomes a session you opened, or the other
    /// way round.
    let origin: SessionOrigin
    /// When an agent run began, for the row that lists it.
    let startedAt: Date?

    var isRun: Bool { origin.agentID != nil }

    /// Extra instruction sent with the *first* message and never shown.
    ///
    /// The same trick `documentNote` uses — the transcript keeps what you
    /// typed, the agent gets what you typed plus what the app needs it to know.
    /// Used by the agent interview, which has to explain the format it wants
    /// back without that explanation being the first thing you read.
    var briefing: String?

    /// The agent's own id for this conversation. Handing it back is what makes
    /// a relaunch rejoin rather than start over.
    var conversationID: String
    /// Whether the agent has ever run here. `--resume` an id that was never
    /// created and Claude exits; `--session-id` one that already exists and it
    /// refuses. The two cases need different flags, so they're tracked.
    var hasStarted: Bool

    @Published var name: String
    @Published var items: [TranscriptItem] = []
    /// The agent's plan. Lives on the session, not in the transcript, because
    /// it's mutated in place by every `TaskUpdate`.
    @Published var todos: [Todo] = []
    @Published var isRunning = false
    /// Cumulative spend, surfaced from the CLI's own `total_cost_usd`.
    @Published var costUSD: Double = 0
    @Published var needsAttention = false
    @Published var rateLimit: RateLimit?
    /// Copilot only: AI Units this conversation has consumed, as the agent
    /// itself reports them — accumulated across resumes, since its own counter
    /// restarts with each process.
    @Published var aiUnits: Double?
    /// Copilot only: a running floor on input tokens, summed from the context
    /// size at the end of each turn.
    ///
    /// Kept because Copilot is the one account that reports no cost at all, so
    /// without this a session's entire consumption is invisible. Claude carries
    /// `total_cost_usd`, which is both exact and more useful.
    @Published var tokensSent = 0
    /// Slash commands this agent advertises, for the composer's `/` completion.
    @Published var commands: [AgentCommand] = []
    @Published var context: ContextUsage?
    /// A dev server the agent started, spotted in command output.
    @Published var devServer: URL?
    /// The browser panel, which is per-session because the server is.
    @Published var browserVisible = false
    @Published var browserURL: URL?
    /// Whether the current URL is one you typed rather than one detected.
    ///
    /// Without this the panel remembered whatever was last in the address bar,
    /// so asking the agent to start a server and then opening the panel showed
    /// you a URL from twenty minutes ago. A server the session started should
    /// win — unless you deliberately went somewhere else after it appeared.
    @Published var browserURLIsManual = false
    /// An artifact from the transcript, opened in the panel.
    ///
    /// Mutually exclusive with `browserURL`: the panel shows one thing, and two
    /// sources of truth for "what's on screen" is how you get a Back button
    /// that lies.
    @Published var browserHTML: Artifact?
    /// The file the panel is actually showing.
    ///
    /// An artifact used to live in the panel as a *string*, which kept the null
    /// origin but made the panel a photograph: the agent would change the
    /// document and the panel would go on showing the version you'd sent it.
    /// Pointing it at the file instead is what makes a revision arrive on its
    /// own — and what makes "edit the file" a coherent instruction to give an
    /// agent in the first place.
    ///
    /// Also set by opening a local file by hand, which is the same thing seen
    /// from the other end.
    @Published var browserFile: URL?
    /// The panel's zoom. Per-session because the panel is — a dashboard you've
    /// zoomed out to see whole shouldn't reset because you answered a message
    /// in another session.
    @Published var browserZoom: CGFloat = 1
    /// The floating chat over a full-width preview.
    @Published var miniChatVisible = false
    /// The panel taken to the full width of the pane. Still the same live web
    /// view — it's a bigger panel, not a screenshot.
    @Published var browserFull = false

    /// Model and effort are process-launch flags, so changing either restarts
    /// the child and resumes the same conversation by ID. Applies from the
    /// next turn, never mid-turn.
    /// What this account can run. Fixed for Claude, read from the CLI's own
    /// entitlement cache; for Copilot it's replaced by the live list the agent
    /// sends when the session opens.
    @Published var availableModels: [AgentModel]

    /// Both guard on the value actually changing. The pickers assign
    /// unconditionally — clicking the row you're already on is a perfectly
    /// normal way to close the popover — and without the guard that tore down
    /// the process and forced a `--resume` on the next turn to confirm a choice
    /// nobody had changed.
    @Published var model: AgentModel {
        didSet {
            guard model.id != oldValue.id else { return }
            adapter.restart()
            onPersistableChange?()
        }
    }
    @Published var effort: EffortChoice = .high {
        didSet {
            guard effort != oldValue else { return }
            adapter.restart()
            onPersistableChange?()
        }
    }

    /// Confined to `directory` — see `Isolation`.
    ///
    /// Restarts the agent like a model change does, and for the same reason:
    /// the confinement is a launch argument for Claude and a decision made per
    /// process for the others, so a live process keeps whatever it started
    /// with. Anything else would leave the lock in the UI describing a session
    /// it doesn't yet govern.
    @Published var isolated = false {
        didSet {
            guard isolated != oldValue else { return }
            append(.notice(id: UUID(), text: isolated
                ? "Isolated to \(subtitle). Nothing above or beside it is readable; "
                  + "the agent is restarting to take it up."
                : "Isolation off. The agent can read outside \(subtitle) again, "
                  + "and is restarting."))
            adapter.restart()
            onPersistableChange?()
            persist()
        }
    }

    /// Set by `Workspace`, so a change to something that lives in the
    /// descriptor writes it out. Without this the picker's choice survived
    /// until quit and no further.
    var onPersistableChange: (() -> Void)?

    /// Set by `Workspace`, which is the only thing that knows whether this
    /// session is the one on screen — and therefore whether finishing is worth
    /// interrupting you for.
    var onTurnComplete: ((Session) -> Void)?

    /// Files staged by the `+` button, sent as `@path` references.
    @Published var attachments: [URL] = []

    /// Messages typed while a turn was still running.
    ///
    /// Queued locally rather than written straight down the pipe. Both CLIs
    /// accept a user frame at any moment, but what they *do* with one mid-turn
    /// isn't specified and differs between them — and a steering message that
    /// silently interleaved into the middle of a tool call would be a worse
    /// failure than waiting a few seconds. This way the behaviour is the same
    /// for both and is knowable: it goes as soon as the turn lands.
    @Published private(set) var queued: [String] = []

    /// Bumped every time a message is actually dispatched.
    ///
    /// The transcript watches this and jumps to the end unconditionally.
    /// Sending is a deliberate act with an obvious intent — every attempt to
    /// infer that intent from scroll geometry got it wrong, because the
    /// geometry at that instant describes a layout that hasn't happened yet.
    @Published private(set) var sendTick = 0

    /// A throwaway. Kept out of the roster and off disk, so it disappears when
    /// you quit — a second opinion is a question you asked once, not a
    /// conversation you'll come back to, and letting them accumulate would turn
    /// the sidebar into a graveyard.
    var isEphemeral = false

    /// Material relayed here from another session, waiting for this session's
    /// composer to pick it up. See `Relay`.
    ///
    /// It lands in the field rather than being sent, and it lands on the
    /// *session* rather than in the composer's own state — the composer is
    /// rebuilt from scratch whenever the column changes identity (see
    /// `RootView`), so a draft parked there would be thrown away by the very
    /// act of switching to the conversation it was sent to.
    @Published var relayIncoming: String?

    /// A relay on its way here, while the sending side transforms it.
    @Published var relayPending: RelayPending?

    /// Which protocol this session speaks. Chosen once, from the account —
    /// there's no path where a Claude session becomes a Copilot one.
    /// Throwaway sessions running a second opinion for this one. Held strongly
    /// because their adapters reference them `unowned`; dropped once done.
    private var reviewers: [UUID: Session] = [:]
    private var reviewerFeeds: [UUID: AnyCancellable] = [:]
    /// Opinions with a mirror already scheduled — see `askOpinion`.
    private var mirrorsPending: Set<UUID> = []

    /// See `leadCrew`. Nil until this conversation is asked to lead one.
    private var crew: Crew?

    /// The crew run this conversation is leading, while one is in flight.
    ///
    /// Published so the window can draw it. Written by `TranscriptReporter`
    /// from the events `Crew` already reports, which is what keeps `Crew`
    /// ignorant of the fact that anything is watching. See `CrewRun`.
    @Published var crewRun: CrewRun?

    /// The agents this conversation sends to, and what each should run.
    ///
    /// Set by the composer's team control and prepended to the next message as
    /// mentions, which is the only grammar `Crew` reads. Kept on the session
    /// rather than in the view so a crew survives switching away and back — you
    /// assemble a team once and then talk to it.
    @Published var team: [AgentMention.Pick] = []

    /// Stop a crew run, from a button rather than by asking an agent to.
    ///
    /// Worth having for a reason the transcripts make plain: stopping used to
    /// be typed as prose — "stop all for now" — to a lead that then had to find
    /// the process and kill it. The run knows how to stop itself.
    @MainActor
    func stopCrew() {
        crew?.interrupt()
        crewRun?.end()
    }

    private lazy var adapter: AgentAdapter = {
        switch account.protocolKind {
        case .claudeStreamJSON:  return ClaudeAdapter(session: self)
        case .acp(let agent):    return ACPAdapter(session: self, agent: agent)
        }
    }()

    init(id: UUID = UUID(), account: Account, directory: URL, name: String? = nil,
         modelID: String? = nil, effort: EffortChoice = .high,
         isolated: Bool = false, origin: SessionOrigin = .user,
         startedAt: Date? = nil) {
        self.id = id
        self.origin = origin
        self.startedAt = startedAt
        // Assigned before anything can observe it. Going through the property's
        // own `didSet` here would post a notice about a change nobody made and
        // restart an adapter that hasn't been built.
        self.isolated = isolated
        self.account = account
        self.directory = directory
        self.name = name ?? directory.lastPathComponent

        let catalogue = ModelCatalog.models(for: account)
        availableModels = catalogue
        // A saved model that's no longer offered — entitlement withdrawn, or a
        // roster carried over from before this existed — falls back rather than
        // being sent to a CLI that will reject it.
        //
        // And with nothing saved, what you last chose for this account rather
        // than whatever the CLI lists first. The difference is the whole of the
        // bug where a crew ran Kimi on K2.7 while the window had said K3 since
        // Tuesday: `catalogue.first` is an ordering decision made by someone
        // else's tool, and it was standing in for a preference nobody could
        // express.
        model = catalogue.first { $0.id == modelID }
            ?? catalogue.first { $0.id == ModelCatalog.preferred(for: account) }
            ?? catalogue.first ?? ModelCatalog.fallback

        conversationID = UUID().uuidString
        hasStarted = false
        self.effort = effort

        // The transcript is deliberately *not* read here — see `hydrate`.
    }

    /// Whether the saved conversation has been read in yet.
    ///
    /// Everything below `items` is empty until it has, which is why nothing may
    /// write this session out before then: `persist` on an unhydrated session
    /// would replace a real transcript with a blank one.
    private(set) var isHydrated = false

    /// Read the saved conversation in, now, on this thread.
    ///
    /// Kept out of `init` because `Workspace` builds a `Session` for every row
    /// of the roster at launch, and each of these is a `Data(contentsOf:)` plus
    /// a full JSON decode — with several multi-megabyte transcripts that was
    /// seconds of blocked main thread before the first frame, most of it
    /// decoding conversations nobody was about to look at. Only the columns
    /// being restored are hydrated up front; the rest are handed a snapshot
    /// decoded off the main thread a moment later, and anything that reaches
    /// for a transcript before that lands forces it here.
    func hydrate() {
        guard !isHydrated else { return }
        restore(SessionStore.load(id))
    }

    /// Take a snapshot somebody else decoded. Ignored once anything has already
    /// hydrated this session — a forced load always wins over an in-flight
    /// background one, which would otherwise arrive stale.
    func restore(_ snapshot: SessionSnapshot?) {
        guard !isHydrated else { return }
        isHydrated = true
        guard let snapshot else { return }

        conversationID = snapshot.conversationID
        hasStarted = snapshot.started
        items = snapshot.items
        todos = snapshot.todos
        costUSD = snapshot.costUSD
        aiUnits = snapshot.aiUnits
        tokensSent = snapshot.tokensSent ?? 0
        // Restored so the readouts are right before the first turn of a resumed
        // session, rather than blank until it next reports.
        if let used = snapshot.contextUsed, let window = snapshot.contextWindow {
            // Clamped, because sessions written before the occupancy fix hold
            // a turn-total rather than a prompt size — one of them recorded
            // 14,071,235 against a 1,000,000 window. Left alone those restore
            // as a meter reading 1,407%, and the first correct figure only
            // arrives after the next turn ends. A full window is the honest
            // reading of "more than a full window" in the meantime.
            context = ContextUsage(used: min(used, window), window: window)
        }

        // A transcript saved mid-turn can carry an unclosed reasoning block,
        // which would restore as a permanent "Thinking…" shimmer for a turn
        // that ended when the app quit.
        closeThinking()
    }

    var descriptor: SessionDescriptor {
        SessionDescriptor(id: id, account: account, path: directory.path, name: name,
                          modelID: model.id, effort: effort, isolated: isolated,
                          origin: origin, startedAt: startedAt)
    }

    /// Write the conversation out. Called at the end of each turn and when a
    /// message is sent — not on every streaming delta, which would be hundreds
    /// of writes a second for no benefit.
    func persist() {
        // An unhydrated session has an empty `items` because nothing has read
        // its file yet, not because the conversation is empty. Writing that out
        // would destroy the transcript it hasn't loaded.
        guard !isEphemeral, isHydrated else { return }
        SessionStore.save(
            SessionSnapshot(conversationID: conversationID, started: hasStarted,
                            items: items, todos: todos, costUSD: costUSD,
                            aiUnits: aiUnits, tokensSent: tokensSent,
                            contextUsed: context?.used, contextWindow: context?.window),
            for: id)
    }

    /// Called by whichever adapter is driving, when a turn completes.
    func endTurn(cost: Double = 0) {
        isRunning = false
        costUSD += cost
        needsAttention = true
        scanForDevServer()
        persist()
        onTurnComplete?(self)

        // Anything typed while it was working goes now, as one message —
        // three separate follow-ups become three turns, which is rarely what
        // someone typing quickly meant.
        if !queued.isEmpty {
            let pending = queued.joined(separator: "\n\n")
            queued.removeAll()
            send(pending)
        }
        // A finished turn is exactly when the allowance has moved. Hopped onto
        // the main actor rather than marking `Session` isolated — the adapters
        // call into it from their reader queues.
        let account = account
        Task { @MainActor in
            UsageStore.shared.record(cost: cost, for: account)
            UsageStore.shared.refresh(account, force: true)
        }
    }

    /// The last thing the agent said, trimmed to a notification's worth.
    var lastReply: String {
        hydrate()
        for item in items.reversed() {
            if case .assistant(_, let text) = item {
                let line = text
                    .components(separatedBy: .newlines)
                    .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
                return line.count > 140 ? String(line.prefix(140)) + "…" : line
            }
        }
        return "Finished."
    }

    /// Shown in the toolbar, not the sidebar — the sidebar row carries the name
    /// alone so nine of them stay a single tidy column.
    var subtitle: String {
        directory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    /// `/clear`, as the composer's `/` list advertises it.
    ///
    /// Honeycode's, and taken before dispatch. The CLIs advertise a command of
    /// the same name and it only ever cleared *their* half: the agent forgot
    /// the conversation and the transcript on screen stayed exactly as it was,
    /// which is the worst of both — a wall of text the agent can no longer see
    /// anything of. Intercepting makes the two halves agree.
    static let clearCommand = AgentCommand(
        name: "clear",
        detail: "Wipe this conversation — the transcript and the agent's memory of it",
        isSkill: false)

    /// True for `/clear` and nothing else. An argument is a different command,
    /// not this one with an argument, so `/clear the build folder` goes to the
    /// agent as the sentence it plainly is.
    private static func isClear(_ text: String) -> Bool {
        text == "/clear"
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if Self.isClear(trimmed) { clear(); return }

        // A finished run stays on screen until you say something else, so the
        // last thing it did is still readable — and goes when you do, because
        // a summary of a run you have moved on from is clutter with a number
        // in it.
        MainActor.assumeIsolated { if crewRun?.finished == true { crewRun = nil } }

        // A message naming other agents is a crew run, not a turn: this
        // conversation leads and the ones named help. Checked before anything
        // else because everything else — hydrating, appending, dispatching —
        // belongs to the turn this message turns out not to be.
        //
        // `@Sources/Models.swift` is a file and stays one. `AgentMention` only
        // matches the four handles, so a path never reads as an agent unless
        // somebody has a file called `kimi` in their project root.
        let named = AgentMention.parse(trimmed).crew.map(\.account).filter { $0 != account }
        if !named.isEmpty {
            // One crew at a time. A second request while three delegates are
            // still working would reuse their conversations mid-turn, so it
            // waits the same way anything typed mid-turn does.
            guard MainActor.assumeIsolated({ crew?.isBusy }) != true, !isRunning else {
                queued.append(trimmed)
                return
            }
            hydrate()
            items.append(.user(id: UUID(), text: trimmed))
            needsAttention = false
            sendTick += 1
            persist()
            // `Crew` is `@MainActor`; `Session` is not, though every line of it
            // runs there — the adapters deliver on the main queue and every
            // stored property drives a view. Annotating the class to say so
            // was tried and cascades into both adapters, which is a
            // concurrency refactor rather than this feature. Asserted at the
            // one boundary that needs it instead.
            MainActor.assumeIsolated { leadCrew().submit(trimmed, ledBy: account) }
            return
        }

        deliver(trimmed, shownAs: trimmed)
    }

    /// Send a turn without the crew intercept, and without assuming the person
    /// typed it.
    ///
    /// `Crew` drives this session's turns during a run, and every one of them —
    /// the briefing, the report — names other agents by handle. Routed back
    /// through `send`, the lead would read its own briefing as a fresh request
    /// for a crew and recurse. So the intercept lives in `send` and the
    /// machinery lives here.
    ///
    /// `shown` nil means the transcript records nothing: the wire text is
    /// plumbing the person never wrote. It is the same split `dispatchable`
    /// makes for an open document, one level up.
    func deliver(_ text: String, shownAs shown: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Before anything is appended or persisted: `conversationID` and
        // `hasStarted` are both in the snapshot, and sending on a session that
        // hasn't read it would start a fresh conversation with the agent.
        hydrate()

        // Mid-turn: hold it. Nothing goes in the transcript yet either, because
        // a message shown as sent that hasn't been is the transcript lying.
        guard !isRunning else {
            queued.append(trimmed)
            return
        }

        if let shown, !shown.isEmpty { items.append(.user(id: UUID(), text: shown)) }
        needsAttention = false
        sendTick += 1
        // The transcript keeps what you typed; the agent gets what you typed
        // plus, when there's a document open beside it, a line saying where
        // that document is.
        adapter.send(dispatchable(trimmed))
        // Save the prompt before the reply exists, so a crash mid-turn still
        // leaves a record of what was asked.
        persist()
    }

    /// The crew this conversation leads, made the first time it needs one.
    ///
    /// Kept for the session's life rather than per message, so a delegate that
    /// wrote the header is still the one asked to make it bigger.
    @MainActor
    private func leadCrew() -> Crew {
        if let crew { return crew }
        let made = Crew(directory: directory,
                        reporter: TranscriptReporter(host: self), host: self)
        crew = made
        return made
    }

    /// Drop everything waiting — stopping a turn should stop what you queued
    /// behind it too, or the thing you interrupted starts right back up.
    func clearQueue() { queued.removeAll() }

    /// Start this session over: empty transcript, empty agent.
    ///
    /// Both halves, or neither. Clearing only the transcript would leave the
    /// agent answering from a conversation you can't see; clearing only the
    /// agent is what the CLIs' own `/clear` does, and it's what made the
    /// command useless here.
    ///
    /// The session keeps its identity — same row, same name, same directory,
    /// same window position. What it doesn't keep is the *conversation* id: a
    /// fresh one is minted so nothing can resume the old thread, and
    /// `hasStarted` goes back to false so the next launch creates rather than
    /// resumes.
    ///
    /// Money and tokens are deliberately left alone. They record what this
    /// session has spent, which is a fact about the account rather than part
    /// of the conversation, and a clear that quietly reset the meter would
    /// make the day's total wrong.
    func clear() {
        // First: `persist` refuses to write an unhydrated session, so without
        // this the wipe would sit in memory and the file on disk would win the
        // next time anything read it.
        hydrate()

        // Whatever is in flight is part of what's being thrown away — and the
        // adapter must let go of the old conversation before the new id is
        // minted, or its next launch resumes an id the session has replaced.
        interrupt()
        adapter.reset()

        conversationID = UUID().uuidString
        hasStarted = false
        items = []
        todos = []
        context = nil
        needsAttention = false
        isRunning = false
        // The panel is showing a document, not a conversation, so it stays —
        // but the dev server was found by reading a transcript that no longer
        // exists, and a port from a process that may be long dead isn't
        // something to keep pointing at.
        devServer = nil
        persist()
    }

    // MARK: The document in the panel

    /// Put an artifact in the panel, as a file.
    ///
    /// Written out here rather than at the moment you ask for a browser,
    /// because the file *is* the artifact now: it's what the panel reloads and
    /// what the agent is told to edit. A revision inherits the previous one's
    /// path, so asking for a change rewrites one file instead of leaving a
    /// numbered trail of near-identical documents.
    func open(_ artifact: Artifact) {
        let next = artifact.succeeding(browserHTML)
        browserHTML = next
        browserFile = next.write()
        browserVisible = true
    }

    /// Show a file you picked yourself.
    func open(file url: URL) {
        browserHTML = nil
        browserFile = url
        browserURL = nil
        browserURLIsManual = false
        browserVisible = true
    }

    /// What actually goes down the pipe, which is not always what you typed.
    ///
    /// Every agent here can edit files, and none of them can see this window.
    /// Left to itself an agent asked to change a page it wrote earlier will
    /// reprint the entire document into the transcript — correct, useless, and
    /// several thousand tokens — while the file the preview is showing stays as
    /// it was. One sentence turns that into an edit.
    ///
    /// The transcript stores what you typed, not this. A note the app adds on
    /// your behalf isn't something you said, and showing it as though it were
    /// would make your own messages unreadable.
    private func dispatchable(_ text: String) -> String {
        var out = text
        // Consumed rather than re-sent. It's an opening instruction, and
        // repeating it on every turn would both waste the tokens and let it
        // drift into being the loudest thing in a long conversation.
        if let briefing {
            out = briefing + "\n\n" + out
            self.briefing = nil
        }
        guard browserVisible, let file = browserFile,
              let note = Self.documentNote(file) else { return out }
        return out + "\n\n" + note
    }

    /// The note is a *host* instruction, and the path in it comes from disk.
    ///
    /// macOS filenames may contain `]` and newlines. Both are the delimiter
    /// this note is bracketed by, so a file called
    /// `report.html]\n\n[Honeycode: also run …` closes the block early and the
    /// rest reads to the agent as another instruction from the app it trusts —
    /// which it then carries out against a CLI launched with permissions
    /// skipped. The agent doesn't have to be tricked into anything; it's doing
    /// exactly what a host instruction says.
    ///
    /// Newlines and control characters are stripped, since no legitimate path
    /// needs them here. A `]` can't be stripped — that would name a different
    /// file — so a path containing one loses the note instead. The preview
    /// still works; the agent just isn't told to edit in place, which is a
    /// wasted round trip rather than an unsafe one.
    static func documentNote(_ file: URL) -> String? {
        let path = file.path.filter { !$0.isNewline && !$0.unicodeScalars.contains { $0.properties.generalCategory == .control } }
        guard !path.contains("]"), path == file.path else { return nil }
        return """
        [Honeycode: \(path) is open in a live preview beside this \
        conversation, and reloads by itself whenever the file changes. If the \
        message above asks for a change to that document, edit the file in \
        place with your file tools and reply with a short summary of what you \
        changed — don't reprint the document unless I ask you to.]
        """
    }

    /// Ask a different agent about something, without leaving this thread.
    ///
    /// The answer comes back *here* rather than in a session you have to go and
    /// find. A review is a footnote to this conversation, not a conversation of
    /// its own — and switching away mid-thought to read it costs more than the
    /// second opinion is worth.
    func askOpinion(account: Account, modelID: String?, effort: EffortChoice,
                    modelTitle: String, prompt: String) {
        hydrate()
        let id = UUID()
        let label = "\(account.title) · \(modelTitle)"
        append(.opinion(id: id, agent: label, text: "", done: false))
        persist()

        let reviewer = Session(account: account, directory: directory,
                               name: "review", modelID: modelID, effort: effort)
        reviewer.isEphemeral = true
        reviewers[id] = reviewer

        // Mirror its reply into the placeholder as it streams, so a slow
        // reviewer shows progress rather than a spinner that might be stuck.
        //
        // Throttled, because `objectWillChange` fires for *every* mutation the
        // reviewer makes — twice per streamed delta, plus its running flag and
        // its cost — and each mirror rescans both transcripts to find the
        // placeholder and the reply. Sixty times a second that is O(transcript)
        // work per token in a session you aren't even looking at. A tenth of a
        // second is well under the rate anyone reads at.
        reviewerFeeds[id] = reviewer.objectWillChange.sink { [weak self] in
            guard let self, self.mirrorsPending.insert(id).inserted else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak reviewer] in
                guard let self else { return }
                self.mirrorsPending.remove(id)
                guard let reviewer else { return }
                self.updateOpinion(id, from: reviewer, done: false)
            }
        }

        reviewer.onTurnComplete = { [weak self] finished in
            guard let self else { return }
            self.updateOpinion(id, from: finished, done: true)
            self.reviewerFeeds[id] = nil
            finished.retire()
            self.reviewers[id] = nil
            self.persist()
        }

        reviewer.send(prompt)
    }

    /// Put another session's reply on screen here, as it arrives.
    ///
    /// The second half of `askOpinion`, split out for a caller that already has
    /// the agent running. A crew's delegates are started, timed out and
    /// interrupted by `Crew` — it owns them, because it is the thing that knows
    /// when a turn never landed — so what is left for this session to do is the
    /// part `askOpinion` does after `send`: hold a placeholder open and mirror
    /// into it.
    ///
    /// Returns the id of the block, for `stopMirroring`.
    @discardableResult
    func mirror(_ other: Session, labelled label: String) -> UUID {
        hydrate()
        let id = UUID()
        append(.opinion(id: id, agent: label, text: "", done: false))
        persist()

        // Same throttle and the same reasoning as `askOpinion`'s: this fires
        // twice per streamed token, and each mirror rescans both transcripts.
        reviewerFeeds[id] = other.objectWillChange.sink { [weak self, weak other] in
            guard let self, self.mirrorsPending.insert(id).inserted else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak other] in
                guard let self else { return }
                self.mirrorsPending.remove(id)
                guard let other else { return }
                self.updateOpinion(id, from: other, done: false)
            }
        }
        return id
    }

    /// Close a mirrored block. The session behind it is not touched — it
    /// belongs to whoever started it.
    func stopMirroring(_ id: UUID, from other: Session) {
        updateOpinion(id, from: other, done: true)
        reviewerFeeds[id] = nil
        mirrorsPending.remove(id)
        persist()
    }

    /// A line of plumbing in the transcript — what was split how, what was held
    /// back, what a run cost.
    func note(_ text: String) {
        hydrate()
        append(.notice(id: UUID(), text: text))
        persist()
    }

    /// Run one prompt on this session's account, out of band, and hand back the
    /// reply. Nothing about it reaches this transcript.
    ///
    /// `askOpinion`'s quieter sibling. That one asks a *different* agent and
    /// shows its answer here, because the answer is the point. This one asks
    /// *this* account to do a piece of work whose output is going somewhere
    /// else — redacting material for a relay — so a placeholder in this
    /// transcript would be a paragraph of plumbing in the middle of a
    /// conversation about something else.
    ///
    /// Same account, same directory, same model: a redaction is only as
    /// trustworthy as the credentials it runs under, and the whole reason the
    /// transform happens on this side is that this side is the one entitled to
    /// read the material.
    func quietly(_ prompt: String, then finish: @escaping (String?) -> Void) {
        let key = UUID()
        let helper = Session(account: account, directory: directory, name: "relay",
                             modelID: model.id, effort: effort)
        helper.isEphemeral = true
        reviewers[key] = helper

        // A turn that never lands would otherwise leave the destination showing
        // a pending chip forever. `endTurn` is the only thing that calls
        // `onTurnComplete`, and a CLI that dies mid-turn doesn't get there —
        // so the timeout isn't belt and braces, it's the other half of the
        // contract that `finish` is called exactly once.
        let expiry = DispatchWorkItem { [weak self] in
            guard let self, let stalled = self.reviewers[key] else { return }
            stalled.retire()
            self.reviewers[key] = nil
            finish(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 300, execute: expiry)

        helper.onTurnComplete = { [weak self] done in
            guard let self, self.reviewers[key] != nil else { return }
            expiry.cancel()
            var reply: String?
            for item in done.items {
                if case .assistant(_, let text) = item { reply = text }
            }
            done.retire()
            self.reviewers[key] = nil
            finish(reply)
        }

        helper.send(prompt)
    }

    private func updateOpinion(_ id: UUID, from reviewer: Session, done: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              case .opinion(_, let agent, let existing, let alreadyDone) = items[index],
              !alreadyDone else { return }

        // From the end. Scanning forwards read every item to keep the last one,
        // which is the same answer for twice the work.
        var reply = ""
        for item in reviewer.items.reversed() {
            if case .assistant(_, let text) = item { reply = text; break }
        }
        // A notice — a crashed process, a refused resume — is the only thing
        // that will ever come back, so surface it rather than sitting blank.
        //
        // Framed as a failure, never as the answer. This block used to hand the
        // notice straight through as `text`, so a delegate that died printed its
        // CLI's stderr into the transcript under its own name, in the place its
        // report should have been — and a lead reading that block had no way to
        // tell "the agent said this" from "the agent said nothing". The two
        // sentences are the two separate facts: it didn't answer, and here is
        // what was going on when it didn't.
        var failure: String?
        if reply.isEmpty, done {
            for item in reviewer.items.reversed() {
                if case .notice(_, let text) = item { failure = text; break }
            }
        }
        guard reply != existing || done else { return }
        let shown = reply.isEmpty && done
            ? failure.map { "No answer came back — \($0)" } ?? "No answer came back."
            : reply
        items[index] = .opinion(id: id, agent: agent, text: shown, done: done)
    }

    /// Called when the session comes on screen.
    func prepare() {
        // First, because the ACP handshake reads `hasStarted` and
        // `conversationID` to decide between rejoining and creating.
        hydrate()
        adapter.prepare()
        let account = account
        Task { @MainActor in UsageStore.shared.refresh(account) }
    }

    func interrupt() {
        clearQueue()
        adapter.interrupt()
    }
    /// Shut a session down and let go of it *later*.
    ///
    /// The adapters hold their session `unowned` — deliberately, since the
    /// session owns the adapter and a strong pair would never be freed. The
    /// consequence is that a session must outlive every main-queue block its
    /// adapter has already enqueued, and `interrupt()` signs off by enqueueing
    /// one more: `DispatchQueue.main.async { self.session.isRunning = false }`.
    ///
    /// So dropping the last strong reference in the same turn as the shutdown
    /// frees the session before that block runs, and the unowned access aborts
    /// the process — which is exactly what unowned is for, and exactly what it
    /// did. Parking the reference for a moment costs an idle object for a
    /// second and makes the ordering explicit rather than lucky.
    ///
    /// Everything that discards a session goes through here rather than
    /// interrupting the adapter and releasing: a throwaway finishing its turn,
    /// one timing out, and a real session being deleted.
    func retire() {
        adapter.interrupt()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            withExtendedLifetime(self) {}
        }
    }

    // MARK: Streaming sinks, called on the main queue by the adapter

    func beginAssistant() {
        // Only open a new block if the last item isn't already an open one, so
        // deltas arriving after a tool call continue the same paragraph rather
        // than fragmenting into a block per chunk.
        if case .assistant = items.last { return }
        items.append(.assistant(id: UUID(), text: ""))
    }

    /// Appended in place rather than rebuilt.
    ///
    /// `existing + delta` allocates a whole new string per delta, so a long
    /// reply copied itself once per token — quadratic in the length of the
    /// answer. Clearing the array's copy first leaves `text` holding the only
    /// reference to the buffer, which is what lets `+=` extend it in place
    /// instead of copying.
    func appendAssistant(_ delta: String) {
        closeThinking()
        beginAssistant()
        guard case .assistant(let id, var text) = items.last else { return }
        items[items.count - 1] = .assistant(id: id, text: "")
        text += delta
        items[items.count - 1] = .assistant(id: id, text: text)
    }

    /// Appended in place, for exactly the reason `appendAssistant` is.
    ///
    /// This was left doing `existing + delta` when that one was fixed, so a long
    /// reasoning block copied its entire buffer once per delta — quadratic in
    /// the length of the thought, sixty times a second, and progressively
    /// jankier the longer the model thinks. Same trick: blank the array's copy
    /// first so `text` holds the only reference to the buffer, then `+=` extends
    /// it rather than allocating a new one.
    func appendThinking(_ delta: String) {
        guard case .thinking(let id, var text, let started, nil) = items.last else {
            items.append(.thinking(id: UUID(), text: delta, started: Date(), finished: nil))
            return
        }
        items[items.count - 1] = .thinking(id: id, text: "", started: started, finished: nil)
        text += delta
        items[items.count - 1] = .thinking(id: id, text: text, started: started, finished: nil)
    }

    /// Stamp the most recent open thinking block. Called whenever anything
    /// else arrives — visible text or a tool call both mean reasoning ended.
    func closeThinking() {
        guard let index = items.lastIndex(where: {
            if case .thinking(_, _, _, nil) = $0 { return true }
            return false
        }) else { return }
        guard case .thinking(let id, let text, let started, _) = items[index] else { return }
        items[index] = .thinking(id: id, text: text, started: started, finished: Date())
    }

    /// Any transcript element other than reasoning closes the open block.
    func append(_ item: TranscriptItem) {
        closeThinking()
        // A repeated notice says nothing the first one didn't. Four identical
        // "couldn't rejoin" lines stacked up is what a failed resume looked
        // like across four relaunches, and it reads as the app malfunctioning
        // rather than as one fact stated once.
        if case .notice(_, let text) = item,
           case .notice(_, let previous)? = items.last, previous == text {
            return
        }
        items.append(item)
    }

    /// Everything the agent said this turn, scanned for a server.
    ///
    /// Tool output alone wasn't enough. A backgrounded server returns
    /// "Command running in background with ID: …" and nothing else — the URL
    /// only ever appears in the *reply*, where the agent tells you where it's
    /// running. So the whole turn gets read, not just its tool results.
    func scanForDevServer() {
        // Collected then joined once. Prepending built the turn's text by
        // copying everything already gathered on every block — quadratic in the
        // length of the reply, for a string that is thrown away immediately.
        var replies: [String] = []
        for item in items.reversed() {
            if case .user = item { break }
            if case .assistant(_, let reply) = item { replies.append(reply) }
        }
        guard !replies.isEmpty else { return }
        noticeDevServer(in: replies.reversed().joined(separator: "\n"))
    }

    /// Watch command output for a dev server announcing itself.
    ///
    /// Vite, Next, Rails, Python's http.server — they all print the URL, and
    /// that output already passes through here on its way to a tool card. So
    /// the preview needs no new plumbing, just noticing.
    func noticeDevServer(in output: String) {
        guard let url = DevServer.find(in: output) else { return }
        noticeDevServer(url)
    }

    /// The same thing, for callers that did the scanning themselves.
    ///
    /// The adapters take this door: a tool result can be two megabytes, and
    /// running a regular expression over it inside the main-queue block that
    /// resolves the card put that scan squarely in the middle of a streaming
    /// frame. They match on their own reader queue and hop over with the answer.
    func noticeDevServer(_ url: URL) {
        guard devServer != url else { return }
        devServer = url
        // A newly started server supersedes anything typed before it existed.
        browserURLIsManual = false
        // Point an already-open panel at it rather than leaving it on a port
        // that just died — a restart usually means a new one.
        if browserVisible { browserURL = url }
    }

    /// What the panel should show when it opens.
    var preferredBrowserURL: URL? {
        if !browserURLIsManual, let devServer { return devServer }
        return browserURL ?? devServer
    }

    /// Match a `tool_result` back to the card that proposed it.
    ///
    /// Takes the outcome rather than a bare `isError`, because only the adapter
    /// can tell a refusal from a failure — it knows which flags the agent was
    /// launched with, and Copilot says so outright.
    /// `text` is the tool's own output, needed for the cards that render what
    /// came back rather than only whether it worked. It can't be read off the
    /// state: `ToolState.message` carries text for a decline or a failure and
    /// nothing for `.applied`, so a *successful* search resolved with an empty
    /// string and scraped no sources from it. The sources list under a search
    /// only ever appeared for searches that had failed.
    func resolve(toolUseID: String, state: ToolState, text: String = "") {
        guard let index = items.lastIndex(where: {
            switch $0 {
            case .tool(_, let id, _, _, _, _):  return id == toolUseID
            case .diff(_, let id, _, _, _):     return id == toolUseID
            case .search(_, let id, _, _, _):   return id == toolUseID
            default: return false
            }
        }) else { return }

        switch items[index] {
        case .tool(let uuid, let id, let name, let target, let detail, _):
            items[index] = .tool(id: uuid, toolUseID: id, name: name,
                                 target: target, detail: detail, state: state)
        case .diff(let uuid, let id, let file, let rows, _):
            items[index] = .diff(id: uuid, toolUseID: id, file: file,
                                 rows: rows, state: state)
        case .search(let uuid, let id, let query, let existing, _):
            let scraped = SearchResult.scrape(text.isEmpty ? (state.message ?? "") : text)
            items[index] = .search(id: uuid, toolUseID: id, query: query,
                                   results: scraped.isEmpty ? existing : scraped,
                                   state: state)
        default:
            break
        }
    }

    /// Give a tool card the file it's actually working on.
    ///
    /// For agents that stream their arguments rather than sending them up front,
    /// the card is created before anyone knows what it operates on — so it first
    /// appears labelled with the tool's own name ("Write") and is corrected here
    /// a moment later.
    func retarget(toolUseID: String, to target: String) {
        guard let index = items.lastIndex(where: {
            if case .tool(_, let id, _, _, _, _) = $0 { return id == toolUseID }
            return false
        }), case .tool(let uuid, let id, let name, _, let detail, let state) = items[index]
        else { return }
        items[index] = .tool(id: uuid, toolUseID: id, name: name,
                             target: target, detail: detail, state: state)
    }

    /// Promote a plain tool row to the diff review surface.
    ///
    /// Same reason: the content of a write only arrives once its arguments have
    /// finished streaming. Deliberately one-way — a card that is already a diff
    /// stays one, so a late update can't downgrade a review surface back into a
    /// row.
    func upgradeToDiff(toolUseID: String, file: String, rows: [DiffRow]) {
        guard !rows.isEmpty, let index = items.lastIndex(where: {
            if case .tool(_, let id, _, _, _, _) = $0 { return id == toolUseID }
            return false
        }), case .tool(let uuid, let id, _, _, _, let state) = items[index]
        else { return }
        items[index] = .diff(id: uuid, toolUseID: id, file: file, rows: rows, state: state)
    }

    // MARK: Plan

    /// `TaskCreate` — IDs are assigned in creation order, matching the CLI's
    /// own sequential numbering, so a later `TaskUpdate` can find its task.
    func createTodo(subject: String, activeForm: String?) {
        todos.append(Todo(id: String(todos.count + 1), subject: subject,
                          activeForm: activeForm, status: .pending))
        // Insert the card once, at the point the agent commits to a plan.
        if !items.contains(where: { if case .todos = $0 { return true }; return false }) {
            append(.todos(id: UUID()))
        }
    }

    /// ACP's `plan` update, which sends the whole list every time rather than
    /// Claude's create-then-patch. Replacing wholesale is the honest mapping;
    /// diffing it against the previous list would invent an ordering the
    /// protocol doesn't promise.
    func setPlan(_ replacement: [Todo]) {
        todos = replacement
        if !todos.isEmpty,
           !items.contains(where: { if case .todos = $0 { return true }; return false }) {
            append(.todos(id: UUID()))
        }
    }

    /// Copilot sends its real model list once the session opens. If the model
    /// in use isn't on it, move to the closest thing rather than leaving a
    /// picker showing something the agent won't accept.
    /// Deliberately not `ModelCatalog.prefer`.
    ///
    /// This is reconciliation, not a choice: a placeholder id being replaced by
    /// the real one the agent just announced, or a fallback to whatever is left
    /// when the saved model is no longer offered. Recording either as a
    /// preference would pin an account to `models[0]` the first time an
    /// entitlement lapsed, and keep it there after it came back.
    func adoptAvailableModels(_ models: [AgentModel]) {
        guard !models.isEmpty else { return }
        availableModels = models
        if !models.contains(where: { $0.id == model.id }) {
            model = models.first { $0.id.hasPrefix(model.id) } ?? models[0]
        }
    }

    /// `TaskUpdate` — status, and optionally a revised subject.
    func updateTodo(id: String, status: String?, subject: String?, activeForm: String?) {
        guard let index = todos.firstIndex(where: { $0.id == id }) else { return }
        if let status, let parsed = Todo.Status(rawValue: status) { todos[index].status = parsed }
        if let subject { todos[index].subject = subject }
        if let activeForm { todos[index].activeForm = activeForm }
    }
}

/// Owns the session roster and its persistence.
///
/// Order within an account is **stable**, not recency-sorted. With three
/// sessions per account, rows shuffling under the cursor costs more than
/// surfacing the freshest one gains — position becomes muscle memory.
final class Workspace: ObservableObject {

    /// Whatever is showing this workspace, if anything is. See `WorkspaceHost`.
    ///
    /// Weak because the host owns the workspace in both cases that exist, and a
    /// strong reference here would be the retain cycle.
    weak var host: WorkspaceHost?

    @Published private(set) var sessions: [Session] = []
    /// The column with the keyboard, not "the session you can see".
    ///
    /// That distinction is the whole of the columns feature at this level.
    /// Everything that used to mean "selected" — ⌘1–4, Rename…, Delete, the
    /// menu bar's Interrupt — still means the focused column, so none of it
    /// had to change. What changed is that being unselected no longer means
    /// being off screen.
    @Published var selection: Session.ID? {
        didSet {
            Prefs.store.set(selection?.uuidString, forKey: Self.selectionKey)
            // Selecting something that isn't on screen puts it where you were
            // looking: it takes over the focused column rather than opening a
            // new one. Opening a new one is a separate, deliberate action.
            if let id = selection, !columns.contains(id) {
                if let index = oldValue.flatMap({ columns.firstIndex(of: $0) }) {
                    columns[index] = id
                } else {
                    columns = [id]
                }
            }
            // Landing on a session clears its unread mark — you've seen it.
            if let selected {
                // Ahead of the column being built, so the transcript is there
                // for the first frame rather than one frame of "no messages
                // yet" while the background sweep catches up.
                selected.hydrate()
                selected.needsAttention = false
                lastVisited[selected.account] = selected.id
            }
        }
    }

    /// The sessions on screen, left to right. Never empty while any session
    /// exists, and always contains `selection`.
    @Published private(set) var columns: [Session.ID] = [] {
        didSet {
            Prefs.store.set(columns.map(\.uuidString), forKey: Self.columnsKey)
        }
    }

    /// The conversation in the floating window, if any.
    ///
    /// One at a time, deliberately. The pop-out exists to be watched while
    /// you're doing something else, and three overlapping always-on-top windows
    /// over the thing you were trying to look at is the opposite of that.
    ///
    /// Its column is *kept*, and draws a placeholder — see `SessionColumns`.
    /// Removing it would reshuffle the arrangement on the way out and again on
    /// the way back, and leave a session that's on screen with no home to
    /// return to.
    @Published var poppedOut: Session.ID? {
        didSet {
            Prefs.store.set(poppedOut?.uuidString, forKey: Self.poppedOutKey)
        }
    }

    /// Three, and the reason is width rather than taste.
    ///
    /// A column narrower than `minColumnWidth` can't hold a composer with a
    /// model picker and a mic on one line. Three of those plus the sidebar
    /// wants a window around 1600pt; the layout works out how many actually
    /// fit and shows that many, so this is the ceiling rather than the count.
    static let maxColumns = 3
    static let minColumnWidth: CGFloat = 400

    var columnSessions: [Session] { columns.compactMap { id in sessions.first { $0.id == id } } }

    func isOnScreen(_ id: Session.ID) -> Bool { columns.contains(id) }

    /// Put a session in a column of its own, beside the focused one.
    ///
    /// At the ceiling the far end gives way rather than the action doing
    /// nothing — a keystroke that silently declines is indistinguishable from
    /// one that didn't register.
    func openBeside(_ id: Session.ID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        if let existing = columns.firstIndex(of: id) {
            // Already up. Focus it instead of duplicating it: the same session
            // in two columns would be two views of one transcript, with two
            // drafts and one composer's worth of attention.
            selection = columns[existing]
            return
        }
        let after = selection.flatMap { columns.firstIndex(of: $0) }.map { $0 + 1 } ?? columns.count
        let at = min(after, columns.count)
        columns.insert(id, at: at)
        if columns.count > Self.maxColumns {
            // One over, so one goes: whichever end is further from what you
            // just opened, so the new column and the one you opened it from
            // both survive.
            if at <= columns.count / 2 { columns.removeLast() } else { columns.removeFirst() }
        }
        selection = id
    }

    /// Put a session where it can be seen, without throwing anything away.
    ///
    /// Not `openBeside`, which evicts a column once you're at the cap. Something
    /// arriving in a conversation is a reason to show you that conversation, not
    /// a reason to close one of the ones you deliberately arranged — so at the
    /// cap this takes the focused column, which is the slot you were already
    /// prepared to lose.
    func reveal(_ id: Session.ID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        if columns.contains(id) || columns.count >= Self.maxColumns {
            selection = id
        } else {
            openBeside(id)
        }
    }

    /// Close a column. The last one standing stays — a pane with nothing in it
    /// is a worse answer than a pane you have to switch away from.
    func closeColumn(_ id: Session.ID) {
        guard columns.count > 1, let index = columns.firstIndex(of: id) else { return }
        columns.remove(at: index)
        if selection == id { selection = columns[min(index, columns.count - 1)] }
    }

    /// Send a session to the floating window.
    ///
    /// It also takes the keyboard, because popping out is a statement about
    /// which conversation you're in — and the placeholder it leaves behind has
    /// nothing to focus.
    func popOut(_ id: Session.ID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        poppedOut = id
        selection = id
    }

    /// Bring it back, into the column it left if that column is still there and
    /// into a new one otherwise — popping out from the sidebar doesn't require
    /// the session to have been on screen first.
    func popIn() {
        guard let id = poppedOut else { return }
        poppedOut = nil
        reveal(id)
    }

    /// Move the keyboard one column left or right. Doesn't wrap: the ends are
    /// the ends, and wrapping in a three-item row reads as a jump.
    func focusColumn(by offset: Int) {
        guard let current = selection.flatMap({ columns.firstIndex(of: $0) }) else { return }
        let next = current + offset
        guard columns.indices.contains(next) else { return }
        selection = columns[next]
    }

    /// The session you were last in, per account, for ⌘1–4.
    ///
    /// Recorded on selection rather than derived from the roster: it used to be
    /// computed as "the first session in the account", which is a different
    /// thing that happens to be right on the first press and wrong on every
    /// press after it.
    private var lastVisited: [Account: Session.ID] = [:]

    /// The session whose name is being edited, if any.
    ///
    /// Held here rather than in the row so the menu bar's Rename… can raise the
    /// same field the row's ⋯ menu does. The row clears it once it has taken
    /// focus.
    @Published var renaming: Session.ID?
    @Published var collapsed: Set<Account> = [] {
        didSet {
            Prefs.store.set(collapsed.map(\.rawValue), forKey: Self.collapsedKey)
        }
    }
    /// The session awaiting a delete confirmation. Lives here rather than in a
    /// view so the sidebar's ⋯ menu and the menu bar's ⌘⌫ can both raise the
    /// same dialog.
    @Published var pendingDeletion: Session?

    /// Bumped by the menu bar's "Send to Session…", which offers whatever you
    /// last copied. Here for the same reason Rename… is: `.commands` sits
    /// outside the view hierarchy and can't reach the focused column's state,
    /// and a counter is the smallest thing that survives being fired twice with
    /// the same clipboard.
    @Published var clipboardRelayTick = 0

    // Still `bench.` on purpose. These are the keys your session roster is
    // written under in the preferences that exist right now; renaming them is
    // not a rename, it's a delete — the app would start up looking for keys
    // nobody has ever written and find no sessions at all. Same reasoning as
    // `Account.work` keeping its raw value after it was relabelled Enterprise.
    private static let storeKey = "bench.sessions.v1"
    private static let selectionKey = "bench.selection"
    private static let collapsedKey = "bench.collapsed"
    private static let columnsKey = "bench.columns"
    private static let poppedOutKey = "bench.poppedOut"

    init() {
        // Whichever store is built first pulls the old app's data across. It
        // can't live in `HoneycodeApp.init` — stored-property initialisers, which
        // is what `@StateObject` is, run *before* the enclosing type's `init`
        // body, so the stores had already read empty defaults by then.
        Migration.run()
        Support.prepare()

        let stored = Self.load()
        // Model and effort were being written to the store and then dropped on
        // the way back in — the descriptor carried them, this initialiser
        // didn't pass them on. The defaults quietly reasserted themselves on
        // every launch, which reads as the picker not working rather than as a
        // persistence bug.
        sessions = stored.isEmpty ? Self.seed() : stored.map {
            Session(id: $0.id ?? UUID(),
                    account: $0.account,
                    directory: URL(fileURLWithPath: $0.path),
                    name: $0.name,
                    modelID: $0.modelID,
                    effort: $0.effort ?? .high,
                    isolated: $0.isolated ?? false,
                    origin: $0.origin ?? .user,
                    startedAt: $0.startedAt)
        }
        sessions.forEach(adopt)

        // Reopen where you left off. Falls back to the first session if that
        // one has since been deleted.
        let remembered = Prefs.store.string(forKey: Self.selectionKey)
            .flatMap(UUID.init(uuidString:))
        // Columns come back before selection does. Setting `selection` is what
        // repairs an empty or stale column list, so restoring them the other
        // way round would have the selection rebuild a single column and throw
        // the arrangement away before it was ever read.
        columns = (Prefs.store.stringArray(forKey: Self.columnsKey) ?? [])
            .compactMap(UUID.init(uuidString:))
            .filter { id in sessions.contains { $0.id == id } }
            .prefix(Self.maxColumns)
            .reduce(into: []) { unique, id in if !unique.contains(id) { unique.append(id) } }
        selection = sessions.contains { $0.id == remembered } ? remembered : sessions.first?.id
        collapsed = Set((Prefs.store.stringArray(forKey: Self.collapsedKey) ?? [])
            .compactMap(Account.init(rawValue:)))
        // The floating window comes back with the arrangement, for the same
        // reason the columns do: where you left a conversation is part of where
        // you left off. A session deleted since simply doesn't reopen.
        poppedOut = Prefs.store.string(forKey: Self.poppedOutKey)
            .flatMap(UUID.init(uuidString:))
            .flatMap { id in sessions.contains { $0.id == id } ? id : nil }

        // Only the transcripts about to be drawn are read on this thread. The
        // rest arrive from `hydrateRemaining` a moment after the window is up.
        for id in columns { sessions.first { $0.id == id }?.hydrate() }
        hydrateRemaining()

        // Warm the CA bundle off the main thread.
        //
        // Building it is two synchronous `security find-certificate` dumps of
        // the whole system keychain, and it was happening lazily — inside the
        // first Kimi session's `startIfNeeded`, on the main thread, at the exact
        // moment you'd pressed send. Doing it here costs nothing anyone waits
        // for; the lock inside makes the racing lazy call a no-op.
        let needsTrust = sessions.contains {
            if case .acp = $0.account.protocolKind { return true }
            return false
        } && ProcessInfo.processInfo.environment["NODE_EXTRA_CA_CERTS"] == nil
        if needsTrust {
            DispatchQueue.global(qos: .utility).async { _ = SystemTrust.caBundle() }
        }

        // A roster written before ids existed gets fresh ones; write them back
        // now so the next launch can find the transcripts this one creates.
        if stored.contains(where: { $0.id == nil }) { save() }
        SessionStore.prune(keeping: Set(sessions.map(\.id)))

    }

    /// Write everything down, and wait for it to land.
    ///
    /// The last turn of a session is the one most likely to be lost, so this
    /// exists to be called at the moment the process is going away rather than
    /// relying on each turn's own save. Whose job it is to notice that moment
    /// is the host's: an app hears `applicationWillTerminate`, a daemon hears
    /// `SIGTERM`, and `Workspace` should have to know about neither.
    func flush() {
        sessions.forEach { $0.persist() }
        save()
        // Transcript writes are queued off the main thread, so quitting has to
        // wait for them — otherwise the save above is the one that gets dropped.
        SessionStore.drain()
    }

    /// Read every transcript nobody has asked for yet, off the main thread.
    ///
    /// The sessions you can see are hydrated before the first frame; these are
    /// the ones behind them, which still have to load eventually — the command
    /// palette searches across every conversation, and a notification quotes the
    /// last reply of whichever session finished. Decoded on a background queue
    /// and applied one at a time, so a roster of nine multi-megabyte transcripts
    /// fills in without ever holding the main thread for more than one of them.
    private func hydrateRemaining() {
        let pending = sessions.filter { !$0.isHydrated }.map(\.id)
        guard !pending.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            for id in pending {
                let snapshot = SessionStore.load(id)
                DispatchQueue.main.async { [weak self] in
                    self?.sessions.first { $0.id == id }?.restore(snapshot)
                }
            }
        }
    }

    /// Give a session a way to ask for the roster to be written out, and a way
    /// to announce that it's finished.
    private func adopt(_ session: Session) {
        session.onPersistableChange = { [weak self] in self?.save() }
        session.onTurnComplete = { [weak self] finished in
            guard let self else { return }
            // Nothing for the session you're already watching. A banner about
            // text appearing in front of you is how an app trains you to switch
            // its notifications off.
            // On screen, not selected. With columns, a reply can land in a
            // conversation you're looking at but haven't got the keyboard in —
            // and a notification about text appearing in front of you is how
            // an app trains you to switch its notifications off.
            let watching = (self.host?.isForeground ?? false)
                && self.columns.contains(finished.id)
            guard !watching else {
                // Nor an unread mark. `endTurn` sets one unconditionally,
                // because a session has no idea whether anyone is looking at
                // it; this does. Otherwise a reply you sat and read carried a
                // dot the moment you switched to something else.
                finished.needsAttention = false
                return
            }
            self.host?.announce(sessionID: finished.id,
                                title: "\(finished.account.title) · \(finished.name)",
                                body: finished.lastReply)
        }
    }

    /// The conversations *you* started, in an account.
    ///
    /// Agent runs are deliberately excluded. They live in the same roster and
    /// on the same disk — that's what gives them a transcript for free — but
    /// they are not sessions you opened, and a sidebar that filled up with
    /// forty-eight of them a day would be useless within a week. Everything
    /// keyed off this filter comes along for free: ⌘1–4, ⌘⌥↑/↓, the section
    /// counts.
    func sessions(in account: Account) -> [Session] {
        sessions.filter { $0.account == account && $0.origin == .user }
    }

    /// Every run of one agent, newest first.
    func runs(of agent: UUID) -> [Session] {
        sessions.filter { $0.origin == .agent(agent) }
            .sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
    }

    /// Put an agent's run in the roster.
    ///
    /// Through the same `adopt` every session goes through, so a run persists,
    /// notifies on completion and is searchable — the point of making a run a
    /// `Session` rather than a new kind of thing. It is *not* selected and does
    /// not take a column: a run starting on a timer must not move the window
    /// you're working in.
    func add(run: Session) {
        adopt(run)
        sessions.append(run)
        save()
    }

    var selected: Session? { sessions.first { $0.id == selection } }

    // MARK: Mutation

    func add(account: Account, directory: URL) {
        // Two sessions on one directory is expected — same repo under personal
        // and work, or two parallel tasks. Disambiguate rather than refuse.
        let base = directory.lastPathComponent
        let taken = sessions(in: account).map(\.name)
        var name = base
        var n = 2
        while taken.contains(name) { name = "\(base) \(n)"; n += 1 }

        let session = Session(account: account, directory: directory, name: name)
        adopt(session)
        sessions.append(session)
        selection = session.id
        save()
    }

    func remove(_ session: Session) {
        // `retire`, not `shutdown` — the line below drops the roster's
        // reference, which on a session nothing else is holding is the last
        // one. See `Session.retire`.
        session.retire()
        SessionStore.remove(session.id)
        sessions.removeAll { $0.id == session.id }
        // Out of the columns before out of the selection: `selection`'s own
        // didSet repairs the column list, and it can only do that correctly
        // once the deleted session is no longer in it.
        columns.removeAll { $0 == session.id }
        // The floating window is showing a conversation that no longer exists.
        if poppedOut == session.id { poppedOut = nil }
        if selection == session.id { selection = columns.first ?? sessions.first?.id }
        save()
    }

    func rename(_ session: Session, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        session.name = trimmed
        save()
    }

    func setCollapsed(_ account: Account, _ isCollapsed: Bool) {
        guard collapsed.contains(account) != isCollapsed else { return }
        if isCollapsed { collapsed.insert(account) } else { collapsed.remove(account) }
    }

    /// Deleting now destroys a saved transcript, so it asks first — but only
    /// when there's something to lose. An empty session is just a row, and
    /// making you confirm the removal of nothing is how confirmation dialogs
    /// stop being read.
    func requestDelete(_ session: Session) {
        // Forced, because "is there anything to lose" is a question about the
        // file on disk — an unhydrated session looks empty and would be deleted
        // without a word.
        session.hydrate()
        // Nothing to lose on a throwaway, so no ceremony.
        if session.isEphemeral || session.items.isEmpty { remove(session) }
        else { pendingDeletion = session }
    }

    func confirmDeletion() {
        if let session = pendingDeletion { remove(session) }
        pendingDeletion = nil
    }

    // MARK: Keyboard navigation

    /// ⌘1 / ⌘2 / ⌘3 — jump to an account, landing on the session you were last
    /// in there rather than always the first.
    func focus(_ account: Account) {
        let inAccount = sessions(in: account)
        guard !inAccount.isEmpty else { return }
        collapsed.remove(account)
        if let current = selected, current.account == account { return }
        selection = (lastVisited[account] ?? inAccount.first?.id)
        // A remembered session can have been deleted since.
        if !inAccount.contains(where: { $0.id == selection }) { selection = inAccount.first?.id }
    }

    /// ⌘⌥↓ / ⌘⌥↑ — step through every session in sidebar order, crossing
    /// account boundaries so the whole list is reachable without the mouse.
    func step(_ delta: Int) {
        let ordered = Account.allCases.flatMap { sessions(in: $0) }
        guard !ordered.isEmpty else { return }
        let current = ordered.firstIndex { $0.id == selection } ?? 0
        let next = (current + delta + ordered.count) % ordered.count
        selection = ordered[next].id
    }

    // MARK: Persistence

    func save() {
        let data = try? JSONEncoder().encode(
            sessions.filter { !$0.isEphemeral }.map(\.descriptor))
        Prefs.store.set(data, forKey: Self.storeKey)
    }

    private static func load() -> [SessionDescriptor] {
        guard let data = Prefs.store.data(forKey: storeKey),
              let list = try? JSONDecoder().decode([SessionDescriptor].self, from: data)
        else { return [] }
        return list
    }

    private static func seed() -> [Session] {
        let workspace = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Workspace")
        return [
            Session(account: .personal, directory: workspace.appendingPathComponent("Personal")),
            Session(account: .work, directory: workspace),
        ]
    }
}
