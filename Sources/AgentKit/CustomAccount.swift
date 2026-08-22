import Foundation
import Security

/// A subscription this app was never told about.
///
/// Honeycode shipped knowing four accounts, and knowing them by name: the
/// sidebar, the colours, the `@handles`, the model catalogue and the tenancy
/// rules all read a fixed enum. That was honest while the set was fixed and
/// wrong the moment somebody else's machine had a fifth — a Gemini CLI, a
/// second Kimi seat on a different key, an in-house agent, a Claude Code
/// pointed at a proxy.
///
/// So an account is now something you can write down. Everything the app needs
/// to drive one is declarative and lives here, and `ACPAdapter` cannot tell a
/// custom agent from one that shipped.
///
/// **What this is not.** An API key on its own does not make an agent. The
/// thing that reads your files, runs your commands and decides what to edit is
/// the CLI; a key is how that CLI authenticates. So a key here is stored
/// securely and handed to a command as an environment variable — which is how
/// every one of these tools takes one — rather than being pointed at a model
/// endpoint directly. Doing the latter would mean writing the agent loop
/// ourselves, which is a different program to this one.
struct CustomAccount: Codable, Identifiable, Hashable {

    /// Stable for the life of the account. Written into every saved session
    /// descriptor, so it outlives renaming.
    let id: String
    /// "Gemini CLI". Names the agent, not the credential — see `Account.title`.
    var title: String
    var shortTitle: String
    /// What it answers to in a message: `@gemini`. Lower-cased, no `@`, and
    /// checked against the built-ins before it is saved.
    var handle: String
    var tint: Tint

    /// The command, and how to speak to it.
    var command: String
    var arguments: [String]
    var isNode: Bool
    var dialect: ACPAgent.Dialect
    var usageReports: ACPAgent.UsageKind

    /// Plain environment, as typed. Anything secret belongs in `secrets`.
    var environment: [String: String]
    /// The names of environment variables whose values live in the Keychain —
    /// `ANTHROPIC_API_KEY`, `GEMINI_API_KEY`. Only the names are stored here;
    /// this file ends up in `UserDefaults`, which is a plist in your Library
    /// that anything you run can read.
    var secretNames: [String]

    /// Which `AgentCatalogue` entry this came from, for one that was added from
    /// the list rather than typed into the form.
    ///
    /// The id and nothing else. The name, the description and where to get it
    /// all live in the catalogue, and copying them here would be storing a
    /// snapshot of a list that is regenerated — so an account added in March
    /// would still be showing March's description of somebody else's tool.
    ///
    /// Optional, and that is also how every account saved before this decodes:
    /// a missing key for an optional is nil, which is exactly right for one
    /// that was written by hand.
    var catalogue: String?

    init(id: String = UUID().uuidString, title: String, shortTitle: String? = nil,
         handle: String, tint: Tint = .teal, command: String,
         arguments: [String] = [], isNode: Bool = true,
         dialect: ACPAgent.Dialect = .standard,
         usageReports: ACPAgent.UsageKind = .none,
         environment: [String: String] = [:], secretNames: [String] = [],
         catalogue: String? = nil) {
        self.id = id
        self.title = title
        self.shortTitle = shortTitle ?? title
        self.handle = handle
        self.tint = tint
        self.command = command
        self.arguments = arguments
        self.isNode = isNode
        self.dialect = dialect
        self.usageReports = usageReports
        self.environment = environment
        self.secretNames = secretNames
        self.catalogue = catalogue
    }

    /// The catalogue entry behind it, if there is one.
    var catalogueEntry: CatalogueAgent? { AgentCatalogue.entry(catalogue) }

    /// Where to get it, for an agent that ships a binary rather than being
    /// fetched by `npx`. Nil for anything with nothing to install, and for
    /// anything added by hand — this app has no idea where somebody's in-house
    /// agent comes from and should not invent a link.
    var site: String? { catalogueEntry?.site }

    /// A colour, chosen from a list rather than a picker.
    ///
    /// The four that ship are orange, blue, purple and green, and the whole job
    /// a colour does here is telling one account from another at a glance. A
    /// free picker lets you choose the orange that is nearly the other orange.
    enum Tint: String, Codable, CaseIterable {
        case teal, pink, indigo, brown, red, yellow

        var title: String { rawValue.capitalized }
    }

    /// This account as something the adapter can launch.
    ///
    /// Secrets are read at the moment of use and never held: the process gets
    /// them, this struct doesn't.
    var agent: ACPAgent {
        var environment = self.environment
        for name in secretNames {
            guard let value = Keychain.read(account: id, key: name) else { continue }
            environment[name] = value
        }
        return ACPAgent(id: id, displayName: shortTitle.lowercased(),
                        command: command, arguments: arguments, isNode: isNode,
                        dialect: dialect, usageReports: usageReports,
                        extraEnvironment: environment)
    }

