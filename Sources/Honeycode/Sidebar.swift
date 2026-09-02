import SwiftUI
import AppKit

/// The list of sessions, grouped by account.
///
/// Lifted out of `RootView`, which had grown to nine types and seventeen
/// hundred lines. Nothing here changed in the move. The sidebar is a surface
/// somebody works on by itself — a row's hover state, what the account header
/// counts, how a session is renamed — and having to find it inside the file
/// that also owns the window, the column layout, the session detail and the
/// status rail made every one of those a search rather than an open.
// MARK: - Sidebar list

struct SidebarList: View {
    @ObservedObject var workspace: Workspace
    @EnvironmentObject private var background: BackgroundStore

    /// What you have typed into the filter.
    ///
    /// Not the command palette, and deliberately a second thing. The palette is
    /// a way to *go* somewhere — it takes over the window, it searches inside
    /// transcripts, and it closes when you pick. This narrows the list you are
    /// already looking at and leaves it narrowed, which is what you want while
    /// working through six sessions on one account and ignoring the other
    /// eleven.
    @State private var filter = ""
    @FocusState private var filtering: Bool

    private func matches(_ account: Account) -> [Session] {
        let all = workspace.sessions(in: account)
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return all }
        return all.filter {
            $0.name.lowercased().contains(query)
                || $0.directory.lastPathComponent.lowercased().contains(query)
        }
    }

    /// Accounts with something to show. While filtering, an account whose
    /// sessions all failed the test is a header with nothing under it.
    private var accounts: [Account] {
        let listed = workspace.listedAccounts
        guard !filter.trimmingCharacters(in: .whitespaces).isEmpty else { return listed }
        return listed.filter { !matches($0).isEmpty }
    }

    private var shown: Int { accounts.reduce(0) { $0 + matches($1).count } }

    var body: some View {
        VStack(spacing: 0) {
            field

            List(selection: $workspace.selection) {
                ForEach(accounts) { account in
                    // The setter honours the value it's given rather than blindly
                    // toggling. SwiftUI writes to this binding on its own schedule —
                    // during layout, on focus changes — and a setter that ignores
                    // the new value turns every one of those into a collapse. That
                    // read as "clicking a session doesn't work": the row you aimed
                    // at had folded away underneath the cursor.
                    Section(isExpanded: Binding(
                        get: { !workspace.collapsed.contains(account) },
                        set: { open in workspace.setCollapsed(account, !open) }
                    )) {
                        ForEach(matches(account)) { session in
                            SessionRow(session: session, workspace: workspace)
                                .tag(session.id)
                        }
                    } header: {
                        AccountHeader(account: account, workspace: workspace,
                                      count: matches(account).count)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            // Two lines per row now — a name and what it is — so the floor that
            // fitted one has to come up with it.
            .environment(\.defaultMinListRowHeight, 38)

            hint
        }
    }

    private var field: some View {
        HStack(spacing: Theme.s3) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            TextField("Filter sessions", text: $filter)
                .textFieldStyle(.plain)
                .font(Theme.note)
                .focused($filtering)
                // Esc clears rather than unfocusing. A filter you cannot see
                // the end of is a list that looks like it has lost sessions.
                .onExitCommand { filter = "" }
            if !filter.isEmpty {
                Button { filter = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, Theme.s4)
        .frame(height: 24)
        .modifier(FieldSurface(glass: background.isGlassy, focused: filtering))
        .padding(.horizontal, Theme.s5)
        .padding(.bottom, Theme.s5)
        .animation(Motion.reveal, value: filter.isEmpty)
    }

    /// The count, and the keys that walk the list.
    ///
    /// ⌘⌥↑↓ has stepped through every session across account boundaries since
    /// it was written and nothing has ever said so. The count beside it is what
    /// makes the filter legible: "3" under a field you have typed in tells you
    /// the other eleven are hidden rather than gone.
    private var hint: some View {
        HStack(spacing: Theme.s3) {
            Text(shown == 1 ? "1 session" : "\(shown) sessions")
                .font(Theme.caption)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Spacer(minLength: Theme.s3)
            KeyCap(Shortcuts.previousSession.display)
            KeyCap(Shortcuts.nextSession.display)
            Text("to move")
                .font(Theme.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Theme.s5)
        .frame(height: 22)
    }
}

private struct AccountHeader: View {
    let account: Account
    @ObservedObject var workspace: Workspace
    /// How many rows are under this header *right now* — which is not the same
    /// as how many sessions the account has, once the filter is typed in.
    var count: Int
    @State private var hovering = false

    private var hiddenAttention: Bool {
        workspace.collapsed.contains(account)
            && workspace.sessions(in: account).contains { $0.needsAttention || $0.isRunning }
    }

    var body: some View {
        HStack(spacing: Theme.s3) {
            Text(account.title)
                .font(Theme.label)
                .foregroundStyle(.secondary)

            Text("\(count)")
                .font(Theme.caption)
                .monospacedDigit()
                .foregroundStyle(.quaternary)

            if hiddenAttention {
                AccountDot(account, size: Theme.dotAttention)
            }

            Spacer(minLength: 0)

            Button {
                workspace.requestNewSession(account)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Faded rather than inserted: an `if` here rebuilt the header's
            // layout on every hover, so the account name twitched sideways as
            // the button appeared and again as it left.
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
            .help("New \(account.title) session")
        }
        .padding(.trailing, Theme.s1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Motion.reveal, value: hovering)
    }
}

private struct SessionRow: View {
    @ObservedObject var session: Session
    @ObservedObject var workspace: Workspace

    @State private var renaming = false
    @State private var draftName = ""
    @State private var hovering = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        HStack(spacing: Theme.s4) {
            SessionAvatar(account: session.account, provisional: session.isEphemeral)

            VStack(alignment: .leading, spacing: Theme.s1) {
                HStack(spacing: Theme.s2) {
                    if renaming {
                        TextField("", text: $draftName)
                            .textFieldStyle(.plain)
                            .font(Theme.sidebarRow)
                            .focused($nameFocused)
                            .onSubmit(commit)
                            .onExitCommand { renaming = false }
                    } else {
                        Text(session.name)
                            .font(Theme.sidebarRow)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    // Beside the name rather than in the slot on the right,
                    // which is already spoken for and cross-fades on hover.
                    // Isolation is a property of the conversation, like its
                    // name — not a transient state like running or unread — so
                    // it shouldn't come and go as the pointer moves.
                    if session.isolated {
                        Image(systemName: "lock")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .help("Isolated to \(session.subtitle)")
                    }
                }

                // The second line, which the row never had.
                //
                // A list of nine names is a list you have to remember the
                // meaning of: two sessions called "wiki" on two accounts in two
                // folders were one row repeated. Agent, folder and how long ago
                // are the three things that tell them apart, and they fit.
                meta
            }

            Spacer(minLength: Theme.s2)

            // One fixed slot, three possible occupants, cross-faded.
            //
            // These used to be alternatives in an `if`, each a different width,
            // so the name shifted left and right as you moved the pointer down
            // the list — and a running session's spinner jumped position the
            // moment you hovered it. Reserving the space costs 18pt and stops
            // the whole column twitching.
            ZStack(alignment: .trailing) {
                if session.isRunning {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.55)
                        .opacity(hovering && !renaming ? 0 : 1)
                } else if session.needsAttention && workspace.selection != session.id {
                    // Never on the selected row: it already carries an accent
                    // dot on the left as identity, and two dots on one row
                    // reads as a rendering fault rather than as unread.
                    AccountDot(session.account,
                               dimmed: hovering && !renaming ? 0 : 1,
                               size: Theme.dotAttention)
                }
                moreButton
                    .opacity(hovering && !renaming ? 1 : 0)
                    .allowsHitTesting(hovering && !renaming)
            }
            .frame(width: 18, height: 16)
            .animation(Motion.reveal, value: hovering)
            .animation(Motion.reveal, value: session.isRunning)
        }
        .padding(.vertical, Theme.s1)
        .contentShape(Rectangle())
        // No double-click-to-rename. Any tap recogniser on a `List` row has to
        // wait out the double-click interval before it can fail, and while it
        // waits the row's own selection is swallowed — intermittently, which is
        // the worst kind of broken. `simultaneousGesture` was tried and still
        // ate clicks. Selection is the thing this row exists to do, so renaming
        // gives way to it and lives in the ⋯ menu instead.
        .contextMenu { menuItems }
        // Session ▸ Rename… names a session rather than reaching a view, so the
        // row that owns the field picks the request up here.
        .onChange(of: workspace.renaming) { _, id in
            guard id == session.id else { return }
            beginRename()
            workspace.renaming = nil
        }
        .help(session.isEphemeral
              ? "\(session.subtitle)\nTemporary — not saved, and gone when you quit"
              : session.subtitle)
        .onHover { hovering = $0 }
    }

    /// Rename, reveal, delete — reachable from the row's own ⋯ button as well
    /// as from a right-click, because a context menu is not an affordance.
    @ViewBuilder
    private var menuItems: some View {
        // One window, so popping out a second conversation moves it rather than
        // opening another — which the label has to say, or the item reads as
        // doing nothing to the one already out there.
        Button(popOutTitle) { popOut() }
        Divider()
        Button("Rename") { beginRename() }
        // Phrased as what it does to the agent, not as a setting name. "Isolate
        // to this folder" says which folder without a second line explaining it.
        Toggle("Isolate to This Folder", isOn: Binding(
            get: { session.isolated }, set: { session.isolated = $0 }))
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([session.directory])
        }
        Divider()
        Button("Delete Session", role: .destructive) { workspace.requestDelete(session) }
    }

    /// Agent · folder · how long ago, in the space one line of 11pt affords.
    ///
    /// Truncates the folder rather than the agent, because the agent is one
    /// short word and the folder can be `some-very-long-repository-name` — and
    /// because which subscription is being spent is the fact you least want
    /// elided.
    private var meta: some View {
        HStack(spacing: Theme.s2) {
            Text(session.account.agentName)
                .fixedSize()
            Text("·")
                .foregroundStyle(.quaternary)
            Text(session.directory.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
            if let ago = SessionRow.ago(session) {
                Text("·")
                    .foregroundStyle(.quaternary)
                Text(ago)
                    .monospacedDigit()
                    .fixedSize()
            }
        }
        .font(Theme.caption)
        .foregroundStyle(.tertiary)
    }

    /// When something last happened here, in one or two characters.
    ///
    /// From the transcript's own stamps rather than a `lastActive` field,
    /// because there isn't one and adding it would mean keeping a fourth
    /// counter correct through edits, retries and a `/clear`. Nil for a session
    /// that has never said anything, where "0m" would be a claim about a
    /// conversation that hasn't started.
    static func ago(_ session: Session) -> String? {
        guard let last = session.stamps.values.max() else { return nil }
        let seconds = Int(Date().timeIntervalSince(last))
        switch seconds {
        case ..<60:      return "now"
        case ..<3600:    return "\(seconds / 60)m"
        case ..<86_400:  return "\(seconds / 3600)h"
        default:         return "\(seconds / 86_400)d"
        }
    }

    private var moreButton: some View {
        PopoverMenu(width: 210, choices: [
            PopoverChoice(title: popOutTitle) { popOut() },
            PopoverChoice(title: "Rename") { beginRename() },
            PopoverChoice(title: session.isolated
                          ? "Stop Isolating" : "Isolate to This Folder") {
                session.isolated.toggle()
            },
            PopoverChoice(title: "Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([session.directory])
            },
            PopoverChoice(title: "Delete Session", destructive: true) {
                workspace.requestDelete(session)
            },
        ]) {
            Image(systemName: "ellipsis")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .help("Session options")
    }

    private var popOutTitle: String {
        workspace.poppedOut == session.id ? "Bring Back from Pop-Out" : "Pop Out"
    }

    private func popOut() {
        if workspace.poppedOut == session.id {
            workspace.popIn()
        } else {
            workspace.popOut(session.id)
        }
    }

    private func beginRename() {
        draftName = session.name
        renaming = true
        DispatchQueue.main.async { nameFocused = true }
    }

    private func commit() {
        workspace.rename(session, to: draftName)
        renaming = false
    }
}

// The shared `chooseDirectory` file panel is gone. Every route to a new
// session goes through `NewSessionSheet`, which offers the folders you have
// actually worked in and keeps the file panel behind a Browse button — see
// `Workspace.requestNewSession`. The panel itself now lives in that sheet,
// which is the one place that still needs it.

// MARK: - The row's mark

/// A session's account, as a small rounded square with a letter in it.
///
/// Honeycode's rule has been "identity is the dot, and only ever the dot" —
/// every other spot of colour in the window carries a *state*, so the two can
/// never be confused. This keeps that rule and gives the shape more to do: the
/// fill and the letter are both the account's own colour, so nothing here says
/// anything a dot didn't, and a 20pt square at the head of a two-line row does
/// the work a 6pt dot cannot, which is anchoring the row visually.
///
/// The letter is the account's short title, which is what makes the four
/// distinguishable: Personal, Enterprise, Kimi, Copilot — P, E, K, C.
struct SessionAvatar: View {
    let account: Account
    /// A throwaway session. Outlined rather than filled, which is the same one
    /// bit of difference `AccountDot(hollow:)` uses for the same fact.
    var provisional = false

    private var letter: String {
        String(account.shortTitle.prefix(1)).uppercased()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.cornerChip - 1)
        Text(letter)
            .font(.system(size: Theme.t1, weight: .semibold))
            .foregroundStyle(account.accent)
            .frame(width: 20, height: 20)
            .background(provisional ? Color.clear : account.accent.opacity(0.16), in: shape)
            .overlay {
                if provisional {
                    shape.strokeBorder(account.accent.opacity(0.5),
                                       style: StrokeStyle(lineWidth: 1, dash: [2.5, 2]))
                }
            }
            .help(provisional ? "\(account.title) — temporary, gone when you quit"
                              : account.title)
    }
}
