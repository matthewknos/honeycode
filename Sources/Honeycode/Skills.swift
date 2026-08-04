import SwiftUI
import AppKit

/// Instructions you write once and every agent can use.
///
/// A skill here is a folder holding a `SKILL.md` — the same shape Claude Code
/// uses, deliberately, so one can be copied in from a repo or out to a config
/// dir without translation. Name and one-line description in the front matter,
/// instructions in the body.
///
/// **How they reach the agents.** Every session is given an *index* — the names
/// and descriptions and where the files are — and told to read a skill's file
/// when the work calls for it. Nothing else. That sounds like the weak option
/// next to installing them as native Claude skills, and it isn't: native skills
/// work exactly this way underneath. An index goes into context, the body is
/// read on demand. Doing it here rather than through `CLAUDE_CONFIG_DIR` buys
/// three things — it works identically on Kimi and Copilot, which have no
/// skills mechanism at all and would otherwise be second-class; it doesn't
/// write into config directories Honeycode doesn't own; and it doesn't change
/// what `claude` does in a terminal, which is somebody else's session.
///
/// What that approach *does* give up is the `/branding` invocation, since only
/// the agent's own skills reach its command list. So Honeycode registers those
/// commands itself — see `commands` — which puts them in the `/` menu on all
/// four profiles rather than on the two Claude ones.
struct Skill: Identifiable, Equatable {
    /// The folder name, and the command. Lowercase, hyphenated.
    let slug: String
    var name: String
    var summary: String
    var body: String

    var id: String { slug }
    var folder: URL { Skills.folder.appendingPathComponent(slug, isDirectory: true) }
    var file: URL { folder.appendingPathComponent("SKILL.md") }
}

enum Skills {

    static var folder: URL {
        Support.folder.appendingPathComponent("Skills", isDirectory: true)
    }

