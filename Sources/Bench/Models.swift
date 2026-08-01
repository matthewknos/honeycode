import SwiftUI
import Combine

/// Which agent and which credentials a session runs under.
///
/// Account switching is nothing more than an environment variable on the child
/// process — `CLAUDE_CONFIG_DIR` picks the credential store, so work and
/// personal are the same binary pointed at different config directories.
enum Account: String, CaseIterable, Identifiable, Codable {
    case personal, work, copilot

    var id: String { rawValue }

    /// Names the *agent*, not just the credential set. With three accounts and
    /// two different agents behind them, "Personal" and "Work" alone left the
    /// sidebar reading as though Copilot were a third Claude account.
    var title: String {
        switch self {
        case .personal: return "Claude Personal"
        case .work:     return "Claude Work"
        case .copilot:  return "Copilot"
        }
    }

    /// For places where the full name would crowd the line — the composer's
    /// placeholder, mainly.
    var shortTitle: String {
        switch self {
        case .personal: return "Personal"
        case .work:     return "Work"
        case .copilot:  return "Copilot"
        }
    }

    var accent: Color {
        switch self {
        case .personal: return .accentPersonal
        case .work:     return .accentWork
        case .copilot:  return .accentCopilot
        }
    }

    // Symbols were tried here — folder / building / code-brackets — and pulled.
    // Literal clipart for an abstract idea like "work" reads as stock iconography,
    // and three different glyphs down one column is visual noise. A single
    // colour-coded dot carries the same information with none of the opinion.

    /// ⌘1 / ⌘2 / ⌘3
    var shortcut: KeyEquivalent {
        switch self {
        case .personal: return "1"
        case .work:     return "2"
        case .copilot:  return "3"
        }
    }

    var configDir: String? {
        switch self {
        case .personal: return NSHomeDirectory() + "/.claude-personal"
        case .work:     return NSHomeDirectory() + "/.claude"
        case .copilot:  return nil
        }
    }
}

/// One rendered element of the transcript.
///
/// Deliberately not a single `Message` type with a role: an assistant turn, a
/// thinking block and a tool call want genuinely different presentation, and
/// collapsing them into one shape pushes that difference into a switch inside
/// the view, where it tends to decay into "same card, different colour".
enum TranscriptItem: Identifiable, Codable {
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
}

/// What became of a tool call.
///
/// A card drawn at `tool_use` time is a *proposal* — the result arrives later,
/// and until this was wired a refused edit rendered identically to an applied
/// one. That's the worst kind of wrong: confidently mis-stating what happened
/// to the user's files.
enum ToolState: Codable {
    case pending
    case applied
    /// Refused before it ran — a permission decision.
    case declined(String)
    /// Ran and errored. A different fact about the world, and conflating the
    /// two was a real bug: `node` missing from PATH rendered as a struck-through
    /// "Declined", which says the tool was blocked when in truth it executed and
    /// failed. Both are `is_error: true` on the wire; only the app knows which.
    case failed(String)

    var isDeclined: Bool { if case .declined = self { return true }; return false }
    var isFailed: Bool { if case .failed = self { return true }; return false }
    /// Struck through and dimmed — the change never happened.
    var isRefused: Bool { isDeclined }

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

    /// ⌥⌘1…4
    var shortcut: KeyEquivalent {
        switch self {
        case .summary:  return "1"
        case .normal:   return "2"
        case .thinking: return "3"
        case .verbose:  return "4"
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
    let id = UUID()
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
        let url = folder.appendingPathComponent("artifact-\(id.uuidString.prefix(8)).\(suffix)")
        guard (try? markup.write(to: url, atomically: true, encoding: .utf8)) != nil
        else { return nil }
        return url
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

    var summary: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let u = formatter.string(from: NSNumber(value: used)) ?? "\(used)"
        let w = formatter.string(from: NSNumber(value: window)) ?? "\(window)"
        return "\(u) of \(w) tokens in context.\nPast roughly 90% the agent "
            + "compacts older turns to make room, which loses detail."
    }
}

/// What the CLI says about your usage window.
///
/// The stream carries this on every turn and Bench used to drop it on the
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
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            parts.append("resets \(formatter.string(from: resetsAt))")
        }
        if usingOverage { parts.append("using overage") }
        else if !overageAvailable { parts.append("no overage available") }
        return parts.joined(separator: " · ")
    }
}

