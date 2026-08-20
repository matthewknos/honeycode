import Foundation

// MARK: - Who you're signed in to Azure as

/// One subscription, as the Azure CLI recorded it.
struct AzureSubscription: Equatable, Sendable {
    let id: String
    let name: String
    /// The identity that can reach it — an email for a person, something else
    /// for a service principal.
    let user: String
    let tenant: String
    /// The subscription `az` currently acts as. There is exactly one across
    /// every account, which is why "which account am I" is answerable at all.
    let isDefault: Bool
    /// Disabled and expired subscriptions stay in the profile. Switching to one
    /// succeeds and then every command against it fails.
    let isEnabled: Bool
}

/// One signed-in identity, with the subscriptions it can reach.
///
/// Grouped by the email rather than listed per subscription, because the
/// question this answers is "which tenant am I in right now" — and an
/// account with four subscriptions would otherwise take four rows to say one
/// thing. `az` has no notion of a current *account*: it tracks a default
/// subscription, and the account is whoever owns it.
struct AzureAccount: Equatable, Sendable, Identifiable {
    let user: String
    var subscriptions: [AzureSubscription]

    var id: String { user }

    var isActive: Bool { subscriptions.contains { $0.isDefault } }

    /// What switching to this account would actually select: the subscription
    /// it was last on if that's still usable, otherwise its first working one.
    /// Nil when every subscription it has is disabled, which is a row worth
    /// showing and not worth clicking.
    var target: AzureSubscription? {
        subscriptions.first { $0.isEnabled && $0.isDefault }
            ?? subscriptions.first { $0.isEnabled }
    }

    /// The subscription when there's one, the count when there are several —
    /// naming one of four would imply a choice that isn't being made here.
    var detail: String? {
        let usable = subscriptions.filter(\.isEnabled)
        if usable.isEmpty { return "no enabled subscriptions" }
        if usable.count == 1 { return usable[0].name }
        if let current = usable.first(where: \.isDefault) {
            return "\(current.name) + \(usable.count - 1) more"
        }
        return "\(usable.count) subscriptions"
    }
}

/// The Azure identities on this machine, and the switch between them.
///
/// Read from `az`'s own profile file rather than by asking `az`, for the reason
/// the whole of `ProjectDetector` is written that way: this runs when a menu
/// opens, and `az` is a Python program whose startup alone is most of a second.
/// The file is the same thing `az account list` would print, minus the wait.
/// Falls back to the CLI when the file isn't where it should be.
///
/// **This is not `azd`.** The two keep separate credentials, and the chip below
/// the pill reads `azd`'s files — so it is possible to be `az`-signed-in as one
/// account while `azd` deploys as the other. This section reports `az` only.
enum AzureAuth {

    private static var binary: String? { Shell.locate("az") }

