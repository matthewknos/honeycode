import Foundation
import CryptoKit

// MARK: - What the fences decided, kept

/// An append-only record of the decisions this app made on somebody's behalf.
///
/// The tenancy fence refuses pieces of work, confines delegates and lets other
/// pieces through, and until now the only trace was a `CrewRun` held in memory
/// and a transcript that scrolls away. So "did enterprise material ever leave,
/// and when" had no answer an hour later, let alone a week — which is the
/// question that actually gets asked, and the one a control has to be able to
/// answer before anybody will rely on it.
///
/// **What is deliberately not in here.** Not the task text, not the reason
/// verbatim, not a file's contents. Writing the material you are protecting
/// into a plaintext log beside the thing that protects it is the classic
/// own-goal, and a log somebody has to be careful with is one that ends up
/// switched off. What is recorded is a **hash** of the task, which answers the
/// question a hash can answer — *was it this same piece of work* — and refuses
/// the one it shouldn't.
///
/// **Append-only, and local.** One line of JSON per event, `0600`, in the
/// app's own support directory. Nothing is sent anywhere: an organisation that
/// wants these off the machine collects them the way it collects everything
/// else off a managed Mac.
enum Audit {

    // MARK: What gets recorded

    /// The decisions worth a line. Deliberately short — a log that records
    /// everything is one nobody reads, and every entry here is a moment where
    /// this app allowed or refused something on a policy basis.
    enum Event: String, Codable, Sendable {
        /// A piece of work was inspected before leaving the tenancy, and
        /// cleared.
        case crossingAllowed
        /// …and was refused. The reason is categorised, not quoted.
        case crossingBlocked
        /// A delegate was given a confined scratch directory rather than the
        /// project, because it runs outside the tenancy.
        case delegateConfined
        /// A scheduled run was held to propose-only, or confined, by policy
        /// rather than by its own definition. See `AgentStore.asRun`.
        case unattendedDowngraded
        /// A setting this app governs was found to be pinned by a
        /// configuration profile. Recorded once per launch, so a log can be
        /// read without also needing the profile that was live at the time.
        case policyApplied
    }

    /// One line.
    ///
    /// Flat and small on purpose: this is read by whatever an organisation
    /// already uses to read JSONL, and a nested shape would mean everybody
    /// writing a parser before they could answer a question.
    struct Entry: Codable, Sendable {
        var at: Date
        var event: Event
        /// The accounts involved, by handle rather than by title — `@claude-w`
        /// is what appears everywhere else a person looks.
        var from: String?
        var to: String?
        /// SHA-256 of the task, truncated. Enough to match two entries against
        /// each other, useless for recovering the text.
        var task: String?
        /// Why, in this app's own words rather than an agent's — see the type
        /// note. Always one of a fixed set.
        var reason: String?
        /// Which run this belonged to, so the lines of one crew group.
        var run: String?
    }

    // MARK: Whether it is on

    /// On unless switched off, and switchable off unless an organisation says
    /// otherwise.
    ///
    /// Default-on for the reason `Tenancy.gates` gives about itself: a record
    /// that ships off is a record nobody has when they need one. Through
    /// `Policy` so it can be pinned, and pinned *on* is the useful direction —
    /// a log the person being logged can turn off is not a log.
    static var isOn: Bool { Policy.value(.auditing, default: true) }

    // MARK: Writing

    /// Where it lives. Beside the sessions rather than in `~/Library/Logs`,
    /// because it is this app's own record rather than a crash report, and
    /// because everything else worth collecting off a machine is already here.
    static var url: URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Honeycode", isDirectory: true)
        return support.appendingPathComponent("audit.jsonl")
    }

    /// A serial queue, because the whole contract is that lines don't
    /// interleave. Two crew runs finishing at once is the ordinary case.
    private static let queue = DispatchQueue(label: "com.matthewquigley.honeycode.audit")

    static func record(_ event: Event, from: Account? = nil, to: Account? = nil,
                       task: String? = nil, reason: String? = nil,
                       run: UUID? = nil) {
        guard isOn else { return }
        let entry = Entry(at: Date(), event: event,
                          from: from.map(AgentMention.handle),
                          to: to.map(AgentMention.handle),
                          task: task.map(digest),
                          reason: reason,
                          run: run?.uuidString)
        queue.async { append(entry) }
    }

    /// Truncated to sixteen hex characters. A full SHA-256 is 64 characters of
    /// line noise per entry to distinguish things that a sixteen-character
    /// prefix already distinguishes — this is for matching two lines in one
    /// file, not for a signature.
    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(16)
            .description
    }

    private static func append(_ entry: Entry) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Sorted keys so a diff of two logs is about the events rather than
        // about dictionary ordering.
        encoder.outputFormatting = [.sortedKeys]
        guard var line = try? encoder.encode(entry) else { return }
        line.append(0x0A)

        let manager = FileManager.default
        let file = url
        try? manager.createDirectory(at: file.deletingLastPathComponent(),
                                     withIntermediateDirectories: true,
                                     attributes: [.posixPermissions: 0o700])

        // `0600` at creation rather than after: a file that is world-readable
        // for the instant between being made and being chmodded is a file that
        // was world-readable.
        if !manager.fileExists(atPath: file.path) {
            manager.createFile(atPath: file.path, contents: nil,
                               attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    // MARK: Reading

    /// Everything on disk, newest last. Small enough to hold: a busy month is
    /// a few thousand lines of a couple of hundred bytes.
    static func all() -> [Entry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap {
            try? decoder.decode(Entry.self, from: Data($0.utf8))
        }
    }

    // MARK: Retention

    /// How long a line is kept. Ninety days is the shortest window that still
    /// covers "what happened last quarter", which is the question these get
    /// asked in.
    static let keepFor: TimeInterval = 90 * 24 * 60 * 60

    /// Drop anything past the window, by rewriting the file.
    ///
    /// A rewrite rather than a truncate, and it is worth saying why the
    /// append-only claim survives it: nothing here can edit a line, and the
    /// only thing that removes one is age. What this is not is tamper-proof —
    /// the file belongs to the person using the Mac, and pretending otherwise
    /// would be the kind of assurance that fails exactly when it matters.
    @discardableResult
    static func prune(now: Date = Date()) -> Int {
        let kept = all().filter { now.timeIntervalSince($0.at) < keepFor }
        let dropped = all().count - kept.count
        guard dropped > 0 else { return 0 }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let body = kept.compactMap { try? encoder.encode($0) }
            .compactMap { String(data: $0, encoding: .utf8) }
            .joined(separator: "\n")
        try? (body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: url.path)
        return dropped
    }

    /// Say once per launch which settings an organisation is holding, so a log
    /// can be read on its own without also needing the profile that was live at
    /// the time.
    static func notePolicy() {
        for key in Policy.managedKeys {
            record(.policyApplied, reason: key.rawValue)
        }
    }

    /// Both of the once-a-launch jobs, in the order they have to happen.
    ///
    /// Pruning first: a log that has just been trimmed to ninety days and then
    /// told what today's policy is reads correctly from either end. The other
    /// order leaves a policy line that gets dropped by the prune that follows
    /// it on a machine which hasn't been opened in three months.
    static func begin() {
        guard isOn else { return }
        queue.async { _ = prune() }
        notePolicy()
    }
}