/// The roster entry for one session. The conversation itself lives beside it
/// in a `SessionSnapshot`, keyed by `id`.
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
}

/// A conversation pinned to a working directory and an account.
final class Session: ObservableObject, Identifiable {
    let id: UUID
    let account: Account
    let directory: URL

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
    /// Held as markup rather than written to a file and loaded by URL, so it
    /// keeps `WebPreview`'s sandbox — null origin, no network beyond loopback.
    /// A `file://` load would hand a generated page the run of your disk, which
    /// is a lot to give away in exchange for a nicer address bar.
    ///
    /// Mutually exclusive with `browserURL`: the panel shows one thing, and two
    /// sources of truth for "what's on screen" is how you get a Back button
    /// that lies.
    @Published var browserHTML: Artifact?
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

    @Published var model: AgentModel {
        didSet { adapter.restart(); onPersistableChange?() }
    }
    @Published var effort: EffortChoice = .high {
        didSet { adapter.restart(); onPersistableChange?() }
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

    /// Which protocol this session speaks. Chosen once, from the account —
    /// there's no path where a Claude session becomes a Copilot one.
    /// Throwaway sessions running a second opinion for this one. Held strongly
    /// because their adapters reference them `unowned`; dropped once done.
    private var reviewers: [UUID: Session] = [:]
    private var reviewerFeeds: [UUID: AnyCancellable] = [:]

    private lazy var adapter: AgentAdapter = account == .copilot
        ? CopilotAdapter(session: self)
        : ClaudeAdapter(session: self)

    init(id: UUID = UUID(), account: Account, directory: URL, name: String? = nil,
         modelID: String? = nil, effort: EffortChoice = .high) {
        self.id = id
        self.account = account
        self.directory = directory
        self.name = name ?? directory.lastPathComponent

        let catalogue = ModelCatalog.models(for: account)
        availableModels = catalogue
        // A saved model that's no longer offered — entitlement withdrawn, or a
        // roster carried over from before this existed — falls back rather than
        // being sent to a CLI that will reject it.
        model = catalogue.first { $0.id == modelID } ?? catalogue.first ?? ModelCatalog.fallback

        let snapshot = SessionStore.load(id)
        conversationID = snapshot?.conversationID ?? UUID().uuidString
        hasStarted = snapshot?.started ?? false
        items = snapshot?.items ?? []
        todos = snapshot?.todos ?? []
        costUSD = snapshot?.costUSD ?? 0
        aiUnits = snapshot?.aiUnits
        tokensSent = snapshot?.tokensSent ?? 0
        // Restored so the readouts are right before the first turn of a resumed
        // session, rather than blank until it next reports.
        if let used = snapshot?.contextUsed, let window = snapshot?.contextWindow {
            context = ContextUsage(used: used, window: window)
        }

        self.effort = effort

        // A transcript saved mid-turn can carry an unclosed reasoning block,
        // which would restore as a permanent "Thinking…" shimmer for a turn
        // that ended when the app quit.
        closeThinking()
    }

    var descriptor: SessionDescriptor {
        SessionDescriptor(id: id, account: account, path: directory.path, name: name,
                          modelID: model.id, effort: effort)
    }

    /// Write the conversation out. Called at the end of each turn and when a
    /// message is sent — not on every streaming delta, which would be hundreds
    /// of writes a second for no benefit.
    func persist() {
        guard !isEphemeral else { return }
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

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Mid-turn: hold it. Nothing goes in the transcript yet either, because
        // a message shown as sent that hasn't been is the transcript lying.
        guard !isRunning else {
            queued.append(trimmed)
            return
        }

        items.append(.user(id: UUID(), text: trimmed))
        needsAttention = false
        sendTick += 1
        adapter.send(trimmed)
        // Save the prompt before the reply exists, so a crash mid-turn still
        // leaves a record of what was asked.
        persist()
    }

    /// Drop everything waiting — stopping a turn should stop what you queued
    /// behind it too, or the thing you interrupted starts right back up.
    func clearQueue() { queued.removeAll() }

    /// Ask a different agent about something, without leaving this thread.
    ///
    /// The answer comes back *here* rather than in a session you have to go and
    /// find. A review is a footnote to this conversation, not a conversation of
    /// its own — and switching away mid-thought to read it costs more than the
    /// second opinion is worth.
    func askOpinion(account: Account, modelID: String?, effort: EffortChoice,
                    modelTitle: String, prompt: String) {
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
        reviewerFeeds[id] = reviewer.objectWillChange.sink { [weak self, weak reviewer] in
            DispatchQueue.main.async {
                guard let self, let reviewer else { return }
                self.updateOpinion(id, from: reviewer, done: false)
            }
        }

        reviewer.onTurnComplete = { [weak self] finished in
            guard let self else { return }
            self.updateOpinion(id, from: finished, done: true)
            self.reviewerFeeds[id] = nil
            finished.shutdown()
            self.reviewers[id] = nil
            self.persist()
        }

        reviewer.send(prompt)
    }

    private func updateOpinion(_ id: UUID, from reviewer: Session, done: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              case .opinion(_, let agent, let existing, let alreadyDone) = items[index],
              !alreadyDone else { return }

        var reply = ""
        for item in reviewer.items {
            if case .assistant(_, let text) = item { reply = text }
        }
        // A notice — a crashed process, a refused resume — is the only thing
        // that will ever come back, so surface it rather than sitting blank.
        if reply.isEmpty, done {
            for item in reviewer.items {
                if case .notice(_, let text) = item { reply = text }
            }
        }
        guard reply != existing || done else { return }
        items[index] = .opinion(id: id, agent: agent,
                                text: reply.isEmpty && done ? "No answer came back." : reply,
                                done: done)
    }

    /// Called when the session comes on screen.
    func prepare() {
        adapter.prepare()
        let account = account
        Task { @MainActor in UsageStore.shared.refresh(account) }
    }

    func interrupt() {
        clearQueue()
        adapter.interrupt()
    }
    func shutdown() { adapter.interrupt() }

    // MARK: Streaming sinks, called on the main queue by the adapter

    func beginAssistant() {
        // Only open a new block if the last item isn't already an open one, so
        // deltas arriving after a tool call continue the same paragraph rather
        // than fragmenting into a block per chunk.
        if case .assistant = items.last { return }
        items.append(.assistant(id: UUID(), text: ""))
    }

    func appendAssistant(_ delta: String) {
        closeThinking()
        beginAssistant()
        guard case .assistant(let id, let existing) = items.last else { return }
        items[items.count - 1] = .assistant(id: id, text: existing + delta)
    }

    func appendThinking(_ delta: String) {
        if case .thinking(let id, let existing, let started, nil) = items.last {
            items[items.count - 1] = .thinking(
                id: id, text: existing + delta, started: started, finished: nil)
        } else {
            items.append(.thinking(id: UUID(), text: delta, started: Date(), finished: nil))
        }
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
        var text = ""
        for item in items.reversed() {
            if case .user = item { break }
            if case .assistant(_, let reply) = item { text = reply + "\n" + text }
        }
        guard !text.isEmpty else { return }
        noticeDevServer(in: text)
    }

    /// Watch command output for a dev server announcing itself.
    ///
    /// Vite, Next, Rails, Python's http.server — they all print the URL, and
    /// that output already passes through here on its way to a tool card. So
    /// the preview needs no new plumbing, just noticing.
    func noticeDevServer(in output: String) {
        guard let url = DevServer.find(in: output) else { return }
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
    func resolve(toolUseID: String, state: ToolState) {
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
        case .search(let uuid, let id, let query, _, _):
            items[index] = .search(id: uuid, toolUseID: id, query: query,
                                   results: SearchResult.scrape(state.message ?? ""),
                                   state: state)
        default:
            break
        }
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
    @Published private(set) var sessions: [Session] = []
    @Published var selection: Session.ID? {
        didSet {
            UserDefaults.standard.set(selection?.uuidString, forKey: Self.selectionKey)
            // Landing on a session clears its unread mark — you've seen it.
            if let selected { selected.needsAttention = false }
        }
    }
    @Published var collapsed: Set<Account> = [] {
        didSet {
            UserDefaults.standard.set(collapsed.map(\.rawValue), forKey: Self.collapsedKey)
        }
    }
    /// The session awaiting a delete confirmation. Lives here rather than in a
    /// view so the sidebar's ⋯ menu and the menu bar's ⌘⌫ can both raise the
    /// same dialog.
    @Published var pendingDeletion: Session?

    private static let storeKey = "bench.sessions.v1"
    private static let selectionKey = "bench.selection"
    private static let collapsedKey = "bench.collapsed"

    init() {
        // Whichever store is built first pulls the old app's data across. It
        // can't live in `BenchApp.init` — stored-property initialisers, which
        // is what `@StateObject` is, run *before* the enclosing type's `init`
        // body, so the stores had already read empty defaults by then.
        Migration.run()

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
                    effort: $0.effort ?? .high)
        }
        sessions.forEach(adopt)

        // Reopen where you left off. Falls back to the first session if that
        // one has since been deleted.
        let remembered = UserDefaults.standard.string(forKey: Self.selectionKey)
            .flatMap(UUID.init(uuidString:))
        selection = sessions.contains { $0.id == remembered } ? remembered : sessions.first?.id
        collapsed = Set((UserDefaults.standard.stringArray(forKey: Self.collapsedKey) ?? [])
            .compactMap(Account.init(rawValue:)))

        // A roster written before ids existed gets fresh ones; write them back
        // now so the next launch can find the transcripts this one creates.
        if stored.contains(where: { $0.id == nil }) { save() }
        SessionStore.prune(keeping: Set(sessions.map(\.id)))

        // The last turn of the session is the one most likely to be lost, so
        // catch the quit rather than relying on each turn's own save.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.sessions.forEach { $0.persist() }
            self?.save()
        }