    static var profile: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/.azure/azureProfile.json")
    }

    static var isInstalled: Bool {
        binary != nil || FileManager.default.fileExists(atPath: profile.path)
    }

    /// Every account with credentials on this machine, in profile order.
    nonisolated static func accounts() -> [AzureAccount] {
        group(subscriptionsFromProfile() ?? subscriptionsFromCLI())
    }

    /// Make `account` the one `az` acts as.
    ///
    /// Machine-wide, like the GitHub switch beside it, and for the same reason:
    /// an answer that held only inside this app would be a different and more
    /// confusing thing than no answer.
    nonisolated static func select(_ account: AzureAccount) throws {
        guard let binary else {
            throw CommandFailure(summary: "`az` isn't installed",
                                 detail: "brew install azure-cli")
        }
        guard let target = account.target else {
            throw CommandFailure(
                summary: "\(account.user) has no enabled subscription",
                detail: "Every subscription on this account is disabled or expired.")
        }
        // Set by id, never by name: subscription names are not unique, and two
        // tenants naming one "Production" is the ordinary case rather than the
        // odd one.
        let result = Shell.run(binary, ["account", "set", "--subscription", target.id])
        guard result.ok else {
            throw CommandFailure(summary: "Couldn't switch to \(account.user)",
                                 detail: result.message)
        }
    }

    /// A script that runs `az login` in the user's terminal.
    ///
    /// See `Shell.terminalScript` for the shape. `az login` adds an identity to
    /// the profile rather than replacing the one already in it, so this is how
    /// the second tenant arrives.
    ///
    /// The preamble is the Python twin of the `NODE_EXTRA_CA_CERTS` problem in
    /// `ACPAgent`: `az` verifies against `certifi`'s bundle and ignores the
    /// keychain, so behind a TLS-inspecting proxy every call it makes fails
    /// with "unable to get local issuer certificate" — including the login
    /// itself. Set only when you haven't set it yourself, and pointed at roots
    /// the system already trusts.
    nonisolated static func loginScript() -> URL? {
        guard let binary else { return nil }
        let trust = ProcessInfo.processInfo.environment["REQUESTS_CA_BUNDLE"] == nil
            ? SystemTrust.caBundle().map { "export REQUESTS_CA_BUNDLE=\"\($0.path)\"\n" } ?? ""
            : ""
        return Shell.terminalScript(named: "honeycode-az-login",
                                    announcing: "Signing in to Azure.",
                                    preamble: trust,
                                    run: binary, ["login"])
    }

    // MARK: Where the list comes from

    /// `~/.azure/azureProfile.json`, which `az` rewrites on every login and
    /// every `account set`.
    ///
    /// Returns nil rather than an empty array when it can't be read, so the
    /// caller can tell "no file" from "a file saying you're signed out" and
    /// only pay for the CLI in the first case.
    private static func subscriptionsFromProfile() -> [AzureSubscription]? {
        guard let data = try? Data(contentsOf: profile) else { return nil }
        // Written UTF-8 *with a BOM*, which `JSONSerialization` rejects outright
        // — the one quirk of this file, and it fails the whole read rather than
        // one field.
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }

        guard let json = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        else { return nil }
        // `az` writes this file the first time it runs, carrying nothing but an
        // installation id, and only grows a `subscriptions` key on first login.
        // So a file without one is a signed-out machine — an answer, not a
        // failed read, and not worth a second of Python startup to re-confirm.
        let list = json["subscriptions"] as? [[String: Any]] ?? []
        return list.compactMap(subscription(from:))
    }

    /// `az account list`, for when the profile isn't where it's expected.
    private static func subscriptionsFromCLI() -> [AzureSubscription] {
        guard let binary else { return [] }
        let result = Shell.run(binary, ["account", "list", "--all", "--output", "json"])
        guard result.ok, let data = result.out.data(using: .utf8),
              let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return [] }
        return list.compactMap(subscription(from:))
    }

    /// One entry, in the shape both the profile and `az account list` use.
    private static func subscription(from json: [String: Any]) -> AzureSubscription? {
        guard let id = json["id"] as? String, !id.isEmpty else { return nil }
        // Service principals and managed identities have a `user.name` that
        // isn't an email; they're still an identity you can be acting as, so
        // they're listed rather than filtered. One with no identity at all has
        // nothing to file it under, and this list is by identity.
        guard let user = (json["user"] as? [String: Any])?["name"] as? String,
              !user.isEmpty else { return nil }
        return AzureSubscription(
            id: id,
            name: json["name"] as? String ?? id,
            user: user,
            tenant: json["tenantId"] as? String ?? "",
            isDefault: json["isDefault"] as? Bool ?? false,
            // Absent means enabled: `az account list` without `--all` only
            // returns enabled ones and omits nothing, so a missing state is a
            // working subscription rather than an unknown one.
            isEnabled: (json["state"] as? String ?? "Enabled") == "Enabled")
    }

    /// Subscriptions to accounts, first-seen order preserved.
    private static func group(_ subscriptions: [AzureSubscription]) -> [AzureAccount] {
        var order: [String] = []
        var byUser: [String: [AzureSubscription]] = [:]
        for subscription in subscriptions {
            let user = subscription.user
            if byUser[user] == nil { order.append(user) }
            byUser[user, default: []].append(subscription)
        }
        return order.map { AzureAccount(user: $0, subscriptions: byUser[$0] ?? []) }
    }
}
