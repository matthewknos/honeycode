import Foundation
import UniformTypeIdentifiers

/// Files referenced by a message, pulled back out of its text.
///
/// The composer appends attachments as `@/absolute/path` lines — the CLIs
/// resolve those themselves, which is why it was done that way. But it means
/// the transcript showed you a wall of paths where you'd attached a screenshot,
/// which is a strange thing for a GUI to do with an image it has on disk.
enum Attached {

    /// Splits a message into what you wrote and what you attached.
    ///
    /// Only *trailing* `@/…` lines count. A path in the middle of a sentence is
    /// something you were talking about, not something you attached.
    static func split(_ text: String) -> (prose: String, files: [URL]) {
        var lines = text.components(separatedBy: "\n")
        var files: [URL] = []

        while let last = lines.last {
            let trimmed = last.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("@/") || trimmed.hasPrefix("@~/") else { break }
            let path = NSString(string: String(trimmed.dropFirst())).expandingTildeInPath
            files.insert(URL(fileURLWithPath: path), at: 0)
            lines.removeLast()
        }

        return (lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
                files)
    }

    static func isImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }
}
