import SwiftUI

/// Where a `@` mention starts, if the caret is inside one.
///
/// The boundary rule is the whole point. Matching any `@` in the field would
/// pop a file list open in the middle of `matthew@example.com`, `user@host`, and
/// every Objective-C keyword — so a mention only begins at the start of the
/// field, after whitespace, or after an opening bracket or quote, and ends at
/// the first space.
enum Mention {
    private static let openers: Set<Character> = ["(", "[", "{", "\"", "'", "`", "<"]

    /// The range of the live mention, `@` included. `nil` when there isn't one.
    ///
    /// Scans from the end because that's where the caret is while typing, which
    /// is when this matters. A mention completed earlier in the line already has
    /// a space after it and is deliberately left alone.
    static func range(in text: String) -> Range<String.Index>? {
        guard let at = text.lastIndex(of: "@") else { return nil }

        let tail = text[text.index(after: at)...]
        guard !tail.contains(where: \.isWhitespace) else { return nil }

        if at > text.startIndex {
            let previous = text[text.index(before: at)]
            guard previous.isWhitespace || openers.contains(previous) else { return nil }
        }
        return at..<text.endIndex
    }

    static func query(in text: String, range: Range<String.Index>) -> String {
        String(text[text.index(after: range.lowerBound)..<range.upperBound])
    }
}

/// One row of the `@` list.
///
/// `@` used to mean a file and only a file. It now means "something to bring
/// into this message", and there are two kinds: an agent, which joins the
/// conversation, and a file, which is pointed at. Berd reached the same place
/// from the other direction and answered it with three categories you cycle
/// between; two, ranked together in one list, is the smaller answer — there are
/// four agents and forty thousand files, so which one you meant is nearly
/// always obvious from what you have typed, and a category toggle would be a
/// control you had to operate to get to the common case.
///
/// Skills stay under `/` where they already are, which is why this is two
/// categories and not three.
enum MentionCandidate: Hashable {
    case agent(Account)
    case file(String)
    /// A model or an effort level for an agent already typed — the list you get
    /// from `@kimi:`.
    ///
    /// The grammar existed before this did, and that was most of the problem
    /// with it: `@copilot:free` is documented in one doc comment and one help
    /// text, so the people who knew about it were the people who had read the
    /// source. A crew ran Kimi on the wrong model for an hour because the lead
    /// didn't know a suffix was allowed, and the person asking for K3 had no
    /// way to see that asking in prose wasn't the same as asking in grammar.
    case qualifier(Qualifier)
}

/// One row of the list under `@handle:`.
struct Qualifier: Hashable {
    enum Kind: Hashable { case model, effort }
    let kind: Kind
    /// Everything already typed, minus the segment being completed: `kimi`, or
    /// `kimi:k3` when a model is already chosen and an effort is being added.
    let base: String
    /// What choosing this row appends.
    let value: String
    let title: String
    let detail: String
}

extension Mention {

