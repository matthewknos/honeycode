import Foundation

/// Confine a session to its own directory.
///
/// An isolated session can read its working directory and everything under it,
/// and nothing above or beside it. The point is a session pointed at one client's
/// checkout that can't wander into another's, or into your home directory,
/// because you asked it something loosely worded.
///
/// **What this is and isn't.** It's enforced by the agent's own permission
/// layer, not by the operating system, so it's a strong guardrail rather than a
/// wall. An agent that composes a shell command to read a file is running a
/// program, and that program isn't bound by these rules. A true wall means
/// running the CLI under `sandbox-exec`, which was measured and does confine
/// file reads on macOS 26 — but the Claude binary fails to start under every
/// deny-home profile tried, with a bare EPERM and nothing in the sandbox trace
/// to say what it wanted. That's the layer to add underneath this one; it isn't
/// this one.
///
/// **Why the rules are shaped so strangely.** Claude Code resolves `deny` ahead
/// of `allow`, which was established rather than assumed:
///
///     deny:  Read(//Users/me/**)
///     allow: Read(//Users/me/isoroot/**)
///     → reading //Users/me/isoroot/note.txt is BLOCKED
///
/// So "deny everything, then allow the root" cannot work, and the deny list has
/// to be built to exclude the root by construction. Walking up from the root and
/// denying each ancestor's *other* children does that — every sibling at every
/// level named individually, and the chain down to the root never mentioned.
///
/// Two things were learned the hard way and are load-bearing:
///
/// - A rule is `Read(//absolute/path)`. The doubled slash is what makes it
///   absolute; with one slash the rule silently matches nothing, and the whole
///   confinement quietly does nothing at all.
/// - Never emit a rule for `/` itself. `Read(//)` matches every path there is,
///   including the root's own contents, and turns isolation into a session that
///   can't read anything.
///
/// Both were caught by testing in each direction. A rule set that blocks what
/// it should is only half of it; one that also *permits* what it should is the
/// half that quietly fails, because the symptom is an agent that says it can't
/// find your files rather than one that reads too much.
enum Isolation {

    /// The deny rules confining a session to `root`.
    static func denyRules(root: URL) -> [String] {
        var rules: [String] = []
        var path = root.standardizedFileURL.resolvingSymlinksInPath()
        let manager = FileManager.default

        // Stop before `/`. The loop still denies the top-level siblings of
        // whatever the root sits under; what it never does is write a rule for
        // the root of the filesystem, which matches everything.
        while path.path != "/" && path.pathComponents.count > 1 {
            let parent = path.deletingLastPathComponent()
            let children = (try? manager.contentsOfDirectory(
                at: parent, includingPropertiesForKeys: nil,
                options: [])) ?? []

            for child in children {
                // The one on the way down to the root is the one to keep.
                guard child.standardizedFileURL.path != path.path else { continue }
                // Both ends trimmed. `URL.path` keeps a trailing slash on some
                // directory URLs, and the leading one is supplied by the `//`
                // that makes the rule absolute — so an untrimmed path yields
                // `Read(//name//**)`, which matches nothing and takes that
                // directory out of the confinement without any sign it has.
                let bare = child.standardizedFileURL.path
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard !bare.isEmpty else { continue }
                rules.append("Read(//\(bare)/**)")
                rules.append("Read(//\(bare))")
            }
            path = parent
        }
        return rules
    }

    /// The settings file to hand the CLI, or nil if it couldn't be written.
    ///
    /// Regenerated on every launch rather than cached. The rules name the
    /// siblings that exist *now*, so a folder created since the session started
    /// wouldn't be covered by a stale file — and a launch is exactly when it's
    /// cheap to look again.
    static func settings(root: URL, for session: UUID) -> URL? {
        let folder = Support.folder.appendingPathComponent("Isolation", isDirectory: true)
        let file = folder.appendingPathComponent("\(session.uuidString).json")
        let document: [String: Any] = [
            "permissions": ["deny": denyRules(root: root)],
        ]
        do {
            try FileManager.default.createDirectory(at: folder,
                                                    withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: document,
                                                  options: [.prettyPrinted])
            try data.write(to: file, options: .atomic)
            // Set after the write: an atomic write replaces by rename, so
            // permissions on the file we made go with the file we replaced.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: file.path)
            return file
        } catch {
            return nil
        }
    }

    /// Whether a path is inside the root. Used for the agents that ask
    /// permission over a protocol rather than reading a settings file.
    ///
    /// Symlinks are resolved on both sides first, so a link inside the root
    /// pointing out of it doesn't count as inside — which is the whole reason
    /// to compare resolved paths rather than the strings as written.
    ///
    /// Compared as path components, not as a string prefix: `/a/project` is a
    /// string prefix of `/a/project-old`, and that difference is the entire
    /// feature.
    static func permits(_ path: String, root: URL) -> Bool {
        let target = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            .standardizedFileURL.resolvingSymlinksInPath()
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        guard target.pathComponents.count >= base.pathComponents.count else { return false }
        return zip(base.pathComponents, target.pathComponents).allSatisfy(==)
    }

    /// The paths mentioned in a tool call, as best they can be told apart from
    /// everything else in it.
    ///
    /// Conservative in the direction that matters: something that isn't
    /// obviously a path isn't treated as one, so this never blocks a call it
    /// merely failed to parse. What it does catch is the ordinary case — a
    /// tool given a file to read — which is what a mis-aimed session actually
    /// does.
    static func paths(in value: Any) -> [String] {
        switch value {
        case let text as String:
            return (text.hasPrefix("/") || text.hasPrefix("~/")) ? [text] : []
        case let list as [Any]:
            return list.flatMap { paths(in: $0) }
        case let map as [String: Any]:
            return map.values.flatMap { paths(in: $0) }
        default:
            return []
        }
    }
}
