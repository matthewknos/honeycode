import Foundation

/// Carries everything over from when the app was called Bench.
///
/// A rename changes two things macOS keys storage by: the bundle identifier
/// (which is the preferences domain) and the Application Support folder name.
/// Neither moves on its own, so without this a rename silently looks like data
/// loss — the roster empties, the background resets, and every transcript is
/// still on disk under a name nothing reads any more.
///
/// Runs once, guarded by a flag, and copies rather than moves. If any of it
/// goes wrong the old data is still exactly where it was.
enum Migration {

    private static let didRunKey = "migrated.fromBench"
    private static let oldBundleID = "com.matthewquigley.bench"
    private static let oldFolder = "Bench"
    private static let newFolder = "Honeycode"

    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: didRunKey) else { return }
        defaults.set(true, forKey: didRunKey)

        migratePreferences()
        migrateSupportFolder()
    }

    /// The old domain's plist is readable directly. `UserDefaults(suiteName:)`
    /// on a plain app-bundle domain doesn't reliably see it, and reading the
    /// file is unambiguous.
    private static func migratePreferences() {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Preferences/\(oldBundleID).plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(
                from: data, format: nil) as? [String: Any] else { return }

        let defaults = UserDefaults.standard
        for (key, value) in plist {
            // Window frames and split positions are the old app's furniture,
            // and AppKit will write its own. Everything else — the session
            // roster, appearance, background choice, spend — is yours.
            guard !key.hasPrefix("NS"), !key.hasPrefix("com.apple") else { continue }
            guard defaults.object(forKey: key) == nil else { continue }
            defaults.set(value, forKey: key)
        }
    }

    /// Transcripts and the background library.
    private static func migrateSupportFolder() {
        let manager = FileManager.default
        guard let support = manager.urls(for: .applicationSupportDirectory,
                                         in: .userDomainMask).first else { return }
        let old = support.appendingPathComponent(oldFolder, isDirectory: true)
        let new = support.appendingPathComponent(newFolder, isDirectory: true)

        guard manager.fileExists(atPath: old.path),
              !manager.fileExists(atPath: new.path) else { return }
        try? manager.copyItem(at: old, to: new)
    }
}
