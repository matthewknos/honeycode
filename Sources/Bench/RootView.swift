import SwiftUI
import AppKit

/// The window.
///
/// Hand-rolled rather than `NavigationSplitView`, for two reasons that both
/// came from the same place: the split view owns the titlebar (so its separator
/// rule can't reliably be removed) and its collapse is all-or-nothing (the
/// sidebar either occupies its full width or vanishes). Collapsing to a narrow
/// rail — which keeps the account switcher and the new-session button reachable
/// — isn't expressible through it.
///
/// What we give up is AppKit's automatic sidebar material and toggle button;
/// both are re-created here, and the material is the same `.sidebar` effect.
struct RootView: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var background: BackgroundStore
    @Binding var showPalette: Bool

    @AppStorage("sidebarExpanded") private var expanded = true
    @State private var railTarget: RailTarget?
    @State private var railHovering = false
    @State private var menuHovering = false

    private var sidebarWidth: CGFloat { expanded ? Theme.sidebarWidth : Theme.railWidth }

    /// Collapsed, there is no panel — just the floating pill.
    ///
    /// Hovering anywhere in the 52pt column used to light the whole strip up,
    /// which is a lot of movement for passing the pointer over it on the way
    /// somewhere else. The pill is its own affordance and doesn't need the
    /// column behind it to announce anything.
    private var sidebarIsPanel: Bool { expanded }

    var body: some View {
        ZStack {
            // The backdrop spans the whole window rather than just the pane.
            // That's what lets the collapsed rail read as part of the canvas —
            // the sidebar paints over this, or it doesn't.
            PaneBackground(store: background)

            HStack(spacing: 0) {
                sidebar
                    .background(sidebarBackground)
                    // Scoped here rather than on the root. On the ZStack these
                    // animated the *transcript* as well, so collapsing the
                    // sidebar made the whole reply slide about.
                    .animation(Motion.panel, value: expanded)
                    .animation(Motion.reveal, value: sidebarIsPanel)

                if sidebarIsPanel {
                    Divider().overlay(Theme.rule)
                        .transition(.opacity)
                }

                Group {
                    if let session = workspace.selected {
                        SessionView(session: session, workspace: workspace)
                            // Rebuild on selection change, or the transcript's
                            // scroll position and the composer's draft leak
                            // across sessions.
                            .id(session.id)
                    } else {
                        EmptyDetail()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .animation(Motion.reveal, value: sidebarIsPanel)
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 900, minHeight: 580)
        .background(WindowChrome())
        .overlay {
            if showPalette {
                CommandPalette(workspace: workspace, isPresented: $showPalette)
            }
        }
        .confirmationDialog(
            "Delete “\(workspace.pendingDeletion?.name ?? "")”?",
            isPresented: Binding(get: { workspace.pendingDeletion != nil },
                                 set: { if !$0 { workspace.pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { workspace.confirmDeletion() }
            Button("Cancel", role: .cancel) { workspace.pendingDeletion = nil }
        } message: {
            // Says exactly what goes and what doesn't. The agent keeps its own
            // copy of the conversation in its config directory, so this is the
            // end of Bench's record, not of the conversation itself.
            Text("This removes the session and its saved transcript from Honeycode. "
                 + "Your files are untouched, and the agent keeps its own copy "
                 + "of the conversation.")
        }
    }

    // MARK: Sidebar

    /// Three states, in order of precedence:
    ///
    /// - **Collapsed and not hovered** — nothing. The rail's controls float
    ///   directly on the canvas.
    /// - **A background image is set** — a flat fill. The `.sidebar` material
    ///   is translucent to the *desktop*, not to the window, so with a photo in
    ///   the pane it picks up whatever wallpaper is behind the app and the
    ///   sidebar ends up tinted by something you can't even see. A solid panel
    ///   is the only way to keep it neutral.
    /// - **Otherwise** — the real vibrant material, which is what a Mac sidebar
    ///   should be when there's nothing competing with it.
    @ViewBuilder
    private var sidebarBackground: some View {
        if !sidebarIsPanel {
            Color.clear
        } else if background.isGlassy {
            Theme.canvas
        } else {
            SidebarMaterial().ignoresSafeArea()
        }
    }

    /// Both layouts, at their natural widths, revealed by a clipping window.
    ///
    /// The width used to be applied to the content itself — so every frame of
    /// the animation asked a `List` (an `NSTableView` underneath) to lay itself
    /// out at a width between 240 and 52. AppKit-backed views don't interpolate
    /// a layout; they redo it. That reflow, sixty times in a third of a second,
    /// was the harshness — no easing curve can smooth a control that's
    /// rebuilding itself on every frame.
    ///
    /// Now neither layout ever changes size. They sit at 240 and 52, and the
    /// container around them animates, clipping. Nothing reflows; a window
    /// slides across finished content.
    private var sidebar: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                header
                SidebarList(workspace: workspace)
                footer
            }
            .padding(.top, Chrome.trafficLightClearance)
            .frame(width: Theme.sidebarWidth, alignment: .leading)
            .opacity(expanded ? 1 : 0)

            VStack(spacing: 0) {
                railGroup
                Spacer(minLength: 0)
                railSettings
            }
            // Same insets as the View menu across the window — top, bottom
            // and sides — so the two floating controls read as a pair rather
            // than as two things that happen to be near corners.
            .padding(.top, Chrome.trafficLightClearance - Theme.s5)
            .padding(.bottom, Chrome.trafficLightClearance - Theme.s5)
            // Centred, not leading. Widening the rail to make room for a 16pt
            // margin put all of it on the *right*, so the pill still sat 6pt
            // from the window edge while the View menu opposite sat 22pt from
            // its own. Centring in 60pt with a 28pt pill gives 16 either side.
            .frame(width: Theme.railWidth)
            .opacity(expanded ? 0 : 1)
        }
        .frame(width: sidebarWidth, alignment: .leading)
        .clipped()
    }

    /// Which rail item's menu is showing.
    ///
    /// Held here rather than by each control so only one can ever be open —
    /// sweeping down the rail switches the menu instantly instead of stacking
    /// popovers or fighting over which closes last.
    enum RailTarget: Hashable {
        case newSession
        case account(Account)
    }

    private func railBinding(_ item: RailTarget) -> Binding<Bool> {
        Binding(get: { railTarget == item },
                set: { railTarget = $0 ? item : nil })
    }

    /// Close once the pointer has left both the rail and the menu it opened.
    ///
    /// Opening on hover is only half a behaviour — without this the menu stayed
    /// up indefinitely over the transcript, because nothing was watching for
    /// you leaving. The grace period is what makes the gap between the rail and
    /// the popover crossable; without it the menu closes the instant you set
    /// off towards it.
    private func closeRailMenuIfAway() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            guard !railHovering, !menuHovering else { return }
            railTarget = nil
        }
    }

    /// Applied to every rail popover, so leaving one closes it.
    private func railMenuChrome<Content: View>(_ content: Content) -> some View {
        content
            .padding(.vertical, Theme.s3)
            .onHover { inside in
                menuHovering = inside
                if !inside { closeRailMenuIfAway() }
            }
    }

    private var railGroup: some View {
        VStack(spacing: Theme.s5) {
            Button { withAnimation(Motion.panel) { expanded = true } } label: {
                Image(systemName: "sidebar.leading")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // The toggle takes no menu, so passing over it closes whatever was.
            .onHover { if $0 { railTarget = nil } }
            .help("Expand sidebar")

            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
                .onHover { if $0 { railTarget = .newSession } }
                .onTapGesture { railTarget = .newSession }
                .help("New session")
                .popover(isPresented: railBinding(.newSession), arrowEdge: .trailing) {
                    railMenuChrome(
                        VStack(alignment: .leading, spacing: 0) {
                            railHeader("New session")
                            ForEach(Account.allCases) { account in
                                PopoverRow(title: account.title,
                                           blurb: account == .copilot
                                               ? "GitHub Copilot" : "Claude Code") {
                                    railTarget = nil
                                    add(to: account)
                                }
                            }
                        }
                    )
                    .frame(width: 240)
                }

            ForEach(Account.allCases) { account in
                railDot(account)
            }
        }
        .padding(.vertical, Theme.s4)
        .modifier(RailSurface(glass: background.isGlassy))
        .onHover { inside in
            railHovering = inside
            if !inside { closeRailMenuIfAway() }
        }
    }

    /// One account. Opens the moment the pointer arrives.
    private func railDot(_ account: Account) -> some View {
        let sessions = workspace.sessions(in: account)

        return Circle()
            .fill(account.accent)
            .frame(width: 7, height: 7)
            .opacity(sessions.isEmpty ? 0.3 : 1)
            .frame(width: 28, height: 22)
            .contentShape(Rectangle())
            .onHover { if $0 { railTarget = .account(account) } }
            // Click works too. A hover-only control is invisible to anyone who
            // doesn't happen to linger.
            .onTapGesture { railTarget = .account(account) }
            .help(account.title)
            .popover(isPresented: railBinding(.account(account)), arrowEdge: .trailing) {
                railMenuChrome(
                    VStack(alignment: .leading, spacing: 0) {
                    railHeader(account.title)

                    if sessions.isEmpty {
                        Text("No sessions")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, Theme.s5)
                            .padding(.vertical, Theme.s3)
                    }

                    ForEach(sessions) { session in
                        PopoverRow(title: session.name,
                                   blurb: session.subtitle,
                                   selected: workspace.selection == session.id) {
                            workspace.selection = session.id
                            railTarget = nil
                        }
                    }

                    Divider().overlay(Theme.rule).padding(.vertical, Theme.s2)
                    PopoverRow(title: "New \(account.title) session…") {
                        railTarget = nil
                        guard let url = chooseDirectory(for: account) else { return }
                        workspace.add(account: account, directory: url)
                    }
                    }
                )
                .frame(width: 250)
            }
    }

    private func railHeader(_ text: String) -> some View {
        Text(text)
            .font(Theme.label)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, Theme.s5)
            .padding(.top, Theme.s2)
            .padding(.bottom, Theme.s3)
    }

    private var railSettings: some View {
        SettingsLink {
            Image(systemName: "gearshape")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, Theme.s2)
        .modifier(RailSurface(glass: background.isGlassy))
        .help("Settings (⌘,)")
    }

    /// Settings, pinned to the bottom edge.
    ///
    /// `SettingsLink` rather than poking `showSettingsWindow:` through
    /// `NSApp.sendAction` — that selector is private, has been renamed at least
    /// once between releases, and fails silently when it changes again.
    private var footer: some View {
        VStack(spacing: 0) {
            Divider().overlay(Theme.rule)

            SettingsLink {
                HStack(spacing: Theme.s3) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        // Same 12pt leading column the session rows use, so the
                        // footer aligns with the list above rather than sitting
                        // a few points off it.
                        .frame(width: 12, alignment: .center)

                    if expanded {
                        Text("Settings")
                            .font(Theme.sidebarRow)
                        Spacer(minLength: 0)
                        Text("⌘,")
                            .font(.system(size: 11))
                            .foregroundStyle(.quaternary)
                    }
                }
                .padding(.horizontal, expanded ? Theme.s4 : 0)
                .padding(.vertical, Theme.s3)
                .frame(maxWidth: .infinity, alignment: expanded ? .leading : .center)
                .contentShape(Rectangle())
            }
            .buttonStyle(SidebarFooterButton())
            .padding(.horizontal, expanded ? Theme.s4 : Theme.s3)
            .padding(.vertical, Theme.s3)
        }
    }

    /// Toggle and new-session, in both states.
    private var header: some View {
        HStack(spacing: Theme.s3) {
            if expanded {
                Button { withAnimation(Motion.panel) { expanded = false } } label: {
                    Image(systemName: "sidebar.leading")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Collapse sidebar")

                Spacer(minLength: 0)

                newSessionMenu
            } else {
                Button { withAnimation(Motion.panel) { expanded = true } } label: {
                    Image(systemName: "sidebar.leading")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Expand sidebar")
            }
        }
        .padding(.horizontal, expanded ? Theme.s5 : Theme.s5 - Theme.s2)
        .padding(.bottom, Theme.s3)
    }

    private var newSessionMenu: some View {
        PopoverMenu(header: "New session",
                    choices: Account.allCases.map { account in
                        PopoverChoice(title: account.title,
                                      blurb: account == .copilot
                                          ? "GitHub Copilot" : "Claude Code") {
                            add(to: account)
                        }
                    }) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .help("New session (⌘N)")
    }

    /// Collapsed state. Not a stripe of nothing: the accounts stay reachable,
    /// each dot jumping to that account and re-expanding. A rail that only
    /// showed a toggle would be a worse version of hiding the sidebar outright.
    private var rail: some View {
        VStack(spacing: Theme.s5) {
            Button { add(to: workspace.selected?.account ?? .personal) } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New session (⌘N)")

            ForEach(Account.allCases) { account in
                let sessions = workspace.sessions(in: account)
                Button {
                    workspace.focus(account)
                    withAnimation(Motion.panel) { expanded = true }
                } label: {
                    Circle()
                        .fill(account.accent)
                        .frame(width: 7, height: 7)
                        .opacity(sessions.isEmpty ? 0.3 : 1)
                        .frame(width: 28, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(account.title)
            }

        }
        .frame(maxWidth: .infinity)
    }

    private func add(to account: Account) {
        guard let url = chooseDirectory(for: account) else { return }
        workspace.add(account: account, directory: url)
    }
}

private struct EmptyDetail: View {
    var body: some View {
        VStack(spacing: Theme.s2) {
            Text("No session")
                .font(.system(size: 15, weight: .medium))
            Text("⌘N to add one.")
                .font(Theme.body)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Sidebar list

struct SidebarList: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        List(selection: $workspace.selection) {
            ForEach(Account.allCases) { account in
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
                guard let url = chooseDirectory(for: account) else { return }
                workspace.add(account: account, directory: url)
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
        .help(session.isEphemeral
              ? "\(session.subtitle)\nTemporary — not saved, and gone when you quit"
              : session.subtitle)
        .onHover { hovering = $0 }
    }

    /// Rename, reveal, delete — reachable from the row's own ⋯ button as well
    /// as from a right-click, because a context menu is not an affordance.
    @ViewBuilder
    private var menuItems: some View {
        Button("Rename") { beginRename() }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([session.directory])
        }
        Divider()
        Button("Delete Session", role: .destructive) { workspace.requestDelete(session) }
    }

    private var moreButton: some View {
        PopoverMenu(width: 210, choices: [
            PopoverChoice(title: "Rename") { beginRename() },
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

/// Shared by the rail, the section headers, and ⌘N.
func chooseDirectory(for account: Account) -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Add Session"
    panel.message = "Choose a working directory for this \(account.title) session."
    return panel.runModal() == .OK ? panel.url : nil
}

// MARK: - Session detail

struct SessionView: View {
    @ObservedObject var session: Session
    @ObservedObject var workspace: Workspace
    @EnvironmentObject private var background: BackgroundStore
    @ObservedObject private var usage = UsageStore.shared
    @State private var draft = ""
    @AppStorage("transcript.mode") private var mode = TranscriptMode.normal
    @AppStorage("transcript.textScale") private var textScale: Double = 1
    @AppStorage("transcript.width") private var readingWidth: Double = Double(Theme.readingWidth)
    @State private var showingChanges = false
    @State private var showingViewMenu = false

    private var changes: [FileChange] { Changes.summarise(session.items) }

    private func composer(prominent: Bool = false) -> some View {
        // Nothing to match any more: the transcript's scroller is off, so
        // neither side reserves width for one and both centre in the full pane.
        ComposerView(draft: $draft, session: session, prominent: prominent,
                     width: CGFloat(readingWidth)) { text in
            session.send(text)
            draft = ""
        }
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                if !(session.browserVisible && session.browserFull) {
                    conversation
                }
                if session.browserVisible {
                    if !session.browserFull {
                        resizer(in: geometry.size.width)
                    }
                    BrowserPanel(session: session, workspace: workspace)
                        .frame(width: session.browserFull
                               ? nil : clamped(panelWidth, in: geometry.size.width))
                        .frame(maxWidth: session.browserFull ? .infinity : nil)
                        // Width follows the pointer exactly while dragging;
                        // an inherited animation would make it lag behind by
                        // whatever the curve's duration is.
                        .transaction { if liveWidth != nil { $0.animation = nil } }
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .animation(Motion.panel, value: session.browserVisible)
        .animation(Motion.panel, value: session.browserFull)
    }

    /// Dragged from the divider, remembered across sessions.
    ///
    /// Split in two on purpose. `@AppStorage` writes to `UserDefaults` on every
    /// assignment, and a drag assigns sixty times a second — so resizing was
    /// hammering the defaults system and stuttering visibly. The live value is
    /// plain view state; only the final width is written.
    @AppStorage("browser.width") private var storedWidth: Double = 520
    @State private var liveWidth: Double?
    @State private var dragStart: Double?

    private var panelWidth: Double { liveWidth ?? storedWidth }

    /// The conversation keeps a floor. Letting the panel eat the whole pane by
    /// dragging would be a worse way to reach full width than the button that
    /// does it deliberately.
    private func clamped(_ width: Double, in total: CGFloat) -> CGFloat {
        min(max(CGFloat(width), 340), max(340, total - 420))
    }

    /// The divider, with a grab area wider than the line it draws.
    ///
    /// A 1pt hit target is a hairline you hunt for; 10pt is invisible and
    /// findable, which is what every split view on the platform does.
    private func resizer(in total: CGFloat) -> some View {
        Rectangle()
            .fill(Theme.rule)
            .frame(width: 1)
            .overlay {
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 11)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    // Global coordinate space, not local.
                    //
                    // A drag reports translation relative to its own view — and
                    // this view *is* the thing being moved, so every frame
                    // shifted the origin the next frame measured from. The
                    // pointer and the divider chased each other, which is the
                    // jitter. In global space the origin holds still.
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = dragStart ?? storedWidth
                                if dragStart == nil { dragStart = start }
                                liveWidth = Double(clamped(start - value.translation.width,
                                                           in: total))
                            }
                            .onEnded { _ in
                                storedWidth = panelWidth
                                liveWidth = nil
                                dragStart = nil
                            }
                    )
            }
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            if session.items.isEmpty {
                GeometryReader { geometry in
                    VStack(spacing: 0) {
                        Spacer().frame(height: max(0, geometry.size.height * 0.26))
                        StartOfSession(session: session)
                        composer(prominent: true)
                        Spacer(minLength: 0)
                    }
                }
            } else {
                TranscriptView(session: session, onEdit: { text in
                                   // Attachments are re-attached separately, so
                                   // only the prose comes back — otherwise the
                                   // `@path` lines would be duplicated on send.
                                   draft = Attached.split(text).prose
                               },
                               workspace: workspace, mode: mode,
                               scale: CGFloat(textScale), width: CGFloat(readingWidth))
                    .environment(\.openArtifact) { artifact in
                        withAnimation(Motion.panel) {
                            session.browserHTML = artifact
                            session.browserVisible = true
                        }
                    }
                composer()
            }
        }
        // Constraining the transcript and composer *together* aligned them and
        // dragged the scroll view in with them. The scroll view spans the pane;
        // both sides centre a column of the same width inside it.
        .animation(Motion.panel, value: session.items.isEmpty)
        .overlay(alignment: .topTrailing) { statusRail }
        .onAppear { session.prepare() }
        .sheet(isPresented: $showingChanges) {
            ChangesView(changes: changes, isPresented: $showingChanges)
        }
    }

    /// One control, not five chips.
    ///
    /// This corner had grown a row of unrelated readouts — mode, limits,
    /// context, spend, changes, server — all competing with the transcript for
    /// the same few hundred points. The numbers belong beside the thing that
    /// spends them, so they moved to the composer; what's left is a menu of
    /// *views*, which is the only thing this corner was ever really for.
    private var statusRail: some View {
        viewMenu
            .padding(.horizontal, background.isGlassy ? Theme.s4 : 0)
            .padding(.vertical, background.isGlassy ? Theme.s3 : 0)
            .modifier(StatusSurface(glass: background.isGlassy))
            .padding(.top, Chrome.trafficLightClearance - Theme.s5)
            .padding(.trailing, Theme.s6)
    }

    /// Same popover as the model picker — sections, two-line rows, trailing
    /// checks — because it's the same kind of control doing the same job.
    private var viewMenu: some View {
        Button { showingViewMenu.toggle() } label: {
            HStack(spacing: Theme.s2 - 1) {
                Image(systemName: "sidebar.squares.right")
                    .font(.system(size: 10, weight: .medium))
                Text(mode.title)
                    .font(.system(size: 11.5, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, Theme.s4)
            .padding(.vertical, Theme.s2)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverCapsule())
        .help("View")
        .popover(isPresented: $showingViewMenu, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader("Panels")
                PopoverRow(title: "Browser",
                           blurb: session.devServer.map { server in
                               "Dev server on " + (server.host ?? "")
                                   + (server.port.map { ":\($0)" } ?? "")
                           } ?? "Preview a URL or a dev server",
                           selected: session.browserVisible) {
                    showingViewMenu = false
                    withAnimation(Motion.panel) {
                        session.browserVisible.toggle()
                        // Opening lands on the session's own server if it has
                        // one — that's the whole reason you opened it. Unless
                        // an artifact is loaded, in which case the panel comes
                        // back the way you left it.
                        if session.browserVisible, session.browserHTML == nil {
                            session.browserURL = session.preferredBrowserURL
                        }
                    }
                }
                PopoverRow(title: "Changes",
                           blurb: changes.isEmpty
                               ? "Nothing edited yet"
                               : "\(changes.count) file\(changes.count == 1 ? "" : "s") edited") {
                    showingViewMenu = false
                    showingChanges = true
                }
                .disabled(changes.isEmpty)
                .opacity(changes.isEmpty ? 0.5 : 1)

                Divider().overlay(Theme.rule).padding(.vertical, Theme.s2)
                sectionHeader("Transcript detail")
                ForEach(TranscriptMode.allCases) { option in
                    PopoverRow(title: option.title, blurb: option.blurb,
                               selected: mode == option) {
                        mode = option
                        showingViewMenu = false
                    }
                }
            }
            .padding(.vertical, Theme.s3)
            .frame(width: 272)
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(Theme.label)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, Theme.s5)
            .padding(.top, Theme.s2)
            .padding(.bottom, Theme.s3)
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

/// The head of an empty session.
private struct StartOfSession: View {
    @ObservedObject var session: Session

    var body: some View {
        Text(Self.greeting)
            .font(Theme.display(28))
            .padding(.bottom, Theme.s7)
    }

    /// Time-of-day greeting using the account holder's first name.
    static var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let part = switch hour {
        case 0..<5:   "Still up"
        case 5..<12:  "Good morning"
        case 12..<18: "Good afternoon"
        default:      "Good evening"
        }
        let first = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? part : "\(part), \(first)"
    }
}