    /// Why this can't be saved, or nil if it can.
    ///
    /// Checked before it is stored rather than discovered when nothing happens.
    /// A handle that collides with a built-in is the one that would fail
    /// silently and strangely: `AgentMention` resolves longest-first, so a
    /// second `@kimi` wouldn't error, it would simply never win.
    static func objection(to draft: CustomAccount, existing: [CustomAccount]) -> String? {
        let handle = draft.handle.lowercased()
        if draft.title.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Give it a name."
        }
        if handle.isEmpty { return "Give it a handle to answer to." }
        if handle.contains(where: { !$0.isLetter && !$0.isNumber && $0 != "-" }) {
            return "A handle can only hold letters, numbers and hyphens — "
                 + "it has to survive being typed after an @."
        }
        if AgentMention.builtInNames.contains(where: { $0.0 == handle }) {
            return "@\(handle) is already one of the built-in agents."
        }
        if existing.contains(where: { $0.handle.lowercased() == handle && $0.id != draft.id }) {
            return "@\(handle) is already taken by another account you've added."
        }
        if draft.command.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Say which command to run."
        }
        return nil
    }
}

/// Every account somebody has added, and where they are kept.
///
/// In `UserDefaults` beside every other preference, because that is what they
/// are — and deliberately *not* where the secrets go. See `Keychain`.
///
/// Readable from any thread, behind a lock, and that is a decision rather than
/// laziness. `Account.title` and `AgentMention.handle` are on the path of every
/// sidebar row, every parsed mention and every log line, and none of those were
/// main-actor-bound before custom accounts existed. Making them so would have
/// pushed `@MainActor` up through `Seat`, `AgentMention` and every test that
/// parses a handle — a great deal of ceremony to protect a list that changes
/// when somebody presses Save in a settings sheet.
enum CustomAccounts {

    private static let key = "accounts.custom.v1"
    private static let lock = NSLock()
    /// Read once and held, because a JSON decode per sidebar row is a decode
    /// per frame. Guarded by `lock`; never touched without it.
    nonisolated(unsafe) private static var cache: [CustomAccount]?

    static var all: [CustomAccount] {
        lock.lock()
        defer { lock.unlock() }
        if let cache { return cache }
        let stored = Prefs.store.data(forKey: key)
            .flatMap { try? JSONDecoder().decode([CustomAccount].self, from: $0) } ?? []
        cache = stored
        return stored
    }

    static func find(_ id: String) -> CustomAccount? {
        all.first { $0.id == id }
    }

    static func save(_ account: CustomAccount) {
        var list = all
        if let index = list.firstIndex(where: { $0.id == account.id }) {
            list[index] = account
        } else {
            list.append(account)
        }
        write(list)
    }

    /// Forget an account, and the secrets that went with it.
    ///
    /// The Keychain entries go too. A key left behind for an account nobody can
    /// see any more is a credential you have no way to find and no reason to
    /// keep.
    static func remove(_ id: String) {
        guard let going = find(id) else { return }
        for name in going.secretNames { Keychain.delete(account: id, key: name) }
        write(all.filter { $0.id != id })
    }

    private static func write(_ list: [CustomAccount]) {
        lock.lock()
        cache = list
        lock.unlock()
        guard let data = try? JSONEncoder().encode(list) else { return }
        Prefs.store.set(data, forKey: key)
    }
}

/// Where an API key goes.
///
/// Not `UserDefaults`, which is a plist in your Library that every process you
/// run can read, and not the JSON above, which is backed up with it. The
/// Keychain is the one place on this machine designed for the question.
enum Keychain {

    private static let service = "com.matthewquigley.honeycode.accounts"

    private static func query(_ account: String, _ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "\(account)/\(key)"]
    }

    static func read(account: String, key: String) -> String? {
        var lookup = query(account, key)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Written, or replaced if it is already there. An empty value deletes:
    /// clearing the field in the sheet has to mean something, and "store an
    /// empty key" is not a thing anyone wants.
    static func write(account: String, key: String, value: String) {
        guard !value.isEmpty else { delete(account: account, key: key); return }
        let data = Data(value.utf8)
        let existing = query(account, key)
        if SecItemCopyMatching(existing as CFDictionary, nil) == errSecSuccess {
            SecItemUpdate(existing as CFDictionary,
                          [kSecValueData as String: data] as CFDictionary)
            return
        }
        var insert = existing
        insert[kSecValueData as String] = data
        // Available without unlocking anything once this Mac is unlocked, and
        // never synced to another device: the key is paired with a CLI
        // installed here, and a copy on a machine that can't run it is exposure
        // with no use.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(insert as CFDictionary, nil)
    }

    static func delete(account: String, key: String) {
        SecItemDelete(query(account, key) as CFDictionary)
    }

    /// Whether something is stored, without reading it — for a field that
    /// should show "set" rather than the key itself.
    static func has(account: String, key: String) -> Bool {
        SecItemCopyMatching(query(account, key) as CFDictionary, nil) == errSecSuccess
    }
}
