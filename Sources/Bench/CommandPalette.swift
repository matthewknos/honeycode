import SwiftUI

/// ⌘K — jump to any session, or start a new one.
///
/// Deliberately not a `.sheet`. A sheet slides from the titlebar and takes the
/// whole window hostage; a palette is a transient overlay you dismiss with Esc
/// without the window ever feeling modal.
///
/// Ranking is subsequence matching, not substring: "wfs" finds
/// "workday-foresight". Substring matching is the thing that makes a palette
/// feel dumb, because it fails exactly when you type the way you think.
struct CommandPalette: View {
    @ObservedObject var workspace: Workspace
    @Binding var isPresented: Bool

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    /// One hit — a session, and optionally the line of transcript that matched.
    struct Hit: Identifiable {
        let session: Session
        var excerpt: String?
        var id: String { session.id.uuidString + (excerpt ?? "") }
    }

    private var matches: [Hit] {
        let all = Account.allCases.flatMap { workspace.sessions(in: $0) }
        guard !query.isEmpty else { return all.map { Hit(session: $0) } }

        var hits = all
            .compactMap { session -> (Hit, Int)? in
                guard let score = Self.score(query, in: session.name + " " + session.subtitle)
                else { return nil }
                return (Hit(session: session), score)
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)

        // Then the transcripts themselves. Substring, not subsequence: fuzzy
        // matching is right for picking a name you half-remember and wrong for
        // finding a phrase you actually wrote — "auth" would match half the
        // prose in the app.
        let needle = query.lowercased()
        guard needle.count >= 3 else { return hits }
        let named = Set(hits.map(\.session.id))

        for session in all {
            for item in session.items {
                guard let text = Self.text(of: item),
                      let range = text.lowercased().range(of: needle) else { continue }
                hits.append(Hit(session: session, excerpt: Self.excerpt(text, around: range)))
                break   // one hit per session keeps the list scannable
            }
        }
        return hits.filter { $0.excerpt != nil || named.contains($0.session.id) }
    }

    private static func text(of item: TranscriptItem) -> String? {
        switch item {
        case .user(_, let text), .assistant(_, let text), .notice(_, let text):
            return text
        default:
            return nil
        }
    }

    /// A window of context around the match, so the row shows why it matched.
    private static func excerpt(_ text: String, around range: Range<String.Index>) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard let start = flat.range(of: text[range]) else { return String(flat.prefix(90)) }
        let lead = flat.index(start.lowerBound, offsetBy: -40,
                              limitedBy: flat.startIndex) ?? flat.startIndex
        let tail = flat.index(start.upperBound, offsetBy: 60,
                              limitedBy: flat.endIndex) ?? flat.endIndex
        var out = String(flat[lead..<tail]).trimmingCharacters(in: .whitespaces)
        if lead != flat.startIndex { out = "…" + out }
        if tail != flat.endIndex { out += "…" }
        return out
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Backdrop: click anywhere to dismiss.
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            card
                .padding(.top, 120)
        }
        .transition(.opacity)
    }

    private var card: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.s4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                TextField("Jump to a session, or search what was said…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                    .onSubmit(activate)
            }
            .padding(.horizontal, Theme.s6)
            .padding(.vertical, Theme.s5)

            if !matches.isEmpty {
                Divider().overlay(Theme.rule)
                results
            }
        }
        .frame(width: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.rule, lineWidth: 1))
        .shadow(color: .black.opacity(0.28), radius: 28, y: 10)
        .onAppear { focused = true }
        // Arrow keys move the highlight; the list scrolls to follow.
        .onMoveCommand { direction in
            switch direction {
            case .down: highlighted = min(highlighted + 1, matches.count - 1)
            case .up:   highlighted = max(highlighted - 1, 0)
            default:    break
            }
        }
        .onExitCommand { isPresented = false }
        .onChange(of: query) { _, _ in highlighted = 0 }
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(matches.enumerated()), id: \.element.id) { index, hit in
                        row(hit, active: index == highlighted)
                            .id(hit.id)
                            .onTapGesture {
                                workspace.selection = hit.session.id
                                isPresented = false
                            }
                    }
                }
                .padding(Theme.s3)
            }
            .frame(maxHeight: 320)
            .onChange(of: highlighted) { _, new in
                guard matches.indices.contains(new) else { return }
                proxy.scrollTo(matches[new].id, anchor: .bottom)
            }
        }
    }

    private func row(_ hit: Hit, active: Bool) -> some View {
        let session = hit.session
        return HStack(alignment: .top, spacing: Theme.s4) {
            Circle()
                .fill(session.account.accent)
                .frame(width: 6, height: 6)
                .frame(width: 12, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.s4) {
                    Text(session.name)
                        .font(.system(size: 13.5))
                    if hit.excerpt == nil {
                        Text(session.subtitle)
                            .font(Theme.monoSmall)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer(minLength: Theme.s4)
                    Text(session.account.title)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.quaternary)
                }
                // The matched line, so you can tell which of four hits is the
                // one you meant without opening all four.
                if let excerpt = hit.excerpt {
                    Text(excerpt)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, Theme.s5)
        .padding(.vertical, Theme.s3)
        .background(active ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: Theme.cornerCard - 2))
        .contentShape(Rectangle())
    }

    private func activate() {
        guard matches.indices.contains(highlighted) else { return }
        workspace.selection = matches[highlighted].session.id
        isPresented = false
    }

    /// Subsequence match. Returns a rough cost — lower is better — so that
    /// tighter, earlier matches sort first. `nil` means no match at all.
    static func score(_ needle: String, in haystack: String) -> Int? {
        let query = Array(needle.lowercased())
        let target = Array(haystack.lowercased())
        var qi = 0, cost = 0, lastHit = -1

        for (index, character) in target.enumerated() where qi < query.count {
            guard character == query[qi] else { continue }
            if lastHit >= 0 { cost += index - lastHit - 1 }   // gaps are penalised
            else { cost += index }                            // so is a late start
            lastHit = index
            qi += 1
        }
        return qi == query.count ? cost : nil
    }
}
