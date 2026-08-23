import Foundation

/// What you typed before.
///
/// A file rather than a preference. It only ever grows at one end, somebody
/// will want to grep it, and it holds the text of everything asked of every
/// agent — which is why it is written 0600 and capped. `Support.folder` is
/// already owner-only; this doesn't rely on that staying true.
final class History {

    private let file: URL
    private static let limit = 500

    /// Oldest first, so walking up is walking back.
    private(set) var entries: [String] = []

    /// Where in `entries` the up-arrow has got to. Past the end means "on the
    /// line you were actually typing", which is a real position and not a
    /// missing one — coming back down to it has to restore what was there.
    private var cursor = 0
    private var draft = ""

    init(file: URL = Support.folder.appendingPathComponent("ai-history")) {
        self.file = file
        if let text = try? String(contentsOf: file, encoding: .utf8) {
            entries = text.split(separator: "\n").map(String.init)
        }
        cursor = entries.count
    }

    /// Newest last. A line identical to the one before it is dropped: running
    /// the same thing twice is ordinary and having to arrow past it twice is
    /// not.
    func add(_ line: String) {
        let entry = line.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        rewind()
        guard !entry.isEmpty, entries.last != entry else { return }
        entries.append(entry)
        if entries.count > Self.limit {
            entries.removeFirst(entries.count - Self.limit)
        }
        cursor = entries.count
        save()
    }

    /// Back to the live line, which is where every new prompt starts.
    func rewind() {
        cursor = entries.count
        draft = ""
    }

    /// - Parameter current: what is on the line now, kept so that arrowing back
    ///   down returns it rather than an empty prompt.
    /// - Returns: what should be on the line, or nil at the end of the list.
    func previous(from current: String) -> String? {
        guard cursor > 0 else { return nil }
        if cursor == entries.count { draft = current }
        cursor -= 1
        return entries[cursor]
    }

    func next() -> String? {
        guard cursor < entries.count else { return nil }
        cursor += 1
        return cursor == entries.count ? draft : entries[cursor]
    }

    private func save() {
        try? (entries.joined(separator: "\n") + "\n")
            .write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: file.path)
    }
}
