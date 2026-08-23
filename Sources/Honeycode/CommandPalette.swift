import AppKit
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
    /// Whether choosing opens a new column rather than replacing the one you
    /// were in.
    ///
    /// The palette is where ⌘D sends you, because "open beside" needs a subject
    /// and the focused session can't be it — it's already on screen. Picking
    /// the session and picking the side are one action this way, rather than a
    /// key that does nothing until you've selected something else first.
    var beside = false

    @State private var query = ""
    @State private var highlighted = 0
    @State private var keyMonitor: Any?
    @FocusState private var focused: Bool

    /// One hit — a session, and optionally the line of transcript that matched.
    struct Hit: Identifiable {
        let session: Session
        var excerpt: String?
        var id: String { session.id.uuidString + (excerpt ?? "") }
    }

    /// The current result set.
    ///
    /// Held rather than computed. As a computed property this ran several times
    /// per body evaluation — the empty check, the list, the scroll observer,
    /// `activate()` — and each run lowercased and substring-scanned every
    /// transcript item of every session. Now it runs once per settled query.
    @State private var matches: [Hit] = []

    private func search(_ query: String) -> [Hit] {
        let all = Account.allCases.flatMap { workspace.sessions(in: $0) }
        guard !query.isEmpty else { return all.map { Hit(session: $0) } }

        var hits = all
            .compactMap { session -> (Hit, Int)? in
                guard let score = Fuzzy.score(query, in: session.name + " " + session.subtitle)
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

        // Only sessions that didn't already match by name. A session called
        // "auth" that also says "auth" in its transcript is one session, and
        // listing it twice — once bare, once with an excerpt — reads as a bug.
        for session in all where !named.contains(session.id) {
            for item in session.items {
                guard let text = Self.text(of: item),
                      text.range(of: needle, options: .caseInsensitive) != nil else { continue }
                hits.append(Hit(session: session, excerpt: Self.excerpt(text, matching: needle)))
                break   // one hit per session keeps the list scannable
            }
        }
        return hits
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
    ///
    /// The needle is re-found in the flattened text rather than handed down as
    /// a range. The range used to come from `text.lowercased()` and be applied
    /// to `text`, which holds only while lowercasing preserves length — it
    /// doesn't for every script (Turkish İ, among others), and the mis-slice
    /// there is a trap, not a wrong answer.
    private static func excerpt(_ text: String, matching needle: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard let start = flat.range(of: needle, options: .caseInsensitive) else {
            return String(flat.prefix(90))
        }
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
                TextField(beside ? "Open a session in a new column…"
                                 : "Jump to a session, or search what was said…",
                          text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: Theme.t6))
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.cornerFloat))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerFloat)
            .strokeBorder(Theme.rule, lineWidth: 1))
        .modifier(Elevated(depth: .float))
        .onAppear {
            focused = true
            installKeyMonitor()
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
        .onExitCommand { isPresented = false }
        // Debounced, so holding a key down doesn't run a transcript-wide scan
        // per character. 90ms is below the threshold where a list feels like
        // it's lagging your typing, and above a fast typist's inter-key gap.
        .task(id: query) {
            if !query.isEmpty {
                try? await Task.sleep(for: .milliseconds(90))
                guard !Task.isCancelled else { return }
            }
            highlighted = 0
            matches = search(query)
        }
    }

    /// Arrow keys, taken before the search field sees them.
    ///
    /// `.onMoveCommand` was the spelling here and it never fired: the field
    /// holds focus, a focused `TextField` handles arrows itself to move the
    /// caret, and SwiftUI only forwards what the focused control declines. So
    /// the highlight never moved and Return always opened the first match. The
    /// composer learned this already; this is the same monitor.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard isPresented else { return event }
            switch event.keyCode {
            case 125:                                   // down
                highlighted = min(highlighted + 1, max(0, matches.count - 1))
                return nil
            case 126:                                   // up
                highlighted = max(highlighted - 1, 0)
                return nil
            case 53:                                    // escape
                isPresented = false
                return nil
            default:
                return event
            }
        }
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(matches.enumerated()), id: \.element.id) { index, hit in
                        row(hit, active: index == highlighted)
                            .id(hit.id)
                            .onTapGesture {
                                choose(hit.session)
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

    private func choose(_ session: Session) {
        if beside { workspace.openBeside(session.id) } else { workspace.selection = session.id }
    }

    private func row(_ hit: Hit, active: Bool) -> some View {
        let session = hit.session
        return HStack(alignment: .top, spacing: Theme.s4) {
            AccountDot(session.account, gutter: 12)
                .frame(height: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.s4) {
                    Text(session.name)
                        .font(Theme.body)
                    if hit.excerpt == nil {
                        Text(session.subtitle)
                            .font(Theme.monoSmall)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer(minLength: Theme.s4)
                    Text(session.account.title)
                        .font(Theme.captionStrong)
                        .foregroundStyle(.secondary)
                }
                // The matched line, so you can tell which of four hits is the
                // one you meant without opening all four.
                if let excerpt = hit.excerpt {
                    Text(excerpt)
                        .font(Theme.note)
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
        choose(matches[highlighted].session)
        isPresented = false
    }

}
