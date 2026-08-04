import SwiftUI
import Combine

// MARK: - What an agent is

/// When an agent runs.
///
/// `watching` is here rather than being left to `every` because the two answer
/// different questions. A clock asks "has half an hour passed"; a file asks "has
/// anything changed" — and for the case this feature was built for, a to-do list
/// you tick by hand, the second one runs when there's work and stays quiet the
/// other forty-seven times a day.
enum AgentSchedule: Codable, Equatable, Hashable {
    case manual
    case every(minutes: Int)
    case daily(hour: Int, minute: Int)
    /// Absolute path. Relative to what, otherwise — the agent's folder moves.
    case watching(path: String)

    var isManual: Bool { self == .manual }

    /// The one-line answer for a sidebar row: short enough for the 240pt column.
    var shortTitle: String {
        switch self {
        case .manual: return ""
        case .every(let minutes):
            return minutes % 60 == 0 && minutes >= 60 ? "\(minutes / 60)h" : "\(minutes)m"
        case .daily(let hour, let minute):
            return String(format: "%02d:%02d", hour, minute)
        case .watching: return "file"
        }
    }

    var title: String {
        switch self {
        case .manual: return "Only when you ask"
        case .every(let minutes):
            return minutes % 60 == 0 && minutes >= 60
                ? "Every \(minutes / 60) hour\(minutes == 60 ? "" : "s")"
                : "Every \(minutes) minutes"
        case .daily(let hour, let minute):
            return String(format: "Daily at %02d:%02d", hour, minute)
        case .watching(let path):
            return "When \((path as NSString).lastPathComponent) changes"
        }
    }

    /// Which section of the Agents list this belongs in.
    var section: String {
        switch self {
        case .manual:   return "Manual"
        case .watching: return "Watching"
        default:        return "Scheduled"
        }
    }
}

/// How much an unattended run is allowed to do.
///
/// Worth being plain about what this is and isn't. `Act` is exactly as powerful
/// as sitting in the session and approving everything, in a folder you named,
/// with nobody watching. `Propose` is an *instruction*, not a sandbox — it's a
/// paragraph telling the agent not to write anything, and an agent that ignores
/// it is not stopped by anything in this app.
///
/// The real fence is `isolated`, which is a launch argument and does hold. That
/// is why new agents get it switched on and why the two controls sit together.
enum Autonomy: String, Codable, CaseIterable, Identifiable {
    case propose, act

    var id: String { rawValue }

    var title: String { self == .propose ? "Propose" : "Act" }

    var blurb: String {
        switch self {
        case .propose: return "Reads and reports back. Told not to edit, commit or push."
        case .act:     return "Full tool access, unattended."
        }
    }
}

/// A saved prompt, an account to run it under, and a clock.
struct AgentDefinition: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var name: String
    /// Which credentials and which CLI. The highest-stakes field here — an
    /// agent running unattended on the enterprise account is a different
    /// proposition from one on a personal subscription, and the app should
    /// never be picking that for you.
    var account: Account
    var path: String
    var prompt: String
    var schedule: AgentSchedule = .manual
    var autonomy: Autonomy = .propose
    var isolated: Bool = true
    var isEnabled: Bool = true
    var modelID: String?
    var effort: EffortChoice = .high
    /// Set when a run *starts*, not when it finishes. That's what makes
    /// catch-up fire once rather than once per missed interval.
    var lastRunAt: Date?

    var directory: URL { URL(fileURLWithPath: path) }

    /// The path, tidied the way a session's subtitle is.
    var subtitle: String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    /// What actually goes down the pipe.
    ///
    /// Propose mode is this paragraph and nothing else — see `Autonomy`.
    var dispatchable: String {
        switch autonomy {
        case .act:
            return prompt
        case .propose:
            return """
            You are running unattended, with nobody to ask. Do not create, edit \
            or delete any file, do not run any command that changes state, and \
            do not commit, push or open a pull request. Read whatever you need, \
            then finish with a short report of what you would change and why.

            \(prompt)
            """
        }
    }

    static func blank(account: Account, path: String) -> AgentDefinition {
        AgentDefinition(name: "New agent", account: account, path: path, prompt: "")
    }
}

// MARK: - The roster and the clock