    /// Every agent whose handle matches, best first.
    ///
    /// Matched against the canonical handle and the account's title, so both
    /// `@ent` and `@claude-w` find Enterprise. The aliases in
    /// `AgentMention.names` are deliberately not offered: `personal`, `work`
    /// and `claude-p` all resolve to the same account, and a list showing three
    /// rows that do the same thing is a choice between things that aren't
    /// different.
    static func agents(_ query: String) -> [Account] {
        guard !query.isEmpty else { return Account.enabled }
        return Account.enabled
            .compactMap { account -> (Account, Int)? in
                let handle = AgentMention.handle(account)
                let scores = [Fuzzy.score(query, in: handle),
                              Fuzzy.score(query, in: account.title)].compactMap { $0 }
                guard let best = scores.min() else { return nil }
                return (account, best)
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    /// The list under a live `@`: agents first, then files.
    ///
    /// Agents lead because there are four of them and they are the ones you
    /// can't discover any other way — a file has the `+` button, the drop
    /// target and the palette, whereas nothing else in the window tells you
    /// that typing `@kimi` here hands a piece of the work to Kimi. They are
    /// also cheap to be wrong about: four rows costs one glance, and a file
    /// query almost never matches a handle.
    @MainActor
    static func candidates(_ query: String, files: FileIndex,
                           limit: Int = 7) -> [MentionCandidate] {
        // A colon means the agent is already chosen and the question has moved
        // on to how it should run. Files drop out entirely at that point:
        // `@kimi:` cannot be a path, so offering one would be offering
        // something that can't be meant.
        if query.contains(":") {
            return qualifiers(query, limit: limit)
        }
        let agents = agents(query).prefix(query.isEmpty ? 4 : 3)
        let room = limit - agents.count
        return agents.map(MentionCandidate.agent)
            + files.matches(query, limit: max(0, room)).map(MentionCandidate.file)
    }

    /// The models and effort levels available to the agent already typed.
    ///
    /// Intents lead — `free`, `cheap`, `best` — because they are the ones worth
    /// knowing: they resolve against the quota multiplier the agent itself
    /// reports, so they stay right as the line-up changes, and `free` is the
    /// one that actually saves you something.
    static func qualifiers(_ query: String, limit: Int) -> [MentionCandidate] {
        let segments = query.split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init)
        guard let handle = segments.first,
              let account = AgentMention.account(forHandle: handle) else { return [] }
        let typed = segments.dropFirst().dropLast().map { $0.lowercased() }
        let partial = segments.last ?? ""
        let base = ([AgentMention.handle(account)] + typed).joined(separator: ":")

        // What's already been said doesn't get offered again. `@kimi:k3:` is
        // asking about effort, and a second model would replace the first
        // silently — `qualify` keeps the first of each kind.
        let hasEffort = typed.contains { EffortChoice(rawValue: $0) != nil }
        let hasModel = typed.contains { EffortChoice(rawValue: $0) == nil }

        var rows: [Qualifier] = []
        if !hasModel {
            for intent in ModelPick.intents {
                rows.append(Qualifier(kind: .model, base: base, value: intent,
                                      title: intent,
                                      detail: Self.intentBlurb(intent)))
            }
            for model in ModelCatalog.models(for: account) {
                rows.append(Qualifier(kind: .model, base: base, value: model.id,
                                      title: model.title,
                                      detail: model.usage.map {
                                          $0 == 0 ? "free" : "\($0)× usage"
                                      } ?? model.family))
            }
        }
        // Effort is a Claude launch flag; ACP has no notion of it, so offering
        // it on Copilot would be offering a setting that doesn't exist there.
        if account.hasEffort, !hasEffort {
            for level in EffortChoice.allCases {
                rows.append(Qualifier(kind: .effort, base: base, value: level.rawValue,
                                      title: level.title, detail: "reasoning effort"))
            }
        }

        guard !partial.isEmpty else { return rows.prefix(limit).map(MentionCandidate.qualifier) }
        return rows
            .compactMap { row -> (Qualifier, Int)? in
                let scores = [Fuzzy.score(partial, in: row.value),
                              Fuzzy.score(partial, in: row.title)].compactMap { $0 }
                guard let best = scores.min() else { return nil }
                return (row, best)
            }
            .sorted { $0.1 < $1.1 }
            .prefix(limit)
            .map { MentionCandidate.qualifier($0.0) }
    }

    /// Whether choosing this row finishes the mention.
    ///
    /// A model on a Claude account doesn't: effort is the natural next
    /// question, the list is already open, and closing it with a space would
    /// mean deleting that space to ask. Everything else does — a file, an
    /// agent, an effort level, a model on an account with no effort — because
    /// there is nothing left to say about it.
    static func completes(_ candidate: MentionCandidate) -> Bool {
        guard case .qualifier(let value) = candidate, value.kind == .model,
              let handle = value.base.split(separator: ":").first.map(String.init),
              let account = AgentMention.account(forHandle: handle),
              account.hasEffort else { return true }
        return false
    }

    private static func intentBlurb(_ intent: String) -> String {
        switch intent {
        case "free":  return "nothing off the quota, where there is one"
        case "cheap", "fast": return "the least expensive on offer"
        case "best":  return "the most capable on offer"
        case "auto":  return "let the agent decide"
        default:      return ""
        }
    }

    /// What gets written into the draft when a row is chosen.
    static func insertion(for candidate: MentionCandidate) -> String {
        switch candidate {
        case .agent(let account):   return AgentMention.handle(account)
        case .file(let path):       return path
        case .qualifier(let value): return value.base + ":" + value.value
        }
    }
}

/// Where a `/` command starts, if the caret is inside one.
///
/// Stricter than a mention on purpose: a slash command is only a command when
/// it's the *first* thing in the message. Anywhere else it's a path, a date, or
/// arithmetic — `src/main.swift` must not open a command list.
enum SlashCommand {
    static func range(in text: String) -> Range<String.Index>? {
        guard text.hasPrefix("/") else { return nil }
        let body = text.dropFirst()
        // Once there's a space the command is chosen and you're typing its
        // argument, so the list gets out of the way.
        guard !body.contains(where: \.isWhitespace) else { return nil }
        return text.startIndex..<text.endIndex
    }

