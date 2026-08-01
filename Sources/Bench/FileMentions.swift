import SwiftUI
import AppKit

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
                guard let score = CommandPalette.score(query, in: command.name)
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
    func matches(_ query: String, limit: Int = 7) -> [String] {
        guard !query.isEmpty else { return Array(paths.prefix(limit)) }
        return paths
            .compactMap { path -> (String, Int)? in
                guard let score = CommandPalette.score(query, in: path) else { return nil }
                // A hit in the filename beats the same hit buried in a
                // directory name — you type `mod` meaning Models.swift, not
                // `modules/thing/other.swift`.
                let name = (path as NSString).lastPathComponent
                let bonus = CommandPalette.score(query, in: name) != nil ? 0 : 40
                return (path, score + bonus)
            }
            .sorted { $0.1 < $1.1 }
            .prefix(limit)
            .map(\.0)
    }
}

/// The completion list, shown above the composer while a mention is live.
struct MentionList: View {
    let matches: [String]
    let highlighted: Int
    let onSelect: (String) -> Void

    @EnvironmentObject private var background: BackgroundStore

    var body: some View {
        CompletionPanel {
            ForEach(Array(matches.enumerated()), id: \.element) { index, path in
                row(path, active: index == highlighted)
                    .onTapGesture { onSelect(path) }
            }
        }
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
            .shadow(color: .black.opacity(0.16), radius: 14, y: 5)
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