/// Every agent, and the one timer that fires them.
///
/// One shared ticker rather than a timer per agent. Twenty timers each drifting
/// on their own tolerance is a worse way to answer "is anything due" than
/// asking every thirty seconds, and it makes catch-up after a relaunch a single
/// code path instead of twenty racing ones.
///
/// There is no daemon. Agents run while Honeycode is open and not while your Mac
/// is asleep, which is stated in the UI rather than quietly worked around — the
/// alternative is an app that keeps a laptop awake to check a to-do list.
@MainActor
final class AgentStore: ObservableObject {

    @Published private(set) var agents: [AgentDefinition] = []
    /// Which agent's detail pane is showing.
    @Published var selection: AgentDefinition.ID?
    /// Which of its runs is open, if any. Deliberately separate from
    /// `Workspace.selection`: flipping to Agents and back must not disturb the
    /// columns you arranged in Code.
    @Published var openRun: Session.ID?
    /// The interview in progress, if you're making one.
    @Published private(set) var setup: Session?
    /// What the interview has worked out so far.
    @Published private(set) var draft: AgentDefinition?

    /// One switch for all of them, for the first time one misbehaves.
    @Published var paused = false {
        didSet { UserDefaults.standard.set(paused, forKey: Self.pausedKey) }
    }

    /// Runs in flight, by agent. Also the overlap guard.
    @Published private(set) var running: [AgentDefinition.ID: Session.ID] = [:]

    /// Runs kept per agent. Older ones are deleted with their transcripts —
    /// half-hourly for a week is 336 files, and none of them is worth keeping.
    static let runsKept = 20

    private weak var workspace: Workspace?
    private var ticker: Timer?
    private var watches: [AgentDefinition.ID: FileWatch] = [:]
    private var setupFeed: AnyCancellable?

    private static let pausedKey = "honeycode.agents.paused"
    private static var file: URL { Support.folder.appendingPathComponent("Agents.json") }

    init() {
        paused = UserDefaults.standard.bool(forKey: Self.pausedKey)
        load()
    }

    /// Handed the roster once the app has one, and started.
    func attach(to workspace: Workspace) {
        self.workspace = workspace
        selection = selection ?? agents.first?.id
        rewatch()
        // On the common run loop mode, so it keeps ticking while a menu is open
        // — the same reason `FileWatch` does it.
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
        tick()
    }

    // MARK: Roster

    func agent(_ id: AgentDefinition.ID?) -> AgentDefinition? {
        guard let id else { return nil }
        return agents.first { $0.id == id }
    }

    /// Sections, in the order the sidebar shows them.
    var sections: [(String, [AgentDefinition])] {
        let order = ["Scheduled", "Watching", "Manual"]
        var enabled: [String: [AgentDefinition]] = [:]
        var paused: [AgentDefinition] = []
        for agent in agents {
            if agent.isEnabled { enabled[agent.schedule.section, default: []].append(agent) }
            else { paused.append(agent) }
        }
        var out = order.compactMap { key in enabled[key].map { (key, $0) } }
        if !paused.isEmpty { out.append(("Paused", paused)) }
        return out
    }

    func update(_ agent: AgentDefinition) {
        guard let index = agents.firstIndex(where: { $0.id == agent.id }) else { return }
        var next = agent
        // The clock's field, not the editor's. The detail pane holds a copy
        // taken when it opened and writes it back as you type — so a run that
        // started while the pane was open would have its stamp rolled back by
        // the next keystroke, and the agent would fire again immediately.
        next.lastRunAt = agents[index].lastRunAt
        guard agents[index] != next else { return }
        agents[index] = next
        save()
        rewatch()
    }

    func add(_ agent: AgentDefinition) {
        agents.append(agent)
        selection = agent.id
        save()
        rewatch()
    }

