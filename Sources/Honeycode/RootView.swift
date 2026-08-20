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
    @ObservedObject var agents: AgentStore
    @Binding var showPalette: Bool
    @Binding var paletteOpensBeside: Bool

    /// Which half of the app the sidebar is showing.
    ///
    /// The pill switches the *sidebar*, not the app: the window, the pane and
    /// the chrome are one thing throughout, and Code keeps its column
    /// arrangement while you're off looking at an agent. Persisted, because
    /// which half you were last in is the same kind of fact as which session.
    enum SidebarMode: String {
        case code, agents
    }

    @AppStorage("sidebar.mode") private var mode = SidebarMode.code
    /// Read here only to cancel `forcesLightContent` — coding mode leaves the
    /// artwork out of the hierarchy, so the light it was compensating for
    /// isn't there any more.
    @AppStorage("transcript.terminal") private var codingMode = false

    /// The appearance the window is actually in, so the flux override below has
    /// something to hand back when it isn't overriding.
    @Environment(\.colorScheme) private var systemScheme

    @AppStorage("sidebarExpanded") private var expanded = true
    @State private var railTarget: RailTarget?
    @State private var railHovering = false
    @State private var menuHovering = false
    /// Held so the dialog keeps its title through the dismiss animation, which
    /// outlives `pendingDeletion` and was leaving `Delete “”?` on screen.
    @State private var deletionName = ""

    private var sidebarWidth: CGFloat { expanded ? Theme.sidebarWidth : Theme.railWidth }

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

                if expanded {
                    Divider().overlay(Theme.rule)
                        .transition(.opacity)
                }

                Group {
                    switch mode {
                    case .code:   SessionColumns(workspace: workspace)
                    case .agents: AgentsPane(store: agents, workspace: workspace)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // The one place the app overrides appearance for a region
                    // rather than for the window — see `forcesLightContent`.
                    //
                    // Written as a ternary rather than an `if`, so switching
                    // backgrounds doesn't change the structural identity of the
                    // columns and throw away every transcript's scroll position
                    // along with it. Assigning the inherited scheme is a no-op.
                    .environment(\.colorScheme,
                                 background.forcesLightContent && !codingMode
                                     ? .light : systemScheme)
            }
        }
        .animation(Motion.reveal, value: expanded)
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 900, minHeight: 580)
        .background(WindowChrome())
        .overlay {
            if showPalette {
                CommandPalette(workspace: workspace, isPresented: $showPalette,
                               beside: paletteOpensBeside)
            }
        }
        // The floating window is reconciled from `poppedOut` rather than opened
        // and closed at the call sites, so every route in — the row menu, the
        // menu bar, a restored arrangement at launch — goes through one path.
        .onAppear { PopOut.shared.sync(workspace: workspace, background: background) }
        .onChange(of: workspace.poppedOut) { _, _ in
            PopOut.shared.sync(workspace: workspace, background: background)
        }
        .onChange(of: workspace.pendingDeletion?.id) { _, id in
            if let session = workspace.pendingDeletion, id != nil { deletionName = session.name }
        }
        .confirmationDialog(
            "Delete “\(deletionName)”?",
            isPresented: Binding(get: { workspace.pendingDeletion != nil },
                                 set: { if !$0 { workspace.pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { workspace.confirmDeletion() }
            Button("Cancel", role: .cancel) { workspace.pendingDeletion = nil }
        } message: {
            // Says exactly what goes and what doesn't. The agent keeps its own
            // copy of the conversation in its config directory, so this is the
            // end of Honeycode's record, not of the conversation itself.
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
        // Collapsed, there is no panel — just the floating pill.
        if !expanded {
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
                pill
                // Switched, not animated between. A crossfade here would run a
                // `List` rebuild against the sidebar's own width animation, and
                // the whole reason both layouts sit at fixed widths (see above)
                // is that AppKit-backed views redo their layout rather than
                // interpolate it.
                switch mode {
                case .code:   SidebarList(workspace: workspace)
                case .agents: AgentList(store: agents)
                }
                footer
            }
            .padding(.top, Chrome.trafficLightClearance)
            .frame(width: Theme.sidebarWidth, alignment: .leading)
            .opacity(expanded ? 1 : 0)
            // Faded out is not gone: an opacity-0 view still hit-tests, and
            // `.clipped()` clips drawing rather than touches. Collapsed, this
            // 240pt list was still taking clicks and scrolls out in the pane.
            .allowsHitTesting(expanded)

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
            // And the other way: expanded, the rail's hover targets sat
            // invisibly under the sidebar header, opening account popovers
            // for a pointer that was aiming at the collapse button.
            .allowsHitTesting(!expanded)
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

            // The pill, as two icons. Both always drawn, the inactive one
            // dimmed — a single glyph that changed its own meaning would be a
            // control you have to press to find out what it does.
            railMode(.code, "chevron.left.forwardslash.chevron.right")
            railMode(.agents, "sparkles")

            if mode == .agents {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 24)
                    .contentShape(Rectangle())
                    .onHover { if $0 { railTarget = nil } }
                    .onTapGesture {
                        agents.beginSetup(account: currentAccount, near: workspace)
                    }
                    .help("New agent")

                ForEach(agents.agents) { agent in
                    railAgentDot(agent)
                }
            } else {
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
                                PopoverHeader("New session")
                                ForEach(Account.allCases) { account in
                                    PopoverRow(title: account.title,
                                               blurb: account.agentName) {
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
        }
        .padding(.vertical, Theme.s4)
        .modifier(RailSurface(glass: background.isGlassy))
        .onHover { inside in
            railHovering = inside
            if !inside { closeRailMenuIfAway() }
        }
    }

    private func railMode(_ value: SidebarMode, _ symbol: String) -> some View {
        let on = mode == value
        return Image(systemName: symbol)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(on ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .frame(width: 28, height: 22)
            .background(on ? Theme.well : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onHover { if $0 { railTarget = nil } }
            .onTapGesture { withAnimation(Motion.hover) { mode = value } }
            .help(value == .code ? "Sessions" : "Agents")
    }

    /// One agent, filled while a run is in flight — so the rail reports that
    /// something is happening without having to be expanded.
    private func railAgentDot(_ agent: AgentDefinition) -> some View {
        let running = agents.running[agent.id] != nil
        return Circle()
            .fill(agent.account.accent)
            .frame(width: running ? 8 : 7, height: running ? 8 : 7)
            .opacity(agent.isEnabled ? (running ? 1 : 0.55) : 0.25)
            .frame(width: 28, height: 22)
            .contentShape(Rectangle())
            .onHover { if $0 { railTarget = nil } }
            .onTapGesture {
                agents.selection = agent.id
                agents.openRun = nil
            }
            .help("\(agent.name)\n\(agent.schedule.title)")
            .animation(Motion.reveal, value: running)
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
                    PopoverHeader(account.title)

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

                newButton
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

    /// Code / Agents.
    ///
    /// A segmented control rather than two tabs or a popup: there are exactly
    /// two halves, both worth naming, and the one you aren't in should stay
    /// visible — a control that hides the alternative is how a second mode goes
    /// undiscovered.
    private var pill: some View {
        HStack(spacing: 2) {
            segment(.code, "Code", "chevron.left.forwardslash.chevron.right")
            segment(.agents, "Agents", "sparkles")
        }
        .padding(2)
        .background(Theme.well, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, Theme.s5)
        .padding(.bottom, Theme.s5)
    }

    private func segment(_ value: SidebarMode, _ title: String,
                         _ symbol: String) -> some View {
        let on = mode == value
        return Button { withAnimation(Motion.hover) { mode = value } } label: {
            HStack(spacing: Theme.s2) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .medium))
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(on ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .frame(maxWidth: .infinity)
            .frame(height: 22)
            .background(on ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: 6))
            .shadow(color: .black.opacity(on ? 0.12 : 0), radius: 1, y: 0.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(value == .code ? "Conversations you started"
                             : "Agents that run on their own")
    }

    /// The `+` means different things on the two sides, so it does.
    @ViewBuilder
    private var newButton: some View {
        switch mode {
        case .code:
            newSessionMenu
        case .agents:
            Button { agents.beginSetup(account: currentAccount, near: workspace) } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New agent — describe it in a sentence")
        }
    }

    /// Which account an interview runs under. Not the agent's own — changing
    /// your mind about who should run the finished agent shouldn't restart the
    /// conversation you're having about it.
    private var currentAccount: Account { workspace.selected?.account ?? .personal }

    private var newSessionMenu: some View {
        PopoverMenu(header: "New session",
                    choices: Account.allCases.map { account in
                        PopoverChoice(title: account.title,
                                      blurb: account.agentName) {
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

    private func add(to account: Account) {
        guard let url = chooseDirectory(for: account) else { return }
        workspace.add(account: account, directory: url)
    }
}

// MARK: - Columns

/// Several conversations at once, side by side.
///
/// Columns rather than a grid, and the reason is the shape of the content: a
/// transcript is a tall document, so splitting horizontally gives you two
/// half-height conversations and doubles the scrolling. Vertical columns keep
/// each one a full page.
///
/// The count is decided by the window, not by you. You say which sessions you
/// want open; how many of them fit is arithmetic, because a column narrower
/// than `minColumnWidth` can't hold a composer with a model picker and a mic on
/// one line, and a layout that lets you make one is a layout that lets you
/// break it. Columns that don't fit stay in the list and come back when the
/// window widens — nothing is closed on your behalf by a window resize.
private struct SessionColumns: View {
    @ObservedObject var workspace: Workspace

    /// Fractions of the pane, one per visible column, summing to 1.
    ///
    /// Live during a drag and committed on release, like the browser divider:
    /// `@AppStorage` writes to `UserDefaults` on every assignment, and a drag
    /// assigns sixty times a second.
    @AppStorage("columns.weights") private var storedWeights = ""
    @State private var live: [CGFloat]?
    @State private var dragBase: [CGFloat] = []

    /// Air between columns, instead of a rule.
    ///
    /// A hairline says "one surface, divided". Each column here is a whole
    /// conversation with its own reading panel, and they read as separate
    /// things — so the separation is a gap and the panels' own edges do the
    /// work the rule was doing.
    private static let gap = Theme.s7

    /// A margin on the trailing edge, matching the collapsed sidebar.
    ///
    /// The window had a 60pt gutter down the left — the rail — and none at all
    /// on the right, so the last column ran to the window edge while the first
    /// one sat inside a margin. Mirroring the rail's width is what makes the
    /// pane look centred in the window rather than pushed against one side.
    ///
    /// Only when the pane is shared. Alone there is nothing to put in the
    /// gutter — the View pill sits in the pane's own corner, as it always has —
    /// and reserving 60pt for it just moved that pill inboard of where every
    /// other version of this window has drawn it.
    private static let gutter = Theme.railWidth
    private static func trailing(for count: Int) -> CGFloat { count > 1 ? gutter : 0 }

    var body: some View {
        GeometryReader { geometry in
            let sessions = onScreen(in: geometry.size.width)
            if sessions.isEmpty {
                EmptyDetail().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let widths = layout(sessions.count, in: geometry.size.width)
                HStack(spacing: 0) {
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                        column(session, focused: session.id == workspace.selection)
                            .frame(width: widths[index])
                        if index < sessions.count - 1 {
                            divider(at: index, usable: widths.reduce(0, +),
                                    count: sessions.count)
                        }
                    }
                }
                .padding(.trailing, Self.trailing(for: sessions.count))
                .animation(Motion.panel, value: sessions.count)
                // The focused column's controls, in the gutter that mirrors
                // the collapsed sidebar — so the window has a rail on each
                // side rather than a rail and a floating stack of pills.
                .overlay(alignment: .topTrailing) {
                    if sessions.count > 1, let focused = workspace.selected {
                        StatusRail(session: focused, compact: true)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func column(_ session: Session, focused: Bool) -> some View {
        Group {
            // Out in the floating window. The slot is kept and a placeholder
            // drawn in it, so popping out doesn't reshuffle the arrangement and
            // popping back in doesn't reshuffle it again.
            if workspace.poppedOut == session.id {
                PoppedOutColumn(session: session, workspace: workspace)
            } else {
                SessionView(session: session, workspace: workspace,
                            isFocused: focused, columned: workspace.columns.count > 1)
            }
        }
            // Rebuild on identity change, or the transcript's scroll position
            // and the composer's draft leak across sessions.
            .id(session.id)
            // Close, top-left, only while the pane is shared.
            //
            // A rail down the leading edge was tried for identity and pulled:
            // two saturated vertical lines in a window whose whole layout is
            // horizontal read as structure that wasn't there. The composer's
            // ring already says which column has the keyboard, and its
            // placeholder and name say which conversation it is.
            .overlay(alignment: .topLeading) {
                if workspace.columns.count > 1 {
                    closeButton(session)
                }
            }
    }

    private func closeButton(_ session: Session) -> some View {
        Button { withAnimation(Motion.panel) { workspace.closeColumn(session.id) } } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverCapsule())
        .help("Close this column (⌘⌥W)")
        .padding(.top, Chrome.trafficLightClearance - Theme.s5)
        .padding(.leading, Theme.s5)
    }

    /// The gap, which is also the grab handle. Nothing is drawn in it — the
    /// cursor is the only affordance, and it's the one a divider has anyway.
    private func divider(at index: Int, usable: CGFloat, count: Int) -> some View {
        Color.clear
            .frame(width: Self.gap)
            .overlay {
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: Self.gap)
                    .contentShape(Rectangle())
                    .hoverCursor(.resizeLeftRight)
                    // Global coordinate space, for the same reason the browser
                    // panel's resizer needs it: this view is the thing being
                    // moved, so a local translation measures from an origin
                    // that the previous frame just shifted, and the pointer and
                    // the divider chase each other.
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                if live == nil { dragBase = weights(count) }
                                live = shifted(dragBase, at: index,
                                               by: value.translation.width / max(usable, 1),
                                               total: usable)
                            }
                            .onEnded { _ in
                                if let live { store(live) }
                                live = nil
                            }
                    )
            }
    }

    // MARK: Which columns, and how wide

    /// The columns that fit, always including the focused one.
    ///
    /// A window of the pinned list rather than its first N: shrinking the
    /// window while working in the rightmost column shouldn't scroll the one
    /// you're typing in off the screen.
    private func onScreen(in width: CGFloat) -> [Session] {
        let all = workspace.columnSessions
        guard !all.isEmpty else { return [] }
        // Measured against what's left after the trailing margin, and counting
        // the gap each extra column brings with it — otherwise the pane
        // promises room for a column and then lays it out below the minimum.
        let available = max(width - Self.gutter + Self.gap, 1)
        let capacity = max(1, min(Workspace.maxColumns,
                                  Int(available / (Workspace.minColumnWidth + Self.gap))))
        guard all.count > capacity else { return all }
        let focused = all.firstIndex { $0.id == workspace.selection } ?? 0
        let start = min(max(0, focused - capacity + 1), all.count - capacity)
        return Array(all[start..<(start + capacity)])
    }

    private func weights(_ count: Int) -> [CGFloat] {
        if let live, live.count == count { return live }
        let stored = storedWeights.split(separator: ",").compactMap { CGFloat(Double($0) ?? 0) }
        // Stored weights belong to the count they were saved at. Two columns
        // dragged to 70/30 and then joined by a third has no defensible
        // answer, so it starts even again rather than guessing one.
        guard stored.count == count, abs(stored.reduce(0, +) - 1) < 0.01 else {
            return Array(repeating: 1 / CGFloat(count), count: count)
        }
        return stored
    }

    private func layout(_ count: Int, in width: CGFloat) -> [CGFloat] {
        let gaps = Self.gap * CGFloat(max(0, count - 1))
        let usable = max(width - gaps - Self.trailing(for: count), 1)
        return weights(count).map { $0 * usable }
    }

    /// Move one divider, taking from one neighbour and giving to the other.
    ///
    /// Only the pair either side of the divider changes; the rest of the row
    /// holds still, which is what makes dragging one edge feel like moving an
    /// edge rather than re-flowing the window.
    private func shifted(_ base: [CGFloat], at index: Int,
                         by fraction: CGFloat, total: CGFloat) -> [CGFloat] {
        guard base.indices.contains(index), base.indices.contains(index + 1) else { return base }
        let floor = Workspace.minColumnWidth / max(total, 1)
        let room = base[index] + base[index + 1]
        var next = base
        next[index] = min(max(base[index] + fraction, floor), room - floor)
        next[index + 1] = room - next[index]
        return next
    }

    private func store(_ weights: [CGFloat]) {
        storedWeights = weights.map { String(format: "%.4f", Double($0)) }.joined(separator: ",")
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


// MARK: - Session detail

struct SessionView: View {
    @ObservedObject var session: Session
    @ObservedObject var workspace: Workspace
    /// Whether this column has the keyboard. Alone, always.
    var isFocused = true
    /// Whether it's sharing the pane. Drives the things that only earn their
    /// place when there's something to tell this column apart *from*.
    var columned = false
    @State private var draft = ""
    @AppStorage("transcript.mode") private var mode = TranscriptMode.normal
    @AppStorage("transcript.terminal") private var terminal = false
    @AppStorage("transcript.textScale") private var textScale: Double = 1
    @AppStorage("transcript.width") private var readingWidth: Double = Double(Theme.readingWidth)
    /// The live crew run, above the composer.
    ///
    /// Above rather than in the transcript, and only while there is one — see
    /// `CrewRunPanel`. It shares the composer's measure so the two read as one
    /// block at the foot of the pane rather than as a widget floating over it.
    @ViewBuilder
    private func runPanel() -> some View {
        if let run = session.crewRun {
            CrewRunPanel(run: run, session: session)
                .frame(maxWidth: terminal ? .infinity : CGFloat(readingWidth))
                .frame(maxWidth: .infinity)
                .padding(.horizontal, terminal ? 0 : Theme.pane)
                .padding(.top, Theme.s5)
                .transition(.opacity)
        }
    }

    private func composer(prominent: Bool = false) -> some View {
        // Nothing to match any more: the transcript's scroller is off, so
        // neither side reserves width for one and both centre in the full pane.
        ComposerView(draft: $draft, session: session, prominent: prominent,
                     width: CGFloat(readingWidth),
                     accent: columned ? session.account.accent : nil,
                     subtitle: columned ? session.name : nil,
                     terminal: terminal && !prominent,
                     onFocused: { workspace.selection = session.id }) { text in
            // `/send` and the shared skills are Honeycode's, and are taken
            // before dispatch — the agent never sees either as a command.
            // `/send` doesn't reach it at all, which is deliberate rather than
            // incidental: a relay crosses an account boundary, and a command
            // the agent reads is a command a prompt injection can write. A
            // skill expands into prose naming the skill and its file, because
            // the agent has no definition for `/branding` and would otherwise
            // be guessing at what it meant.
            if !relay(text) { session.send(Skills.expand(text) ?? text) }
            draft = ""
        }
        .popover(item: $relayRequest, arrowEdge: .top) { request in
            RelayForm(source: session, payload: { request.payload },
                      isPresented: Binding(get: { relayRequest != nil },
                                           set: { if !$0 { relayRequest = nil } }),
                      initialInstruction: request.instruction)
                .environmentObject(workspace)
        }
        .onChange(of: workspace.clipboardRelayTick) { _, _ in
            // Only the column with the keyboard. Every composer on screen is
            // watching the same counter, and three popovers opening at once is
            // not what "Send to Session…" means.
            guard isFocused else { return }
            relayRequest = RelayRequest(
                payload: Result { try Relay.payloadFromClipboard() },
                instruction: "")
        }
    }

    /// A relay that still needs a destination, or a payload that couldn't be
    /// built. Either way it opens the picker rather than failing silently.
    private struct RelayRequest: Identifiable {
        let id = UUID()
        let payload: Result<Relay.Payload, Error>
        let instruction: String
    }

    @State private var relayRequest: RelayRequest?

    /// Handle `/send`. Returns false for anything that isn't one, which goes to
    /// the agent untouched.
    private func relay(_ text: String) -> Bool {
        guard let request = Relay.parse(text, from: session, in: workspace)
        else { return false }

        let payload = Result { try Relay.payload(request.files, from: session) }
        // A destination that resolved goes straight out. Anything else — no
        // name, a name that matches nothing, a name that matches two things
        // equally, or a file that can't be read — opens the picker with what
        // you typed already in it.
        if let target = request.destination, case .success(let ready) = payload {
            Relay.send(ready, from: session, to: target,
                       instruction: request.instruction, in: workspace)
        } else {
            relayRequest = RelayRequest(payload: payload,
                                        instruction: request.instruction)
        }
        return true
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
                    .hoverCursor(.resizeLeftRight)
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
                        StartOfSession()
                        composer(prominent: true)
                        Spacer(minLength: 0)
                    }
                }
            } else if terminal {
                // Coding mode. A different renderer, not a different filter —
                // see `TerminalTranscript`. The composer and everything around
                // it stays: this is a view on the same session, and switching
                // back brings the cards with it.
                TerminalHeader(session: session)
                TerminalTranscript(session: session, mode: mode,
                                   scale: CGFloat(textScale))
                runPanel()
                composer()
            } else {
                TranscriptView(session: session, onEdit: { text in
                                   // The prose goes back in the field and the
                                   // files go back on the strip, separately —
                                   // the composer re-appends the `@path` lines
                                   // on send, so putting the raw text back
                                   // would duplicate them.
                                   //
                                   // Splitting and then dropping the files is
                                   // what the previous version did, which meant
                                   // editing a message that carried a
                                   // screenshot silently resent it without one.
                                   let (prose, files) = Attached.split(text)
                                   draft = prose
                                   for file in files where !session.attachments.contains(file) {
                                       session.attachments.append(file)
                                   }
                               },
                               mode: mode,
                               scale: CGFloat(textScale), width: CGFloat(readingWidth))
                    .environment(\.openArtifact) { artifact in
                        withAnimation(Motion.panel) {
                            // Written to disk and shown from there. A revision
                            // inherits the same path, so the panel — and your
                            // browser, if you sent it there — reloads into the
                            // new version rather than pointing at a dead one.
                            session.open(artifact)
                        }
                    }
                runPanel()
                composer()
            }
        }
        // Constraining the transcript and composer *together* aligned them and
        // dragged the scroll view in with them. The scroll view spans the pane;
        // both sides centre a column of the same width inside it.
        .animation(Motion.panel, value: session.items.isEmpty)
        // Alone, the rail sits in this pane's corner. Sharing the pane it
        // moves out to the window's trailing gutter — see `SessionColumns` —
        // because three stacks of pills is the dashboard this corner was
        // deliberately rescued from, and they'd be describing three different
        // sessions while looking like one control.
        .overlay(alignment: .topTrailing) {
            if !columned { StatusRail(session: session) }
        }
        // How much of loopback a preview in this pane may reach. See
        // `WebPreview.loopback` — agent-written markup gets this port or
        // nothing, rather than the run of 127.0.0.1.
        .environment(\.devServerPort, session.devServer.flatMap {
            $0.port ?? ($0.scheme == "https" ? 443 : 80)
        })
        .onAppear { session.prepare() }
    }

}



/// The head of an empty session.
private struct StartOfSession: View {
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