    static func query(in text: String) -> String { String(text.dropFirst()) }

    /// Ranked by the same subsequence match the palette uses.
    static func matches(_ query: String, in commands: [AgentCommand],
                        limit: Int = 7) -> [AgentCommand] {
        guard !commands.isEmpty else { return [] }
        guard !query.isEmpty else { return Array(commands.prefix(limit)) }
        return commands
            .compactMap { command -> (AgentCommand, Int)? in
                guard let score = Fuzzy.score(query, in: command.name)
                else { return nil }
                return (command, score)
            }
            .sorted { $0.1 < $1.1 }
            .prefix(limit)
            .map(\.0)
    }
}

/// The files in a session's directory, for mention completion.
///
/// Built once per session, off the main queue, and held for the session's life.
/// Rebuilding on every keystroke would walk a large checkout thousands of times;
/// going stale for the odd file created mid-session is the cheaper mistake, and
/// the `+` button still reaches anything the index missed.
@MainActor
final class FileIndex: ObservableObject {
    @Published private(set) var paths: [String] = []
    @Published private(set) var loading = false

    private var loadedAt: Date?

    /// Directories that are always noise in a mention list and expensive to
    /// walk. Skipped wholesale rather than filtered afterwards.
    nonisolated private static let skipped: Set<String> = [
        ".git", "node_modules", ".build", "build", "dist", ".next", "out",
        "DerivedData", "Pods", "target", "vendor", "venv", ".venv",
        "__pycache__", ".mypy_cache", ".pytest_cache", ".cache", ".gradle",
    ]

    /// Enough to cover any repo worth opening, and a hard stop so a stray
    /// symlink into the home folder can't hang the composer.
    nonisolated private static let limit = 40_000

    /// Rescan if the index is older than `maxAge`.
    ///
    /// It used to build exactly once and never again, which meant files the
    /// agent created during the session were invisible to `@` for the rest of
    /// it — precisely the files you'd most want to mention. The old list stays
    /// on screen while the rescan runs, so completion never blanks out.
    func load(root: URL, maxAge: TimeInterval = 20) {
        guard !loading else { return }
        if let loadedAt, Date().timeIntervalSince(loadedAt) < maxAge { return }
        loadedAt = Date()
        loading = true

        Task.detached(priority: .userInitiated) {
            let found = Self.scan(root)
            await MainActor.run {
                self.paths = found
                self.generation += 1
                self.loadedAt = Date()
                self.loading = false
            }
        }
    }

    nonisolated private static func scan(_ root: URL) -> [String] {
        let manager = FileManager.default
        guard let walker = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }

        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var result: [String] = []

        for case let url as URL in walker {
            if result.count >= limit { break }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory ?? false
            if isDirectory {
                if skipped.contains(url.lastPathComponent) { walker.skipDescendants() }
                continue
            }
            guard url.path.hasPrefix(prefix) else { continue }
            result.append(String(url.path.dropFirst(prefix.count)))
        }

        // Shallow first, then alphabetical: with no query typed yet, the files
        // at the root of a project are the ones you actually mean.
        return result.sorted {
            let a = $0.count(where: { $0 == "/" }), b = $1.count(where: { $0 == "/" })
            return a == b ? $0.localizedStandardCompare($1) == .orderedAscending : a < b
        }
    }

    /// Ranked matches. Empty query returns the head of the index rather than
    /// nothing, so `@` on its own is still useful.
    /// The last answer, kept because the composer asks the same question
    /// several times per redraw — from the list, from the completion count, and
    /// from the hint line — and each ask scores every indexed path twice.
    private var memo: (query: String, generation: Int, result: [String])?

    /// Bumped whenever the index is replaced, so a rescan can't be served a
    /// stale answer.
    private var generation = 0

    func matches(_ query: String, limit: Int = 7) -> [String] {
        guard !query.isEmpty else { return Array(paths.prefix(limit)) }
        if let memo, memo.query == query, memo.generation == generation { return memo.result }
        let result = score(query, limit: limit)
        memo = (query, generation, result)
        return result
    }

    private func score(_ query: String, limit: Int) -> [String] {
        paths
            .compactMap { path -> (String, Int)? in
                guard let score = Fuzzy.score(query, in: path) else { return nil }
                // A hit in the filename beats the same hit buried in a
                // directory name — you type `mod` meaning Models.swift, not
                // `modules/thing/other.swift`.
                let name = (path as NSString).lastPathComponent
                let bonus = Fuzzy.score(query, in: name) != nil ? 0 : 40
                return (path, score + bonus)
            }
            .sorted { $0.1 < $1.1 }
            .prefix(limit)
            .map(\.0)
    }
}

