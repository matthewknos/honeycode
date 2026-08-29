import Foundation
import Combine

// MARK: - One allowance

/// A limit somebody is spending against, and how far through it they are.
///
/// This used to be two fields — `sessionPercent` and `weekPercent` — which is
/// Claude's shape written into the type. It was already wrong for the other
/// three: Copilot bills in premium requests against a monthly count, Kimi
/// reports no allowance at all, and a usage-based enterprise seat has a figure
/// in a contract and nothing the CLI can see. So a window carries its own name,
/// and an account has however many of them it has.
///
/// `percent` is the whole point and is never optional. A window nothing can put
/// a number on is not a window; it is a line of prose, and prose does not go on
/// a ring — an account whose answer carries no number reports no window at all,
/// which is what `AccountUsage.read` returning nil means.
struct UsageWindow: Equatable, Sendable, Codable, Identifiable {
    /// As the agent worded it — "Current session", "Premium requests".
    let title: String
    let percent: Int
    /// When the allowance comes back, as the agent worded that too. Left as
    /// text deliberately: "resets in 51 min" and "resets Aug 1 at 3:59pm" are
    /// both answers, and parsing them into a `Date` to print them back out
    /// again would be work done to lose information.
    var resets: String?
    /// The count behind the percentage, where the agent gave one — "123 of
    /// 300". Shown in the popover, never on the ring.
    var detail: String?

    var id: String { title }

    /// The ring's caption: one word, lowercase.
    ///
    /// A ring is 44 points across and sits under a number. "Current week (all
    /// models)" is a paragraph at that size, and the popover is where the full
    /// wording belongs.
    var short: String {
        let lowered = title.lowercased()
        for word in ["session", "week", "month", "day", "premium", "credit"]
        where lowered.contains(word) {
            return word
        }
        return lowered.split(separator: " ").first.map(String.init) ?? lowered
    }

    var pressure: UsagePressure { UsagePressure.of(percent) }
}

/// How worried to look about a percentage.
///
/// Three bands rather than the single `>= 90` test the readouts used, because
/// 90 is not a warning — at ninety per cent of a five-hour window the decision
/// it would have informed (give this piece to a different subscription) is
/// already behind you. The thresholds are where a *choice* is still available:
/// below 40 nothing about this seat should change what you do, and past 70 a
/// crew of four should be routed around it.
enum UsagePressure: String, Sendable, Codable, CaseIterable {
    case easy, tight, critical

    static func of(_ percent: Int) -> UsagePressure {
        switch percent {
        case ..<40: return .easy
        case ..<70: return .tight
        default:    return .critical
        }
    }

    /// Whether this is the one to say out loud.
    var isAlarming: Bool { self == .critical }
}

// MARK: - What an account has left

/// Every allowance one subscription is spending against.
///
/// Carries where the figure came from, which the old shape could not say and
/// which changes how much it is worth. A percentage the agent reported is a
/// fact about your plan; one computed from what this app has spent against a
/// cap you typed in is an estimate that ignores every turn you ran in a
/// terminal. Drawing them identically and never saying which is which is how a
/// gauge gets trusted for something it cannot do.
struct AccountUsage: Equatable, Sendable, Codable {
    var windows: [UsageWindow] = []
    /// When this reading was taken. A rail that is on screen all day has to be
    /// able to say "as of 11:04" rather than implying it is live.
    var measuredAt = Date()
    var source: Source = .reported

    enum Source: String, Sendable, Codable {
        /// The agent's own answer to `/usage`.
        case reported
        /// Computed here, from what Honeycode has spent against a cap.
        case measured

        var blurb: String {
            switch self {
            case .reported: return "Reported by the agent"
            case .measured: return "Counts turns run in Honeycode only"
            }
        }
    }

    /// The window closest to biting. A 5-hour window at 34% next to a weekly at
    /// 69% means the week is the thing that will actually stop you.
    var binding: UsageWindow? { windows.max { $0.percent < $1.percent } }