    /// Delete an agent and every transcript it ever wrote.
    func remove(_ id: AgentDefinition.ID) {
        for run in workspace?.runs(of: id) ?? [] { workspace?.remove(run) }
        agents.removeAll { $0.id == id }
        watches[id]?.stop()
        watches[id] = nil
        running[id] = nil
        if selection == id { selection = agents.first?.id }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.file),
              let list = try? JSONDecoder().decode([AgentDefinition].self, from: data)
        else { return }
        agents = list
    }

    /// A file rather than `UserDefaults`.
    ///
    /// The prompt is multi-line prose that you'll want to read, diff and paste
    /// elsewhere, and the session roster's own comment is a standing warning
    /// about what a defaults key costs you the day you want to rename it.
    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(agents) else { return }
        try? data.write(to: Self.file, options: .atomic)
    }

    // MARK: The clock

    private func tick() {
        guard !paused, workspace != nil else { return }
        let now = Date()
        for agent in agents where agent.isEnabled && due(agent, at: now) {
            run(agent, at: now)
        }
    }

    /// Whether this agent's next fire is in the past.
    ///
    /// A `watching` agent is never due here — its `FileWatch` fires it — and a
    /// `manual` one never is at all.
    private func due(_ agent: AgentDefinition, at now: Date) -> Bool {
        switch agent.schedule {
        case .manual, .watching:
            return false

        case .every(let minutes):
            guard let last = agent.lastRunAt else { return true }
            return now.timeIntervalSince(last) >= Double(max(1, minutes)) * 60

        case .daily(let hour, let minute):
            // The most recent time today's clock passed h:m — yesterday's if it
            // hasn't yet. Due when that moment is after the last run, which
            // fires once for a week of missed mornings rather than seven times.
            var components = Calendar.current.dateComponents([.year, .month, .day], from: now)
            components.hour = hour
            components.minute = minute
            guard var slot = Calendar.current.date(from: components) else { return false }
            if slot > now {
                guard let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: slot)
                else { return false }
                slot = yesterday
            }
            return (agent.lastRunAt ?? .distantPast) < slot
        }
    }

    /// One `FileWatch` per watching agent, rebuilt whenever the roster changes.
    private func rewatch() {
        let wanted = Dictionary(
            agents.filter { $0.isEnabled }.compactMap { agent -> (AgentDefinition.ID, String)? in
                guard case .watching(let path) = agent.schedule else { return nil }
                return (agent.id, path)
            }, uniquingKeysWith: { first, _ in first })

        for (id, watch) in watches where wanted[id] == nil {
            watch.stop()
            watches[id] = nil
        }
        for (id, path) in wanted {
            let watch = watches[id] ?? FileWatch()
            watches[id] = watch
            // `watch` is a no-op when handed the url it already has, so this is
            // safe to call on every roster change.
            watch.watch(URL(fileURLWithPath: path)) { [weak self] in
                guard let self, !self.paused, let agent = self.agent(id) else { return }
                self.run(agent, at: Date(), trigger: .file)
            }
        }
    }

    // MARK: Running

    /// Why a run happened, for the line at the top of its transcript.
    enum Trigger: Equatable { case schedule, file, hand }

    @discardableResult
    func run(_ agent: AgentDefinition, at now: Date = Date(),
             trigger: Trigger? = nil) -> Session? {
        guard let workspace else { return nil }
        // An agent whose last run is still going does not start another. A
        // 30-minute schedule and a 40-minute run would otherwise stack
        // processes until the Mac gave up.
        guard running[agent.id] == nil else {
            note(agent, "Skipped — the previous run hadn't finished.", at: now)
            return nil
        }

        let why = trigger ?? (agent.schedule.isManual ? .hand : .schedule)
        let run = Session(account: agent.account, directory: agent.directory,
                          name: "\(agent.name) · \(Self.stamp(now))",
                          modelID: agent.modelID, effort: agent.effort,
                          isolated: agent.isolated,
                          origin: .agent(agent.id), startedAt: now)
        workspace.add(run: run)

        // Chained rather than replaced: `Workspace.add(run:)` installs the
        // notification handler, and a run finishing is exactly the thing worth
        // being told about.
        let notify = run.onTurnComplete
        run.onTurnComplete = { [weak self] finished in
            notify?(finished)
            Task { @MainActor in self?.finished(agent.id) }
        }

        run.append(.notice(id: UUID(), text: Self.opening(agent, why: why)))
        run.send(agent.dispatchable)

        running[agent.id] = run.id
        stamp(agent.id, ranAt: now)
        prune(agent.id)
        return run
    }

    /// Stop a run without deleting it. Its transcript is the record of how far
    /// it got, which is worth keeping.
    func stop(_ agent: AgentDefinition.ID) {
        guard let id = running[agent],
              let session = workspace?.sessions.first(where: { $0.id == id }) else { return }
        session.interrupt()
        running[agent] = nil
    }

    private func finished(_ agent: AgentDefinition.ID) {
        running[agent] = nil
    }

    private func stamp(_ id: AgentDefinition.ID, ranAt: Date) {
        guard let index = agents.firstIndex(where: { $0.id == id }) else { return }
        agents[index].lastRunAt = ranAt
        save()
    }

    /// A run that never started, recorded as one line so the history doesn't
    /// silently skip a slot.
    private func note(_ agent: AgentDefinition, _ text: String, at now: Date) {
        guard let workspace else { return }
        let run = Session(account: agent.account, directory: agent.directory,
                          name: "\(agent.name) · \(Self.stamp(now))",
                          origin: .agent(agent.id), startedAt: now)
        workspace.add(run: run)
        run.hydrate()
        run.append(.notice(id: UUID(), text: text))
        run.persist()
        prune(agent.id)
    }

    /// Keep the last `runsKept`, transcripts and all.
    private func prune(_ id: AgentDefinition.ID) {
        guard let workspace else { return }
        let runs = workspace.runs(of: id)
        guard runs.count > Self.runsKept else { return }
        for old in runs.dropFirst(Self.runsKept) where old.id != running[id] {
            workspace.remove(old)
        }
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// The line at the top of a run, saying who started it and under what.
    private static func opening(_ agent: AgentDefinition, why: Trigger) -> String {
        let cause = why == .hand ? "run by hand" : agent.schedule.title.lowercased()
        let fence = agent.autonomy == .act
            ? "full tool access" : "propose only — told not to write anything"
        return "\(agent.name) — \(cause), \(fence)"
            + (agent.isolated ? ", confined to \(agent.subtitle)." : ".")
    }
}

