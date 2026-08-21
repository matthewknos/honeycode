import Foundation

/// The folders you have started sessions in, most recent first.
///
/// Every route to a new session used to open an `NSOpenPanel` and nothing else:
/// four accounts, five buttons, one file chooser each time, and no memory of
/// the fact that the answer is almost always one of the same half-dozen
/// directories. A file panel is the right control for "somewhere I have never
/// been" and a poor one for "the repository I was in twenty minutes ago", which
/// is what it was being used for.
///
/// Kept apart from the session list on purpose. Deleting a session should not
/// erase the fact that you work in that folder — that is a fact about you, not
/// about the conversation — and a recents list derived from live sessions would
/// forget a project the moment you tidied up after it.
enum RecentProjects {

    private static let key = "recentProjects"
    /// Enough to cover a working week without turning the list into a second
    /// file browser you have to search.
    private static let limit = 12

    /// The remembered folders that still exist.
    ///
    /// Filtered on read rather than pruned on write: a folder can be moved or
    /// deleted by anything, at any time, and a list that only checks when it is
    /// written to is a list that offers you a directory that has not been there
    /// since March.
    static var all: [URL] {
        let manager = FileManager.default
        return stored.compactMap { path in
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            return URL(fileURLWithPath: path)
        }
    }

    /// Move a folder to the front, or add it there.
    static func remember(_ url: URL) {
        let path = url.standardizedFileURL.path
        var paths = stored.filter { $0 != path }
        paths.insert(path, at: 0)
        Prefs.store.set(Array(paths.prefix(limit)), forKey: key)
    }

    static func forget(_ url: URL) {
        let path = url.standardizedFileURL.path
        Prefs.store.set(stored.filter { $0 != path }, forKey: key)
    }

    private static var stored: [String] {
        Prefs.store.stringArray(forKey: key) ?? []
    }
}