/// The completion list, shown above the composer while a mention is live.
struct MentionList: View {
    let matches: [MentionCandidate]
    let highlighted: Int
    let onSelect: (MentionCandidate) -> Void

    var body: some View {
        CompletionPanel {
            ForEach(Array(matches.enumerated()), id: \.element) { index, candidate in
                Group {
                    switch candidate {
                    case .agent(let account):   agentRow(account, active: index == highlighted)
                    case .file(let path):       row(path, active: index == highlighted)
                    case .qualifier(let value): qualifierRow(value, active: index == highlighted)
                    }
                }
                .onTapGesture { onSelect(candidate) }
            }
        }
    }

    /// An agent reads differently from a file on purpose. The dot carries the
    /// account's own colour — the same one the sidebar and the terminal use —
    /// so the four handles are recognisable before the name is read, and the
    /// blurb says what the row will actually do, which for the first few weeks
    /// is the entire point of the feature being discoverable at all.
    private func agentRow(_ account: Account, active: Bool) -> some View {
        HStack(spacing: Theme.s4) {
            AccountDot(account, gutter: 12)
            Text("@" + AgentMention.handle(account))
                .font(.system(size: 12.5))
                .lineLimit(1)
            Text(account.title)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("helps with this")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Theme.s4)
        .padding(.vertical, Theme.s3 - 1)
        .background(active ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: Theme.cornerCard - 2))
        .contentShape(Rectangle())
    }

    /// Model and effort read as settings rather than as names: a symbol that
    /// says which of the two this is, the label, and what it costs or means. The
    /// value is shown as it will be written, because the point of the list is
    /// that you stop having to know how to write it.
    private func qualifierRow(_ value: Qualifier, active: Bool) -> some View {
        HStack(spacing: Theme.s4) {
            Image(systemName: value.kind == .model ? "cpu" : "brain")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(width: 12)
            Text(value.title)
                .font(.system(size: 12.5))
                .lineLimit(1)
            Text(value.detail)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: Theme.s4)
            Text(":" + value.value)
                .font(Theme.monoSmall)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, Theme.s4)
        .padding(.vertical, Theme.s3 - 1)
        .background(active ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: Theme.cornerCard - 2))
        .contentShape(Rectangle())
    }

    private func row(_ path: String, active: Bool) -> some View {
        // Filename leading, directory trailing and dimmed — the same split the
        // Finder path bar and Xcode's Open Quickly both use, and it puts the
        // part you searched for at the left edge where you're already looking.
        let name = (path as NSString).lastPathComponent
        let parent = (path as NSString).deletingLastPathComponent

        return HStack(spacing: Theme.s4) {
            Image(systemName: "doc")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(width: 12)
            Text(name)
                .font(.system(size: 12.5))
                .lineLimit(1)
            if !parent.isEmpty {
                Text(parent)
                    .font(Theme.monoSmall)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.s4)
        .padding(.vertical, Theme.s3 - 1)
        .background(active ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: Theme.cornerCard - 2))
        .contentShape(Rectangle())
    }
}

/// The shared container for both completion lists.
struct CompletionPanel<Content: View>: View {
    @EnvironmentObject private var background: BackgroundStore
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(Theme.s2)
            .modifier(RaisedSurface(glass: background.isGlassy, radius: Theme.cornerCard))
            .modifier(Elevated(depth: .high))
    }
}

/// Slash commands, shown the same way file mentions are.
struct CommandList: View {
    let matches: [AgentCommand]
    let highlighted: Int
    let onSelect: (AgentCommand) -> Void

    var body: some View {
        CompletionPanel {
            ForEach(Array(matches.enumerated()), id: \.element) { index, command in
                row(command, active: index == highlighted)
                    .onTapGesture { onSelect(command) }
            }
        }
    }

    private func row(_ command: AgentCommand, active: Bool) -> some View {
        HStack(spacing: Theme.s4) {
            // Skills come from your own config rather than the CLI, so they get
            // their own glyph — otherwise a list of 58 entries reads as one
            // undifferentiated pile.
            Image(systemName: command.isSkill ? "wand.and.stars" : "slash.circle")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(width: 12)
            Text("/" + command.name)
                .font(.system(size: 12.5))
                .lineLimit(1)
            if !command.detail.isEmpty {
                Text(command.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.s4)
        .padding(.vertical, Theme.s3 - 1)
        .background(active ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: Theme.cornerCard - 2))
        .contentShape(Rectangle())
    }
}
