import Foundation
import Combine

/// How much of the plan's allowance an account has spent.
///
/// Not available over the stream-json protocol: `rate_limit_event` says whether
/// you're *allowed* and when the window resets, but never how close you are.
/// The numbers only exist behind the CLI's `/usage` command — which, usefully,
/// is handled locally: it returns in a few hundred milliseconds and reports
/// `total_cost_usd: 0`, so it can be polled without spending anything.
struct AccountUsage: Equatable {
    var sessionPercent: Int?
    var weekPercent: Int?
    var sessionResets: String?
    var weekResets: String?

    /// The window closest to biting. A 5-hour window at 34% next to a weekly at
    /// 69% means the week is the thing that will actually stop you.
    var binding: (label: String, percent: Int, resets: String?)? {
        let candidates = [("5h", sessionPercent, sessionResets),
                          ("week", weekPercent, weekResets)]
            .compactMap { label, percent, resets in
                percent.map { (label: label, percent: $0, resets: resets) }
            }
        return candidates.max { $0.percent < $1.percent }
    }

    var summary: String {
        var parts: [String] = []
        if let percent = sessionPercent {
            parts.append("5-hour window \(percent)% used"
                         + (sessionResets.map { ", resets \($0)" } ?? ""))
        }
        if let percent = weekPercent {
            parts.append("This week \(percent)% used"
                         + (weekResets.map { ", resets \($0)" } ?? ""))
        }
        return parts.isEmpty ? "No usage limits reported for this account" : parts.joined(separator: "\n")
    }
}

/// Polls `/usage` per Claude account.
///
/// Runs in a throwaway process rather than down the live session's pipe, so the
/// answer never lands in your transcript. Account-wide rather than per-session,
/// because the allowance is.
@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    @Published private(set) var usage: [Account: AccountUsage] = [:]
    /// Spend this calendar month, per account, in dollars.
    @Published private(set) var monthlySpend: [Account: Double] = [:]

    /// The cap to measure that against. Only meaningful for a usage-based seat,
    /// where the CLI reports no percentage because there's no per-user limit it
    /// knows about — the limit lives in the contract, so it has to be typed in.
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

    init() { loadSpend() }

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

    /// Percentage of the configured cap spent this month, or `nil` when there's
    /// no cap set.
    func capUsage(_ account: Account) -> (percent: Int, spent: Double, cap: Double)? {
        guard monthlyCap > 0 else { return nil }
        let spent = monthlySpend[account] ?? 0
        return (Int((spent / monthlyCap * 100).rounded()), spent, monthlyCap)
    }

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
        guard let configDir = account.configDir, !inFlight.contains(account) else { return }
        if let last = lastChecked[account],
           Date().timeIntervalSince(last) < (force ? Self.forcedInterval : Self.minimumInterval) {
            return
        }

        inFlight.insert(account)
        lastChecked[account] = Date()

        Task.detached(priority: .utility) {
            let text = Self.run(configDir: configDir)
            let parsed = Self.parse(text)
            await MainActor.run {
                self.inFlight.remove(account)
                // An account with no limits to report — see `parse` — keeps its
                // absent entry rather than being written as all-zero.
                if let parsed { self.usage[account] = parsed }
            }
        }
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

    /// Reads the two lines that matter:
    ///
    ///     Current session: 34% used · resets Jul 31 at 4:59pm (Europe/Dublin)
    ///     Current week (all models): 69% used · resets Aug 1 at 3:59pm (…)
    ///
    /// Returns `nil` when neither is present. That isn't a parse failure — an
    /// enterprise usage-based seat genuinely has no percentages to report, and
    /// writing zeroes for it would invent a limit that doesn't exist.
    nonisolated static func parse(_ text: String) -> AccountUsage? {
        func find(_ pattern: String) -> (Int, String?)? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(
                    in: text, range: NSRange(text.startIndex..., in: text)),
                  let percentRange = Range(match.range(at: 1), in: text),
                  let percent = Int(text[percentRange]) else { return nil }

            var resets: String?
            if match.numberOfRanges > 2, let range = Range(match.range(at: 2), in: text) {
                // Drop the parenthesised timezone: the reset time is already in
                // local time, and "(Europe/Dublin)" is a lot of pixels to spend
                // restating that.
                resets = text[range]
                    .components(separatedBy: " (").first?
                    .trimmingCharacters(in: .whitespaces)
            }
            return (percent, resets)
        }

        let session = find(#"Current session:\s*(\d+)%\s*used(?:\s*·\s*resets\s*([^\n]+))?"#)
        let week = find(#"Current week[^:]*:\s*(\d+)%\s*used(?:\s*·\s*resets\s*([^\n]+))?"#)
        guard session != nil || week != nil else { return nil }

        return AccountUsage(sessionPercent: session?.0, weekPercent: week?.0,
                            sessionResets: session?.1, weekResets: week?.1)
    }
}
