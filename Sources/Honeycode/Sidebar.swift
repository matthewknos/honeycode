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

    var body: some View {
        List(selection: $workspace.selection) {
            ForEach(workspace.listedAccounts) { account in
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
                    ForEach(workspace.sessions(in: account)) { session in
                        SessionRow(session: session, workspace: workspace)
                            .tag(session.id)
                    }
                } header: {
                    AccountHeader(account: account, workspace: workspace)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 26)
    }
}

private struct AccountHeader: View {
    let account: Account
    @ObservedObject var workspace: Workspace
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

            if hiddenAttention {
                Circle().fill(account.accent).frame(width: 4, height: 4)
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
        HStack(spacing: Theme.s3) {
            // Hollow for a throwaway — same dot, one bit of difference, no
            // extra glyph or badge to explain.
            Group {
                if session.isEphemeral {
                    Circle().strokeBorder(session.account.accent, lineWidth: 1.5)
                } else {
                    Circle().fill(session.account.accent)
                }
            }
            .frame(width: 6, height: 6)
            .frame(width: 12, alignment: .center)

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

            // Beside the name rather than in the slot on the right, which is
            // already spoken for and cross-fades on hover. Isolation is a
            // property of the conversation, like its name — not a transient
            // state like running or unread — so it shouldn't come and go as
            // the pointer moves.
            if session.isolated {
                Image(systemName: "lock")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .help("Isolated to \(session.subtitle)")
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
                    Circle()
                        .fill(session.account.accent)
                        .frame(width: 5, height: 5)
                        .opacity(hovering && !renaming ? 0 : 1)
                }
                moreButton
                    .opacity(hovering && !renaming ? 1 : 0)
                    .allowsHitTesting(hovering && !renaming)
            }
            .frame(width: 18, height: 16)
            .animation(Motion.reveal, value: hovering)
            .animation(Motion.reveal, value: session.isRunning)
        }
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
        Button("Open Beside") { workspace.openBeside(session.id) }
            .disabled(workspace.columns.count >= Workspace.maxColumns
                      || workspace.isOnScreen(session.id))
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

    private var moreButton: some View {
        PopoverMenu(width: 210, choices: [
            PopoverChoice(title: "Open Beside") { workspace.openBeside(session.id) },
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