    var summary: String {
        var parts = windows.map { window -> String in
            var line = "\(window.title) \(window.percent)% used"
            if let detail = window.detail { line += " (\(detail))" }
            if let resets = window.resets { line += ", resets \(resets)" }
            return line
        }
        if parts.isEmpty { return "No usage limits reported for this account" }
        parts.append(source.blurb)
        return parts.joined(separator: "\n")
    }

    // MARK: Reading one

    /// Pull every allowance out of an agent's answer to `/usage`.
    ///
    /// One parser for every vendor, which is the point. The old one knew two
    /// Claude sentences by heart and nothing else, so Copilot's answer — which
    /// the ACP adapter has been fetching after every turn since it was written
    /// — was parsed for its credit count and otherwise thrown away.
    ///
    /// Two shapes, because between them they cover what the four CLIs actually
    /// print:
    ///
    ///     Current session: 34% used · resets Jul 31 at 4:59pm (Europe/Dublin)
    ///     Premium requests: 123 of 300 used
    ///
    /// Returns `nil` when neither is present anywhere in the text. That is not
    /// a parse failure: an enterprise usage-based seat genuinely has no
    /// percentage to report, and writing zeroes for it would invent a limit
    /// that does not exist and draw a reassuring empty ring for it.
    static func read(_ raw: String, at moment: Date = Date()) -> AccountUsage? {
        let text = plain(raw)
        var windows: [UsageWindow] = []
        var seen: Set<String> = []

        func keep(_ window: UsageWindow) {
            guard seen.insert(window.title.lowercased()).inserted else { return }
            windows.append(window)
        }

        for window in stated(in: text) { keep(window) }
        for window in counted(in: text) { keep(window) }

        guard !windows.isEmpty else { return nil }
        return AccountUsage(windows: windows, measuredAt: moment, source: .reported)
    }

    /// `Current session: 34% used · resets …`
    ///
    /// The label may start with a digit — `5h limit:` is a real line from a
    /// real status command, and an `[A-Za-z]` anchor silently skipped it. That
    /// is the shape of every bug this parser can have: it does not throw, it
    /// returns one fewer window, and a missing window is indistinguishable from
    /// a plan with no limit.
    private static func stated(in text: String) -> [UsageWindow] {
        matches(#"^[\s\-•*]*([A-Za-z0-9][^:\n]{1,48}?)\s*:\s*(\d{1,3})\s*%\s*used\b[^\n]*"#,
                in: text).compactMap { match in
            guard let title = match.group(1, in: text),
                  let percent = match.group(2, in: text).flatMap(Int.init)
            else { return nil }
            return UsageWindow(title: tidy(title),
                               percent: min(percent, 100),
                               resets: resets(in: match.line(in: text)))
        }
    }

    /// `Premium requests: 123 of 300`, and `123/300` for the same thing.
    private static func counted(in text: String) -> [UsageWindow] {
        matches(#"^[\s\-•*]*([A-Za-z0-9][^:\n]{1,48}?)\s*:\s*([\d,]+)\s*(?:of|/)\s*([\d,]+)[^\n]*"#,
                in: text).compactMap { match in
            guard let title = match.group(1, in: text),
                  let used = match.group(2, in: text).flatMap(number),
                  let limit = match.group(3, in: text).flatMap(number),
                  limit > 0 else { return nil }
            let percent = Int((used / limit * 100).rounded())
            return UsageWindow(title: tidy(title),
                               percent: min(percent, 100),
                               resets: resets(in: match.line(in: text)),
                               detail: "\(trim(used)) of \(trim(limit))")
        }
    }

