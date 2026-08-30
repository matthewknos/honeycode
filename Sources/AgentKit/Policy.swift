import Foundation

// MARK: - Settings an organisation gets to decide

/// A preference the person using this Mac may not be the one who decides.
///
/// Every control in this app is a `UserDefaults` key somebody can change, and
/// for most of them that is exactly right. Three are not: they are the fences,
/// and a fence whose only guard is a checkbox in Settings is a fence that the
/// person it exists for can switch off — which is the same person who is going
/// to forget it is there.
///
/// `Tenancy.gates` says this about itself already: *"A privacy fence that ships
/// off costs one forgotten checkbox to become nothing at all, and the person
/// who forgets is exactly the person it was for."* Default-on answers half of
/// that. This answers the other half.
///
/// **How it works.** macOS has a managed preference domain — the one a
/// configuration profile writes into, pushed by whatever MDM the organisation
/// runs. `CFPreferencesAppValueIsForced` asks whether a given key came from
/// there, and `CFPreferencesCopyAppValue` returns the managed value ahead of
/// the user's own. Neither needs an entitlement, a framework or a network: this
/// is the same mechanism every managed Mac app has used for fifteen years, and
/// on an unmanaged Mac it answers "no" and costs one function call.
///
/// **What it deliberately is not.** It is not a licence check, a kill switch or
/// anything that phones home. An organisation can force a setting on this
/// machine; nothing here reports back that it did, and nothing here can be
/// switched on remotely by anybody who isn't already administering the Mac.
enum Policy {

    /// The keys an organisation may pin, and nothing else.
    ///
    /// A closed list rather than "anything in the managed domain wins",
    /// which matters in the direction people don't expect: the risk isn't a
    /// setting being forced, it is *every* setting silently becoming
    /// forceable — a profile that pinned the model, the directory and the
    /// spend cap would be administering somebody's work rather than fencing
    /// it. These four are the ones with a security answer.
    enum Key: String, CaseIterable, Sendable {
        /// Whether enterprise work is inspected before it leaves the tenancy.
        /// See `Tenancy.gates`.
        case tenancyGate = "tenancy.gateDelegation"
        /// Whether an agent running on a schedule, with nobody watching, may
        /// write. See `AgentStore.unattendedWritesAllowed`.
        case unattendedWrites = "agents.unattendedWrites"
        /// Whether agents run with permission prompts skipped.
        case skipPermissions = "agent.skipPermissions"
        /// Whether the audit log is kept. Forced *on* is the useful direction:
        /// a record somebody can turn off is not a record.
        case auditing = "audit.enabled"

        /// What to say beside a control this is holding.
        var blurb: String {
            switch self {
            case .tenancyGate:
                return "Whether work leaving the enterprise account is inspected first"
            case .unattendedWrites:
                return "Whether an agent on a schedule may write with nobody watching"
            case .skipPermissions:
                return "Whether agents act without a permission prompt"
            case .auditing:
                return "Whether policy decisions are recorded"
            }
        }
    }

    /// The domain a profile writes into: this app's own bundle identifier.
    /// `Prefs.domain` rather than a second literal — see its note about what
    /// happens when the two halves of this tool disagree about a domain name.
    private static var appID: CFString { Prefs.domain as CFString }

    /// Whether this key is being decided by a configuration profile.
    ///
    /// The whole of the mechanism. On an unmanaged Mac it is false for
    /// everything and every caller falls through to the value it always used.
    static func isManaged(_ key: Key) -> Bool {
        CFPreferencesAppValueIsForced(key.rawValue as CFString, appID)
    }

    /// The managed value, or nil when nobody is managing this key.
    ///
    /// Read as a `Bool` through `NSNumber`, because a profile may deliver a
    /// boolean as `<true/>` or as `1` depending on how it was authored, and a
    /// fence that failed open because somebody typed an integer would be the
    /// worst possible bug in this file.
    static func managed(_ key: Key) -> Bool? {
        guard isManaged(key) else { return nil }
        guard let value = CFPreferencesCopyAppValue(key.rawValue as CFString, appID)
        else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    /// The answer, wherever it comes from: the profile if there is one, the
    /// user's own setting otherwise.
    ///
    /// Every governed setting reads through here rather than touching
    /// `Prefs.store` directly, which is what makes "can an organisation pin
    /// this" a property of the key rather than of whoever remembered to check.
    static func value(_ key: Key, default fallback: Bool) -> Bool {
        if let forced = managed(key) { return forced }
        return Prefs.store.object(forKey: key.rawValue) as? Bool ?? fallback
    }

    /// Write, unless an organisation has taken the decision away.
    ///
    /// Returns whether the write landed, so a control can tell the difference
    /// between "saved" and "ignored" instead of showing a switch that springs
    /// back and looks broken.
    @discardableResult
    static func set(_ key: Key, _ on: Bool) -> Bool {
        guard !isManaged(key) else { return false }
        Prefs.store.set(on, forKey: key.rawValue)
        return true
    }

    /// Every key a profile is currently holding. Empty on an unmanaged Mac,
    /// which is what the Settings pane checks before saying anything about
    /// organisations at all — a machine nobody manages should never see the
    /// word.
    static var managedKeys: [Key] { Key.allCases.filter(isManaged) }
}

extension Policy {
    /// One line for the person, when a control is not theirs to change.
    static let note = "Set by your organisation"

    /// A sample profile, for whoever has to write one.
    ///
    /// Kept in the source rather than in a wiki because the payload identifier
    /// has to match the bundle identifier exactly, and the one place that
    /// cannot drift from the bundle identifier is this repository.
    static var sampleProfile: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
          "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>PayloadType</key>       <string>\(Prefs.domain)</string>
          <key>PayloadIdentifier</key> <string>\(Prefs.domain).policy</string>
          <key>PayloadUUID</key>       <string>replace-with-a-uuid</string>
          <key>PayloadVersion</key>    <integer>1</integer>
        \(Key.allCases.map {
            "  <key>\($0.rawValue)</key> <true/>"
        }.joined(separator: "\n"))
        </dict>
        </plist>
        """
    }
}