// MARK: - Making one by talking

/// The interview.
///
/// A form with nine fields is exactly the friction that stops you making the
/// second agent, so the `+` opens a conversation instead. One sentence produces
/// a complete draft — the assistant is handed your session roster, so "the
/// honeycode todos" resolves to a folder and an account without being asked —
/// and you correct it in words.
///
/// It runs on an account you pick, not on the agent's: switching the
/// interviewer mid-sentence because you changed your mind about who should run
/// the finished agent would throw the conversation away.
extension AgentStore {

    /// Everything after this marker in a reply is the draft, not prose.
    ///
    /// A fenced block rather than a tool call, because it has to work across
    /// three different CLIs and two wire protocols — a fence is the one thing
    /// all of them can be relied on to emit. It's stripped from the transcript
    /// when the turn lands, so you never see it.
    static let draftFence = "honeycode-agent"

    func beginSetup(account: Account, near workspace: Workspace) {
        endSetup()
        let session = Session(account: account,
                              directory: URL(fileURLWithPath: NSHomeDirectory()),
                              name: "New agent", origin: .setup)
        session.isEphemeral = true
        session.briefing = briefing(for: workspace)
        setup = session
        draft = nil
        selection = nil

        // Same throttle and the same reasoning as `Session.askOpinion`'s
        // mirror: this fires twice per streamed token, and the work it does is
        // a scan of the whole reply.
        setupFeed = session.objectWillChange
            .throttle(for: .milliseconds(150), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] in self?.readDraft() }
    }

    func endSetup() {
        setupFeed = nil
        setup?.retire()
        setup = nil
        draft = nil
    }

    /// Take the draft as it stands and make it real.
    func acceptDraft() {
        guard var agent = draft else { return }
        agent.id = UUID()
        endSetup()
        add(agent)
    }

    /// Pull the fenced block out of the latest reply, and take it out of the
    /// transcript so the conversation reads as prose.
    private func readDraft() {
        guard let session = setup else { return }
        guard let index = session.items.lastIndex(where: {
            if case .assistant = $0 { return true }
            return false
        }), case .assistant(let id, let text) = session.items[index] else { return }

        guard let (prose, json) = Self.split(text) else { return }
        if let parsed = Self.parse(json, fallback: draft) { draft = parsed }
        // Only once the turn has landed. Rewriting mid-stream would fight the
        // deltas still arriving into the same item.
        if !session.isRunning, prose != text {
            session.items[index] = .assistant(id: id, text: prose)
        }
    }

    /// Prose before the fence, JSON inside it.
    static func split(_ text: String) -> (String, String)? {
        guard let open = text.range(of: "```\(draftFence)") else { return nil }
        let rest = text[open.upperBound...]
        let close = rest.range(of: "```")
        let json = String(close.map { rest[..<$0.lowerBound] } ?? rest)
        let after = close.map { String(rest[$0.upperBound...]) } ?? ""
        let prose = (String(text[..<open.lowerBound]) + after)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (prose, json)
    }

    /// The wire shape. Deliberately flat and forgiving — a model that omits a
    /// field should leave the previous answer standing rather than blank it.
    private struct Wire: Codable {
        var name: String?
        var account: String?
        var path: String?
        var prompt: String?
        var schedule: String?
        var minutes: Int?
        var time: String?
        var watch: String?
        var autonomy: String?
        var isolated: Bool?
    }

    static func parse(_ json: String, fallback: AgentDefinition?) -> AgentDefinition? {
        guard let data = json.data(using: .utf8),
              let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return nil }

        let path = wire.path.map { ($0 as NSString).expandingTildeInPath }
            ?? fallback?.path
        guard let path, !path.isEmpty else { return nil }

        let schedule: AgentSchedule
        switch wire.schedule {
        case "every":
            schedule = .every(minutes: max(1, wire.minutes ?? 30))
        case "daily":
            let parts = (wire.time ?? "09:00").split(separator: ":").compactMap { Int($0) }
            schedule = .daily(hour: parts.first ?? 9, minute: parts.count > 1 ? parts[1] : 0)
        case "watching":
            let file = ((wire.watch ?? "") as NSString).expandingTildeInPath
            schedule = file.isEmpty ? .manual : .watching(path: file)
        case "manual":
            schedule = .manual
        default:
            schedule = fallback?.schedule ?? .manual
        }

        var agent = AgentDefinition(
            id: fallback?.id ?? UUID(),
            name: wire.name ?? fallback?.name ?? "New agent",
            account: wire.account.flatMap(Account.init(rawValue:))
                ?? fallback?.account ?? .personal,
            path: path,
            prompt: wire.prompt ?? fallback?.prompt ?? "",
            schedule: schedule,
            autonomy: wire.autonomy.flatMap(Autonomy.init(rawValue:))
                ?? fallback?.autonomy ?? .propose,
            isolated: wire.isolated ?? fallback?.isolated ?? true)
        agent.effort = fallback?.effort ?? .high
        return agent
    }

    /// What the interviewer is told before your first message.
    ///
    /// The roster goes in because it turns "the honeycode todos" into a folder
    /// and an account without a round trip — the difference between one
    /// sentence and four.
    private func briefing(for workspace: Workspace) -> String {
        let known = Account.allCases.flatMap { account in
            workspace.sessions(in: account).map { session in
                "- \(session.name) — \(account.rawValue) — \(session.directory.path)"
            }
        }.joined(separator: "\n")

        return """
        [Honeycode: you are setting up a scheduled agent, not doing the work \
        itself. The person will describe what they want in a sentence. Reply \
        with two or three lines of prose — what you've assumed, and at most one \
        question, asked only if the answer would change what the agent does. \
        Never ask about anything you can reasonably infer.

        Then end every reply with a fenced block, exactly:

        ```\(Self.draftFence)
        {"name":"…","account":"personal|work|kimi|copilot","path":"/absolute/path",
         "prompt":"the instruction the agent runs, written as an instruction to \
        an agent, not a description of one","schedule":"manual|every|daily|watching",
         "minutes":30,"time":"09:00","watch":"/absolute/path/to/file",
         "autonomy":"propose|act","isolated":true}
        ```

        Include the whole object every time, carrying forward anything that \
        hasn't changed. Default `autonomy` to "propose" and `isolated` to true, \
        and only change them if asked — an agent runs unattended, so acting is \
        a decision the person makes, not one you make for them.

        These are the folders they already work in; match names against them \
        rather than guessing a path:
        \(known.isEmpty ? "- (none yet)" : known)]
        """
    }
}