    /// The tail of a line, from "resets" onwards.
    ///
    /// The parenthesised timezone goes: the time is already local, and
    /// "(Europe/Dublin)" is a lot of pixels to spend restating that.
    private static func resets(in line: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"resets\s+([^\n]+)"#,
                                                   options: [.caseInsensitive]),
              let match = regex.firstMatch(
                in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        let text = line[range].components(separatedBy: " (").first ?? String(line[range])
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// "Current week (all models)" survives; a stray bullet or bold marker
    /// doesn't.
    private static func tidy(_ title: String) -> String {
        title.trimmingCharacters(in: CharacterSet(charactersIn: " \t*_-•·"))
    }

    /// The same text with the terminal's colouring taken out.
    ///
    /// Every probe here is a command-line tool answering a question it normally
    /// answers to a human, and a tool that draws its limits as a green bar
    /// writes `\u{1B}[32m21%\u{1B}[0m` — where the digits are still there and
    /// the line no longer starts where the regex thinks it does. `Shell.run`
    /// sets `NO_COLOR`, which most tools honour and some ignore; this is for
    /// the ones that ignore it, and costs one pass over a few hundred
    /// characters.
    static func plain(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        guard let regex = try? NSRegularExpression(
                pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]") else { return text }
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    private static func number(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: ""))
    }

    private static func trim(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }

    private static func matches(_ pattern: String, in text: String)
        -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.anchorsMatchLines, .caseInsensitive]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }
}

private extension NSTextCheckingResult {
    func group(_ index: Int, in text: String) -> String? {
        guard index < numberOfRanges,
              let range = Range(range(at: index), in: text) else { return nil }
        return String(text[range])
    }

    /// The whole matched line, for the second pass over it that finds "resets".
    func line(in text: String) -> String {
        guard let range = Range(self.range, in: text) else { return "" }
        return String(text[range])
    }
}

// MARK: - The store

