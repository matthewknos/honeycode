import Foundation

/// Where preferences live, for both faces of the same tool.
///
/// The app and `ai` are two binaries sharing AgentKit, and until this existed
/// they were also two preference domains. The app writes to
/// `com.matthewquigley.honeycode` — its bundle identifier, which is what
/// `UserDefaults.standard` resolves to inside a bundle. `ai` has no bundle, so
/// the same call resolved to a domain named after the process: `ai.plist`.
///
/// Nobody decided that. The result was a split brain in which each half learned
/// every account's model catalogue separately, each tracked spend separately,
/// and a model chosen in the app's picker had no effect whatsoever on a crew
/// run in the terminal. Splits like this are hard to see from either side,
/// because both halves stay internally consistent — and the advice that follows
/// from one ("change it in the app") is confidently wrong.
///
/// So there is one domain, and it is the app's. `ai` joins it.
enum Prefs {

    /// The app's bundle identifier, which is also the shared domain name.
    static let domain = "com.matthewquigley.honeycode"

    /// Every preference read and write in AgentKit goes through here.
    ///
    /// Inside the app this is `.standard` deliberately, rather than
    /// `UserDefaults(suiteName:)` with the app's own bundle id — Apple
    /// documents passing your own domain to `suiteName` as unsupported, and it
    /// returns nil on some releases. Outside the app, the suite is the app's
    /// domain and the redirect is the whole point.
    static let store: UserDefaults = {
        if Bundle.main.bundleIdentifier == domain { return .standard }
        return UserDefaults(suiteName: domain) ?? .standard
    }()

    /// True when this process reaches the shared domain through a suite — that
    /// is, it is `ai` rather than the app. Only the joining side migrates.
    private static var isGuest: Bool { Bundle.main.bundleIdentifier != domain }

    private static let didRunKey = "migrated.fromCLIDomain"

    /// What `UserDefaults.standard` resolved to for a bare executable named
    /// `ai`: `~/Library/Preferences/ai.plist`.
    private static let guestDomain = "ai"

    private static let spendPrefix = "usage.spend."

    /// Carry `ai`'s own preferences into the shared domain, once.
    ///
    /// Copies rather than moves, and never overwrites: the app's domain is the
    /// older and busier of the two, so where both hold a key the app's value
    /// wins and `ai`'s is left behind in its own plist rather than destroyed.
    ///
    /// Spend is the one exception, and it is summed. Two separate running
    /// totals for the same account and month are two halves of one number —
    /// picking either would silently under-report what has been spent, which is
    /// the one preference here where being quietly wrong costs money.
    ///
    /// With one guard on that. Both domains were seeded from the same Bench
    /// migration, so a key can hold the identical figure in each not because
    /// two halves were spent but because one was copied twice. Exact equality
    /// between two independently accumulated float totals is not something that
    /// happens; a shared ancestor is the only thing that produces it. So equal
    /// values are treated as the same money and left alone, and only genuinely
    /// divergent ones are added.
    static func adopt() {
        guard isGuest, !store.bool(forKey: didRunKey) else { return }

        // Flagged even when there is nothing to read, so a machine that never
        // ran the old `ai` doesn't re-scan for a file that will never exist.
        defer { store.set(true, forKey: didRunKey) }

        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Preferences/\(guestDomain).plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(
                from: data, format: nil) as? [String: Any]
        else { return }

        for (key, value) in plist {
            // AppKit's own furniture. It will write its own, in its own domain.
            guard !key.hasPrefix("NS"), !key.hasPrefix("com.apple") else { continue }

            if key.hasPrefix(spendPrefix), let mine = value as? Double {
                let theirs = store.double(forKey: key)
                guard theirs != mine else { continue }
                store.set(theirs + mine, forKey: key)
                continue
            }
            guard store.object(forKey: key) == nil else { continue }
            store.set(value, forKey: key)
        }
    }
}
