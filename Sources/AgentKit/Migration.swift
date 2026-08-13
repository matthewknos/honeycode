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

        migratePreferences()
        migrateSupportFolder()

        // Flagged after the work, not before. Setting it up front meant a copy
        // that failed — or an app that died halfway through one — left the old
        // data stranded behind a flag claiming it had already been brought
        // over, with no way to retry short of editing defaults by hand. The
        // work is idempotent (both halves skip what already exists), so
        // running it twice after a crash is harmless; never running it again
        // is not.
        defaults.set(true, forKey: didRunKey)
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



/// The application support folder, and what's allowed to accumulate in it.
///
/// Everything this app keeps is in one place and none of it is encrypted, which
/// is a deliberate and documented choice — but the *contents* deserve stating
/// plainly, because it's more than "some settings". Transcripts hold file
/// contents, diffs and command output. `Artifacts/` holds every page and diagram
/// an agent has ever drawn. `Attachments/` holds every image pasted into the
/// composer, which for most people means screenshots of whatever was on screen
/// at the time. All of it is swept into Time Machine and any folder-syncing
/// backup.
///
/// Encryption isn't the answer here — the app would have to hold the key, and
/// on an unsandboxed personal tool that's ceremony rather than security. Two
/// cheaper things are worth doing: don't leave it readable by every other
/// account on the machine, and don't keep the ephemeral parts forever.
enum Support {

    static var folder: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Honeycode", isDirectory: true)
    }

    /// Run once at launch.
    static func prepare() {
        let manager = FileManager.default
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        // Owner only. Application Support is 0700 already on a stock system,
        // but this doesn't depend on that staying true, and it costs one call.
        try? manager.setAttributes([.posixPermissions: 0o700],
                                    ofItemAtPath: folder.path)
        // Off the main thread. The directory and its permissions have to be
        // right before anything writes into it, so those stay here — but the
        // sweep is three directory enumerations plus a modification date read
        // per file, and it runs from `Workspace.init`, which is before the
        // first frame. Nothing waits on the result of a month-old file being
        // deleted a second later than it might have been.
        DispatchQueue.global(qos: .utility).async {
            prune("Artifacts")
            prune("Attachments")
            // Relayed files are redacted, not harmless — and unlike the other
            // two they exist only to be handed to one composer once. Swept on
            // the same schedule rather than kept indefinitely.
            prune("Relays")
        }
    }

    /// Delete anything in a subfolder older than a month.
    ///
    /// Only the two derived folders. Transcripts are the thing you came back
    /// for and are never swept — a chat history that deletes itself after a
    /// month is a bug report, not a retention policy.
    static func prune(_ name: String, olderThan days: Double = 30) {
        let manager = FileManager.default
        let cutoff = Date().addingTimeInterval(-days * 24 * 60 * 60)
        let directory = folder.appendingPathComponent(name, isDirectory: true)
        guard let files = try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        for file in files {
            let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            guard let modified, modified < cutoff else { continue }
            try? manager.removeItem(at: file)
        }
    }
}
