import Foundation

/// Everything about a conversation that outlives the process.
///
/// `conversationID` is the important field. Both CLIs keep their own record of
/// a conversation on disk and will rejoin it on request — Claude with
/// `--resume`, Copilot with `session/load` — but only if you hand back the id
/// they gave you. Bench used to mint one per launch and throw it away, so every
/// relaunch silently started over with the agent while the sidebar implied
/// otherwise.
struct SessionSnapshot: Codable {
    var conversationID: String
    /// Whether the agent has ever run for this conversation. Distinguishes
    /// "rejoin this" from "create this", which are different flags.
    var started: Bool
    var items: [TranscriptItem]
    var todos: [Todo]
    var costUSD: Double
    /// Copilot's own accounting. Optional because files written before this
    /// existed have to keep decoding, and because the other two accounts have
    /// no use for it — they report cost directly.
    ///
    /// It lives here or nowhere: `copilot`'s session state on disk records the
    /// conversation but not what it spent, and its `/usage` counter restarts
    /// with every process.
    var aiUnits: Double?
    var tokensSent: Int?
    var contextUsed: Int?
    var contextWindow: Int?
}

/// One JSON file per session, in Application Support.
///
/// Worth being plain about what this is: transcripts on disk, unencrypted, in
/// your user library. They contain whatever the agents said about your code —
/// file contents, diffs, commands. That's the same exposure the CLIs already
/// have in `~/.claude`, so this doesn't widen it, but it is a real file you
/// can read, back up, and should know exists.
enum SessionStore {

    private static var folder: URL {
        let url = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Honeycode", isDirectory: true)
            .appendingPathComponent("Sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func url(for id: UUID) -> URL {
        folder.appendingPathComponent("\(id.uuidString).json")
    }

    static func load(_ id: UUID) -> SessionSnapshot? {
        guard let data = try? Data(contentsOf: url(for: id)) else { return nil }
        return try? JSONDecoder().decode(SessionSnapshot.self, from: data)
    }

    static func save(_ snapshot: SessionSnapshot, for id: UUID) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url(for: id), options: .atomic)
    }

    static func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    /// Delete snapshots with no session left pointing at them. Closing a
    /// session removes its file directly; this catches anything orphaned by a
    /// crash or by hand-editing the roster.
    static func prune(keeping live: Set<UUID>) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for file in files where file.hasSuffix(".json") {
            let name = String(file.dropLast(5))
            guard let id = UUID(uuidString: name), !live.contains(id) else { continue }
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(file))
        }
    }
}