        // Clicking a notification jumps to the session that finished.
        NotificationCenter.default.addObserver(
            forName: Notifier.activated, object: nil, queue: .main
        ) { [weak self] note in
            guard let id = note.userInfo?[Notifier.sessionKey] as? UUID else { return }
            self?.selection = id
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
            let watching = NSApp.isActive && self.selection == finished.id
            guard !watching else { return }
            Notifier.post(sessionID: finished.id,
                          title: "\(finished.account.title) · \(finished.name)",
                          body: finished.lastReply)
        }
    }

    func sessions(in account: Account) -> [Session] {
        sessions.filter { $0.account == account }
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

    /// A scratch session for a one-off — a handoff, a second opinion.
    @discardableResult
    func addEphemeral(account: Account, directory: URL, name: String,
                      modelID: String?, effort: EffortChoice) -> Session {
        let taken = sessions(in: account).map(\.name)
        var unique = name
        var n = 2
        while taken.contains(unique) { unique = "\(name) \(n)"; n += 1 }

        let session = Session(account: account, directory: directory, name: unique,
                              modelID: modelID, effort: effort)
        session.isEphemeral = true
        adopt(session)
        sessions.append(session)
        selection = session.id
        return session
    }

    func remove(_ session: Session) {
        session.shutdown()
        SessionStore.remove(session.id)
        sessions.removeAll { $0.id == session.id }
        if selection == session.id { selection = sessions.first?.id }
        save()
    }

    func rename(_ session: Session, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        session.name = trimmed
        save()
    }

    func toggle(_ account: Account) {
        setCollapsed(account, !collapsed.contains(account))
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

    private var lastVisited: [Account: Session.ID] {
        var map: [Account: Session.ID] = [:]
        for session in sessions where map[session.account] == nil {
            map[session.account] = session.id
        }
        return map
    }

    // MARK: Persistence

    func save() {
        let data = try? JSONEncoder().encode(
            sessions.filter { !$0.isEphemeral }.map(\.descriptor))
        UserDefaults.standard.set(data, forKey: Self.storeKey)
    }

    private static func load() -> [SessionDescriptor] {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
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