/// What every subscription has left, in one place.
///
/// Three sources, and the order is the order of authority:
///
/// 1. **What the agent says.** Claude answers `/usage` with two percentages;
///    Copilot answers with its premium-request count. Both are facts about the
///    plan. Claude's arrives from a throwaway process spawned here — the CLI
///    handles `/usage` locally, returns in a few hundred milliseconds and
///    reports `total_cost_usd: 0`, so it can be polled without spending
///    anything — and the ACP agents' arrives from `ACPAdapter`, which has been
///    asking after every turn since it was written.
/// 2. **What this app has spent**, against a cap. Every account has one now,
///    rather than one global figure standing in for four subscriptions that
///    bill nothing like each other.
/// 3. **Nothing**, said as nothing. An account with no reported allowance and
///    no cap draws no ring rather than a comforting empty one.
@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    @Published private(set) var usage: [Account: AccountUsage] = [:]
    /// Spend this calendar month, per account, in dollars.
    @Published private(set) var monthlySpend: [Account: Double] = [:]

    /// The cap an account is measured against when nothing reports a
    /// percentage, and the default for one that has no cap of its own.
    ///
    /// Read straight from defaults rather than through `@AppStorage`, which is
    /// SwiftUI and so can't be here. No loss: the field that *writes* this key
    /// lives in `CrewSettings` and keeps its wrapper, and this side only ever
    /// read it.
    var monthlyCap: Double {
        (Prefs.store.object(forKey: "usage.monthlyCap") as? Double) ?? 500
    }

    private var lastChecked: [Account: Date] = [:]
    private var inFlight: Set<Account> = []

    /// Frequent enough to move while you work, rare enough that a burst of
    /// finished turns doesn't spawn a process each.
    private static let minimumInterval: TimeInterval = 30

    init() {
        loadSpend()
        loadReadings()
    }

    // MARK: Per-account caps

    /// One cap per subscription, because they do not bill alike.
    ///
    /// A single `usage.monthlyCap` was applied to all four, which made the
    /// month gauge meaningless on three of them: $500 is a plausible ceiling
    /// for a usage-based enterprise seat and nonsense for a $20 subscription,
    /// so a Pro account showed 4% while sitting on top of its actual limit.
    /// The global figure survives as the default for an account nobody has set
    /// one for, so nothing that was configured stops working.
    private static func capKey(_ account: Account) -> String {
        "usage.cap.\(account.id)"
    }

    func cap(for account: Account) -> Double {
        let own = Prefs.store.object(forKey: Self.capKey(account)) as? Double
        return (own ?? 0) > 0 ? (own ?? 0) : monthlyCap
    }

    /// Zero clears it back to the shared default rather than storing a cap of
    /// nothing, which would divide by zero everywhere downstream.
    func setCap(_ amount: Double, for account: Account) {
        if amount > 0 {
            Prefs.store.set(amount, forKey: Self.capKey(account))
        } else {
            Prefs.store.removeObject(forKey: Self.capKey(account))
        }
        objectWillChange.send()
    }

    func hasOwnCap(_ account: Account) -> Bool {
        ((Prefs.store.object(forKey: Self.capKey(account)) as? Double) ?? 0) > 0
    }

    // MARK: Monthly spend

    /// Keyed by month so a new month starts from zero without any bookkeeping,
    /// and last month's figure is still on disk if it's ever wanted.
    private static let month: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }()

    private static var monthKey: String { month.string(from: Date()) }

    private static func spendKey(_ account: Account) -> String {
        "usage.spend.\(account.id).\(monthKey)"
    }

    /// Spend that happened outside Honeycode, typed in from the admin console.
    ///
    /// Without this the figure is only ever what this app has spent, which on a
    /// seat you also use from the terminal reads far too low — and a spend
    /// gauge that under-reports is worse than none, because it tells you you're
    /// fine right up until you aren't.
    private static func baselineKey(_ account: Account) -> String {
        "usage.baseline.\(account.id).\(monthKey)"
    }

    private func loadSpend() {
        for account in Account.allCases {
            let tracked = Prefs.store.double(forKey: Self.spendKey(account))
            let baseline = Prefs.store.double(forKey: Self.baselineKey(account))
            if tracked + baseline > 0 { monthlySpend[account] = tracked + baseline }
        }
    }

    func baseline(for account: Account) -> Double {
        Prefs.store.double(forKey: Self.baselineKey(account))
    }

    /// Set the known-true figure. Honeycode's own tally restarts from zero and
    /// accrues on top, so setting it twice can't double-count.
    func setBaseline(_ amount: Double, for account: Account) {
        Prefs.store.set(amount, forKey: Self.baselineKey(account))
        Prefs.store.set(0.0, forKey: Self.spendKey(account))
        monthlySpend[account] = amount
    }

    /// Add a turn's cost. Comes from the CLI's own `total_cost_usd`, which is
    /// the authoritative figure — it already accounts for cache reads and
    /// writes being priced differently, which recomputing from token counts
    /// would have to get right by hand and would quietly get wrong.
    func record(cost: Double, for account: Account) {
        guard cost > 0 else { return }
        let tracked = Prefs.store.double(forKey: Self.spendKey(account)) + cost
        Prefs.store.set(tracked, forKey: Self.spendKey(account))
        monthlySpend[account] = tracked + baseline(for: account)
    }

    /// Percentage of this account's cap spent this month.
    func capUsage(_ account: Account) -> (percent: Int, spent: Double, cap: Double)? {
        let cap = cap(for: account)
        guard cap > 0 else { return nil }
        let spent = monthlySpend[account] ?? 0
        return (Int((spent / cap * 100).rounded()), spent, cap)
    }

    // MARK: What to draw

    /// The reading for this account, whatever it turned out to be — reported
    /// where the agent reports, measured where it doesn't, nil where there is
    /// nothing honest to draw.
    ///
    /// One function so the rail, the crew pane and the header cannot disagree
    /// about which of the three cases they are in. They previously each wrote
    /// their own ladder of `if let`s, in three different orders.
    func reading(for account: Account) -> AccountUsage? {
        if let reported = usage[account], !reported.windows.isEmpty { return reported }
        guard let cap = capUsage(account), cap.spent > 0 else { return nil }
        return AccountUsage(
            windows: [UsageWindow(title: "This month",
                                  percent: min(cap.percent, 100),
                                  resets: nil,
                                  detail: String(format: "$%.2f of $%.0f",
                                                 cap.spent, cap.cap))],
            source: .measured)
    }

    // MARK: Remembering the last reading

    /// So a rail that is on screen at launch has something in it.
    ///
    /// The readings were in memory only, which for a readout inside a session
    /// was survivable — you were about to run a turn, and a turn refreshes it.
    /// A panel whose whole job is to be glanceable cannot open empty and fill
    /// itself in a minute later; by then you have looked, seen nothing, and
    /// stopped looking. What is drawn from disk carries `measuredAt`, so it can
    /// say how old it is rather than pretending to be live.
    private static func readingKey(_ account: Account) -> String {
        "usage.reading.\(account.id)"
    }

    private func loadReadings() {
        for account in Account.allCases {
            guard let data = Prefs.store.data(forKey: Self.readingKey(account)),
                  let reading = try? JSONDecoder().decode(AccountUsage.self, from: data)
            else { continue }
            usage[account] = reading
        }
    }

    private func remember(_ reading: AccountUsage, for account: Account) {
        guard let data = try? JSONEncoder().encode(reading) else { return }
        Prefs.store.set(data, forKey: Self.readingKey(account))
    }

    /// Take a reading, from wherever it came from.
    ///
    /// The ACP adapter's route in. It already asks every agent `/usage` when a
    /// turn ends and parses the answer for a credit count; everything else in
    /// that reply — which for Copilot is the premium-request quota, the only
    /// account-wide allowance it publishes — was read and dropped.
    func ingest(_ text: String, for account: Account) {
        guard let reading = AccountUsage.read(text) else { return }
        usage[account] = reading
        remember(reading, for: account)
    }

    // MARK: How an account is asked

    /// What to run to ask this account what it has left.
    ///
    /// Claude is asked by spawning its own CLI with a `/usage` turn; the ACP
    /// agents answer over the wire they are already on. Everything else
    /// publishes its limits somewhere this app cannot guess — OpenAI's Codex
    /// being the one that prompted this — and guessing is worse than not
    /// guessing. A parser written against an invented format does not fail
    /// loudly; it matches nothing, and the rail draws a dash forever, which
    /// reads as "this plan has no limits" rather than as "nobody asked
    /// properly".
    ///
    /// So it is a setting: whatever prints the numbers goes here, and its
    /// output goes through the same parser as everything else. Any line of the
    /// form `<name>: <n>% used` or `<name>: <n> of <m>` becomes a window, so
    /// the bar for making a new agent work is finding its status command
    /// rather than writing any code.
    ///
    /// It runs on the same schedule as everything else — every 30 seconds at
    /// most while something is watching — so it has to be cheap and it has to
    /// be read-only. Both are on whoever sets it; this is a preference on your
    /// own machine, the same trust as `.honeycode-check`, and no more access
    /// than the agent CLI this app already launches for you.
    static func commandKey(_ account: Account) -> String {
        "usage.command.\(account.id)"
    }

    func usageCommand(for account: Account) -> String? {
        let stored = (Prefs.store.string(forKey: Self.commandKey(account)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stored.isEmpty ? nil : stored
    }

    func setUsageCommand(_ command: String?, for account: Account) {
        let trimmed = (command ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Prefs.store.removeObject(forKey: Self.commandKey(account))
        } else {
            Prefs.store.set(trimmed, forKey: Self.commandKey(account))
        }
        // The floor is there to stop a burst of turns spawning a process each.
        // Somebody who has just changed the command is not a burst, and making
        // them wait half a minute to find out whether it worked is how a
        // settings field gets abandoned.
        //
        // No `objectWillChange` here, unlike `setCap`: nothing on screen draws
        // the command except the field that owns it, and this is written on
        // every keystroke — publishing each one would redraw the rail and the
        // crew pane while somebody types a shell command.
        lastChecked[account] = nil
    }

    /// Which of the two ways this account can be asked, if either.
    ///
    /// A declared command wins. It is the more specific answer and the one
    /// somebody typed on purpose — including, for a Claude account, as a way
    /// to replace a probe that spawns 100MB of Node with something cheaper.
    private enum Probe: Sendable {
        case declared(String)
        case claude(configDir: String)
    }

    private func probe(for account: Account) -> Probe? {
        if let command = usageCommand(for: account) { return .declared(command) }
        if let directory = account.configDir { return .claude(configDir: directory) }
        return nil
    }

    /// Run one, and hand back exactly what it said.
    ///
    /// The raw text comes back as well as the parse, and that is the whole
    /// point of the shape: the settings field has a Test button, and "it
    /// printed this, and none of it looked like a limit" is the only answer
    /// that lets somebody fix their command. A bare "no" would send them
    /// looking for a bug in this app.
    nonisolated private static func answer(from probe: Probe) -> String {
        switch probe {
        case .declared(let command):
            let result = Shell.run("/bin/sh", ["-c", command], timeout: Self.patience)
            if result.timedOut { return "" }
            // Both streams: these tools disagree about which one a status
            // report belongs on, and the useful half is whichever isn't empty.
            return [result.out, result.err]
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .joined(separator: "\n")
        case .claude(let configDir):
            return run(configDir: configDir)
        }
    }

    /// Short, because this is polled. A status command that takes longer than
    /// this to say what your quota is has something else wrong with it, and
    /// `Verification.patience` — five minutes, sized for a typecheck — would
    /// leave a wedged probe holding a slot until the app quit.
    private static let patience: TimeInterval = 20

    /// Run a candidate command now and report what it produced, without
    /// storing anything. What the Test button calls.
    func test(_ command: String) async -> (output: String, reading: AccountUsage?) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("", nil) }
        return await Task.detached(priority: .userInitiated) {
            let text = Self.answer(from: .declared(trimmed))
            return (text, AccountUsage.read(text))
        }.value
    }

    // MARK: Polling

    /// Even a forced refresh keeps a floor.
    ///
    /// Every finished turn forces one, and a forced refresh launches a full
    /// `claude` process — a second of wall-clock and north of 100MB of Node —
    /// so a burst of short turns paid for one each. `force` is meant to say
    /// "the number has just moved", not "spawn regardless".
    ///
    /// Two minutes rather than ten seconds, because ten was still a Node
    /// process every ten seconds through a working session, to redraw a bar
    /// measuring a five-hour window. Nothing it reports can move enough in that
    /// time to be worth the launch.
    private static let forcedInterval: TimeInterval = 120

    func refresh(_ account: Account, force: Bool = false) {
        guard !inFlight.contains(account), let probe = probe(for: account) else { return }
        if let last = lastChecked[account],
           Date().timeIntervalSince(last) < (force ? Self.forcedInterval : Self.minimumInterval) {
            return
        }

        inFlight.insert(account)
        lastChecked[account] = Date()

        Task.detached(priority: .utility) {
            let text = Self.answer(from: probe)
            await MainActor.run {
                self.inFlight.remove(account)
                // An account with no limits to report — see `AccountUsage.read`
                // — keeps its previous reading rather than being written as
                // all-zero or blanked.
                self.ingest(text, for: account)
            }
        }
    }

    /// Every account that can answer, asked at once.
    ///
    /// What the rail calls. The per-account floors still apply, so a panel that
    /// is open all day costs one process per account per `minimumInterval` and
    /// a panel nobody has opened costs nothing at all.
    func refreshAll() {
        for account in Account.enabled { refresh(account) }
    }

    nonisolated private static func run(configDir: String) -> String {
        guard let binary = [NSHomeDirectory() + "/.local/bin/claude",
                            "/opt/homebrew/bin/claude",
                            "/usr/local/bin/claude"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return "" }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["-p", "--verbose",
                             "--input-format", "stream-json",
                             "--output-format", "stream-json",
                             // Cheapest model available; `/usage` never reaches
                             // the API, but the flag still has to parse.
                             "--model", "haiku"]
        var env = ProcessInfo.processInfo.environment
        env["CLAUDE_CONFIG_DIR"] = configDir
        process.environment = env

        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()

        do { try process.run() } catch { return "" }

        let turn = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"/usage"}]}}"# + "\n"
        try? input.fileHandleForWriting.write(contentsOf: Data(turn.utf8))
        try? input.fileHandleForWriting.close()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        // Pull the assistant text back out of the NDJSON stream.
        var text = ""
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let json = (try? JSONSerialization.jsonObject(with: Data(line.utf8)))
                    as? [String: Any],
                  json["type"] as? String == "assistant",
                  let message = json["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            for block in content where block["type"] as? String == "text" {
                text += block["text"] as? String ?? ""
            }
        }
        return text
    }
}