    /// Which skills are switched on, by slug.
    ///
    /// Kept in preferences rather than in the file, so turning one off for a
    /// while doesn't rewrite a document you may be keeping in version control
    /// somewhere else.
    static var enabled: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: enabledKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: enabledKey) }
    }

    private static let enabledKey = "skills.enabled"

    // MARK: Reading and writing

    /// Every skill on disk, in name order.
    ///
    /// Read from the folder each time rather than cached behind a shared
    /// object. There are a handful of small files, they're read once per
    /// process launch and once per Settings redraw, and a cache would need
    /// invalidating from the one place a person is most likely to change them
    /// from — a text editor, outside the app.
    static func all() -> [Skill] {
        let manager = FileManager.default
        guard let folders = try? manager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey])
        else { return [] }

        return folders
            .compactMap { read(slug: $0.lastPathComponent) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func read(slug: String) -> Skill? {
        let file = folder.appendingPathComponent(slug, isDirectory: true)
            .appendingPathComponent("SKILL.md")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let (front, body) = split(text)
        return Skill(slug: slug,
                     name: front["name"] ?? slug,
                     summary: front["description"] ?? "",
                     body: body)
    }

    @discardableResult
    static func write(_ skill: Skill) -> Bool {
        let document = """
        ---
        name: \(skill.name)
        description: \(skill.summary)
        ---

        \(skill.body)
        """
        do {
            try FileManager.default.createDirectory(at: skill.folder,
                                                    withIntermediateDirectories: true)
            try Data(document.utf8).write(to: skill.file, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func delete(_ skill: Skill) {
        try? FileManager.default.removeItem(at: skill.folder)
        enabled.remove(skill.slug)
    }

    /// A slug that doesn't collide with one already there.
    static func slug(for name: String, avoiding taken: Set<String>) -> String {
        let base = name.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }
            .joined()
            .split(separator: "-").joined(separator: "-")
        let stem = base.isEmpty ? "skill" : base
        guard taken.contains(stem) else { return stem }
        var n = 2
        while taken.contains("\(stem)-\(n)") { n += 1 }
        return "\(stem)-\(n)"
    }

    /// Bring in a `SKILL.md`, or a folder holding one.
    ///
    /// Copied rather than referenced. A skill that lives in a checkout would
    /// stop existing the moment you switched branches, and a set of
    /// instructions every agent depends on shouldn't have that property.
    @discardableResult
    static func imported(from url: URL) -> Skill? {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }

        let source = isDirectory.boolValue ? url.appendingPathComponent("SKILL.md") : url
        guard let text = try? String(contentsOf: source, encoding: .utf8) else { return nil }

        let (front, body) = split(text)
        let name = front["name"]
            ?? (isDirectory.boolValue ? url.lastPathComponent
                                      : url.deletingPathExtension().lastPathComponent)
        let skill = Skill(slug: slug(for: name, avoiding: Set(all().map(\.slug))),
                          name: name,
                          summary: front["description"] ?? "",
                          body: body)
        guard write(skill) else { return nil }

        // Anything alongside the SKILL.md comes too — a skill that references a
        // template or a palette file is a skill that needs the file.
        if isDirectory.boolValue,
           let extras = try? manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
            for extra in extras where extra.lastPathComponent != "SKILL.md" {
                try? manager.copyItem(
                    at: extra, to: skill.folder.appendingPathComponent(extra.lastPathComponent))
            }
        }
        enabled.insert(skill.slug)
        return skill
    }

    /// Front matter and body. A file without front matter is all body, which is
    /// the right reading of a plain markdown file someone dropped in.
    private static func split(_ text: String) -> ([String: String], String) {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let close = lines.dropFirst().firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespaces) == "---"
              })
        else { return ([:], text.trimmingCharacters(in: .whitespacesAndNewlines)) }

        var front: [String: String] = [:]
        for line in lines[1..<close] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon])
                .trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            front[key] = value
        }
        return (front, lines[(close + 1)...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: Reaching the agents

    /// The index handed to every session that starts.
    ///
    /// Descriptions, not bodies. Putting the instructions themselves in here
    /// would spend the context on every turn whether the skill was relevant or
    /// not — which is the mistake that makes people turn a feature like this
    /// off. Empty string when nothing is enabled, so a session that uses no
    /// skills carries no trace of the feature.
    static func preamble() -> String {
        let active = all().filter { enabled.contains($0.slug) }
        guard !active.isEmpty else { return "" }

        let entries = active.map { skill in
            let blurb = skill.summary.isEmpty ? "" : " — \(skill.summary)"
            return "- \(skill.name)\(blurb)\n  Instructions: \(skill.file.path)"
        }.joined(separator: "\n")

        return """

        The person running this app keeps a set of shared skills, available to \
        every agent Honeycode runs. Each one is a file:

        \(entries)

        When a task falls within one of these, read that file first and follow \
        it. Don't read them speculatively, and don't read them all at once — the \
        descriptions above are there so you can tell which, if any, applies.
        """
    }

    /// The enabled skills as slash commands, for the composer's `/` list.
    ///
    /// Marked `isSkill` so they draw with the wand glyph beside the CLI's own,
    /// which is the honest description: from where you're typing they're the
    /// same kind of thing.
    static func commands(excluding known: [AgentCommand]) -> [AgentCommand] {
        let taken = Set(known.map(\.name))
        return all()
            .filter { enabled.contains($0.slug) && !taken.contains($0.slug) }
            .map { AgentCommand(name: $0.slug, detail: $0.summary, isSkill: true) }
    }

    /// Expand `/branding make the deck` into a message that names the skill and
    /// says where to find it.
    ///
    /// Honeycode's, and intercepted before dispatch — the agent receives prose,
    /// not a command it has no definition for. Returns nil for anything that
    /// isn't one of ours, which goes to the agent untouched.
    static func expand(_ text: String) -> String? {
        let (prose, files) = Attached.split(text)
        guard prose.hasPrefix("/") else { return nil }

        let rest = prose.dropFirst()
        let split = rest.firstIndex(where: \.isWhitespace) ?? rest.endIndex
        let name = String(rest[rest.startIndex..<split])
        guard let skill = all().first(where: { $0.slug == name && enabled.contains($0.slug) })
        else { return nil }

        let argument = String(rest[split...]).trimmingCharacters(in: .whitespacesAndNewlines)
        var message = "Use the \(skill.name) skill for this. Its instructions are at "
            + "\(skill.file.path) — read that file first, then follow it."
        if !argument.isEmpty { message += "\n\n" + argument }
        // The attachment lines go back on the end, where `Session.send` and the
        // CLI both expect them.
        if !files.isEmpty {
            message += "\n" + files.map { "@\($0.path)" }.joined(separator: "\n")
        }
        return message
    }
}

/// The skills list, for Settings.
///
/// A view model over `Skills`, which is the real thing. It exists because a
/// `Form` needs something to observe and `Skills` is a folder on disk — not
/// because the folder needs a cache.
@MainActor
final class SkillStore: ObservableObject {
    static let shared = SkillStore()

    @Published private(set) var skills: [Skill] = []

    private init() { reload() }

    func reload() { skills = Skills.all() }

    func isEnabled(_ skill: Skill) -> Bool { Skills.enabled.contains(skill.slug) }

    func setEnabled(_ skill: Skill, _ on: Bool) {
        var current = Skills.enabled
        if on { current.insert(skill.slug) } else { current.remove(skill.slug) }
        Skills.enabled = current
        objectWillChange.send()
    }

    @discardableResult
    func add(name: String = "New Skill") -> Skill {
        let skill = Skill(slug: Skills.slug(for: name, avoiding: Set(skills.map(\.slug))),
                          name: name,
                          summary: "",
                          body: "")
        Skills.write(skill)
        Skills.enabled.insert(skill.slug)
        reload()
        return skill
    }

    func update(_ skill: Skill) {
        Skills.write(skill)
        reload()
    }

    func remove(_ skill: Skill) {
        Skills.delete(skill)
        reload()
    }

    func importFrom(_ url: URL) {
        Skills.imported(from: url)
        reload()
    }
}
