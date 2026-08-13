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
                                 background.forcesLightContent ? .light : systemScheme)
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
    /// Whether this column has the keyboard. Alone, always.
    var isFocused = true
    /// Whether it's sharing the pane. Drives the things that only earn their
    /// place when there's something to tell this column apart *from*.
    var columned = false
    @State private var draft = ""
    @AppStorage("transcript.mode") private var mode = TranscriptMode.normal
    @AppStorage("transcript.textScale") private var textScale: Double = 1
    @AppStorage("transcript.width") private var readingWidth: Double = Double(Theme.readingWidth)
    private func composer(prominent: Bool = false) -> some View {
        // Nothing to match any more: the transcript's scroller is off, so
        // neither side reserves width for one and both centre in the full pane.
        ComposerView(draft: $draft, session: session, prominent: prominent,
                     width: CGFloat(readingWidth),
                     accent: columned ? session.account.accent : nil,
                     subtitle: columned ? session.name : nil,
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

struct StatusRail: View {
    @ObservedObject var session: Session
    /// Icons only, stacked to fit the 60pt gutter.
    var compact = false

    @EnvironmentObject private var background: BackgroundStore
    /// Only for the pop-out row below, which is a question about where this
    /// conversation lives rather than about the session itself.
    @EnvironmentObject private var workspace: Workspace
    @AppStorage("transcript.mode") private var mode = TranscriptMode.normal
    @State private var showingChanges = false
    @State private var showingViewMenu = false
    /// Read when the menu opens, not when the rail draws — `gh auth status`
    /// spawns a process and touches the keychain, and this corner redraws
    /// while a reply streams.
    @State private var gitHubAccounts: [GitHubAccount] = []
    @State private var gitHubLoaded = false
    @State private var gitHubFailure: String?
    @State private var azureAccounts: [AzureAccount] = []
    @State private var azureLoaded = false
    @State private var azureFailure: String?

    /// A function, not a computed property, and called only from the two places
    /// that present it.
    ///
    /// As a property read from `body` it ran on every redraw — walking the
    /// whole transcript and copying every diff's rows into fresh structs, sixty
    /// times a second while a reply streams — to answer a question nobody was
    /// asking unless the View menu or the Changes sheet was actually open.
    private func currentChanges() -> [FileChange] { Changes.summarise(session.items) }

    var body: some View {
        Group {
            if compact { collapsed } else { expanded }
        }
        .sheet(isPresented: $showingChanges) {
            ChangesView(session: session, changes: currentChanges(),
                        isPresented: $showingChanges)
        }
    }

    /// Icons only, in the gutter.
    ///
    /// The words go because there's 60pt to work in, and because they were
    /// saying "Normal" and a repository name over a pane that already has two
    /// composers naming themselves. What's left is the same two controls with
    /// the same two popovers — the labels move into the tooltips, which is
    /// where a Mac keeps them when a control is this small.
    ///
    /// Deliberately shaped like the collapsed sidebar opposite: same 28pt
    /// controls, same centring in the same width, so the window reads as having
    /// two matching gutters rather than a rail on one side and a rail-ish thing
    /// on the other.
    private var collapsed: some View {
        VStack(spacing: Theme.s5) {
            viewMenu
            ProjectBadge(directory: session.directory,
                         glass: background.isGlassy, compact: true)
        }
        .padding(.vertical, Theme.s4)
        .modifier(RailSurface(glass: background.isGlassy))
        .padding(.top, Chrome.trafficLightClearance - Theme.s5)
        .frame(width: Theme.railWidth)
    }

    /// This corner had grown a row of unrelated readouts — mode, limits,
    /// context, spend, changes, server — all competing with the transcript for
    /// the same few hundred points. The numbers belong beside the thing that
    /// spends them, so they moved to the composer; what's left is a menu of
    /// *views*, which is the only thing this corner was ever really for.
    private var expanded: some View {
        VStack(alignment: .trailing, spacing: Theme.s3) {
            viewMenu
                .padding(.horizontal, background.isGlassy ? Theme.s4 : 0)
                .padding(.vertical, background.isGlassy ? Theme.s3 : 0)
                .modifier(StatusSurface(glass: background.isGlassy))
            // Under the pill rather than beside it: this says where you are,
            // which is a different kind of thing from what the pill offers, and
            // a row of four controls in one corner is how that corner became a
            // dashboard the last time.
            ProjectBadge(directory: session.directory, glass: background.isGlassy)
        }
        .padding(.top, Chrome.trafficLightClearance - Theme.s5)
        .padding(.trailing, Theme.s6)
    }

    /// Same popover as the model picker — sections, two-line rows, trailing
    /// checks — because it's the same kind of control doing the same job.
    private var viewMenu: some View {
        Button { showingViewMenu.toggle() } label: {
            HStack(spacing: Theme.s2 - 1) {
                Image(systemName: "sidebar.squares.right")
                    .font(.system(size: compact ? 13 : 10, weight: .medium))
                if !compact {
                    Text(mode.title)
                        .font(.system(size: 11.5, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, compact ? 0 : Theme.s4)
            .padding(.vertical, Theme.s2)
            .frame(width: compact ? 28 : nil, height: compact ? 24 : nil)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverCapsule())
        .help(help)
        .popover(isPresented: $showingViewMenu, arrowEdge: .bottom) {
            // Summarised once, when the menu opens.
            let changes = currentChanges()
            VStack(alignment: .leading, spacing: 0) {
                PopoverHeader("Panels")
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
                        if session.browserVisible, session.browserHTML == nil,
                           session.browserFile == nil {
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

                // The discoverable way in. The row menus carry it too, but a
                // context menu is not an affordance — and this corner is
                // already where you go to decide what you're looking at.
                PopoverRow(title: "Pop Out",
                           blurb: "A small window that stays above other apps",
                           selected: workspace.poppedOut == session.id) {
                    showingViewMenu = false
                    if workspace.poppedOut == session.id {
                        workspace.popIn()
                    } else {
                        workspace.popOut(session.id)
                    }
                }

                Divider().overlay(Theme.rule).padding(.vertical, Theme.s2)
                PopoverHeader("Transcript detail")
                ForEach(TranscriptMode.allCases) { option in
                    PopoverRow(title: option.title, blurb: option.blurb,
                               selected: mode == option) {
                        mode = option
                        showingViewMenu = false
                    }
                }

                Divider().overlay(Theme.rule).padding(.vertical, Theme.s2)
                PopoverHeader("GitHub account")
                gitHubAccountRows

                Divider().overlay(Theme.rule).padding(.vertical, Theme.s2)
                PopoverHeader("Azure account")
                azureAccountRows
            }
            .padding(.vertical, Theme.s3)
            .frame(width: 272)
            // Every time the menu opens rather than once: `gh auth login`,
            // `gh auth switch` and `az login` all happen in terminals, and a
            // stale tick beside the wrong account is worse than no tick at all.
            .task {
                await loadGitHubAccounts()
                await loadAzureAccounts()
            }
        }
    }

    /// Which GitHub identity a push from this app will use, and the switch.
    ///
    /// Here rather than in Settings because it's a per-moment answer, not a
    /// preference: it changes when you move between a work repo and a personal
    /// one, which is the same moment you're already in this corner. It replaces
    /// the chip that used to name the repository below — that said where the
    /// code was going and left out who was taking it there.
    @ViewBuilder private var gitHubAccountRows: some View {
        if !GitHubAuth.isInstalled {
            PopoverRow(title: "`gh` isn't installed",
                       blurb: "brew install gh") {}
                .disabled(true)
                .opacity(0.5)
        } else if !gitHubLoaded {
            PopoverRow(title: "Checking…", blurb: nil) {}
                .disabled(true)
                .opacity(0.5)
        } else {
            ForEach(gitHubAccounts) { account in
                PopoverRow(title: account.login,
                           blurb: blurb(for: account),
                           selected: account.isActive) {
                    Task { await select(account) }
                }
                // Switching to an account whose token `gh` has already told us
                // is dead would look like it worked and then fail on the push.
                .disabled(!account.isValid)
                .opacity(account.isValid ? 1 : 0.5)
            }
            if let gitHubFailure {
                Text(gitHubFailure)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Theme.s5)
                    .padding(.top, Theme.s2)
            }
            // The way you get a second account, said where you go looking for
            // one. Signing in is `gh`'s job and needs a terminal, so this is a
            // door to it rather than a form — but a menu that lists one account
            // and no way to have two is a dead end you have to already know the
            // command to leave.
            PopoverRow(title: gitHubAccounts.isEmpty
                           ? "Sign in to GitHub…" : "Add an account…",
                       blurb: "Runs `gh auth login` in a terminal") {
                showingViewMenu = false
                if let script = GitHubAuth.loginScript() {
                    NSWorkspace.shared.open(script)
                }
            }
        }
    }

    /// The host when it isn't github.com, and the state when it isn't fine.
    ///
    /// Not "Active" on the current one — the checkmark says that, and a row
    /// carrying both says it twice.
    private func blurb(for account: GitHubAccount) -> String? {
        var parts: [String] = []
        if let host = account.hostNote { parts.append(host) }
        if !account.isValid { parts.append("token expired — gh auth login") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Which Azure identity `az` is acting as, and the switch.
    ///
    /// The chip below the pill names a resource group; it has never been able
    /// to say whose. With two tenants in play that's the difference between
    /// deploying to the right estate and the wrong one, and it isn't inferable
    /// from a group name.
    @ViewBuilder private var azureAccountRows: some View {
        if !AzureAuth.isInstalled {
            PopoverRow(title: "`az` isn't installed",
                       blurb: "brew install azure-cli") {}
                .disabled(true)
                .opacity(0.5)
        } else if !azureLoaded {
            PopoverRow(title: "Checking…", blurb: nil) {}
                .disabled(true)
                .opacity(0.5)
        } else {
            ForEach(azureAccounts) { account in
                PopoverRow(title: account.user,
                           blurb: account.detail,
                           selected: account.isActive) {
                    Task { await select(account) }
                }
                // An account whose every subscription is disabled has nothing
                // to switch *to*.
                .disabled(account.target == nil)
                .opacity(account.target == nil ? 0.5 : 1)
            }
            if let azureFailure {
                Text(azureFailure)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Theme.s5)
                    .padding(.top, Theme.s2)
            }
            PopoverRow(title: azureAccounts.isEmpty
                           ? "Sign in to Azure…" : "Add an account…",
                       blurb: "Runs `az login` in a terminal") {
                showingViewMenu = false
                if let script = AzureAuth.loginScript() {
                    NSWorkspace.shared.open(script)
                }
            }
        }
    }

    private func loadAzureAccounts() async {
        let found = await Task.detached(priority: .userInitiated) {
            AzureAuth.accounts()
        }.value
        azureAccounts = found
        azureLoaded = true
    }

    private func select(_ account: AzureAccount) async {
        await switchAccount(perform: { try AzureAuth.select(account) },
                            reload: loadAzureAccounts) { azureFailure = $0 }
    }

    /// Switch, then re-read rather than assume.
    ///
    /// The CLI is the record here, not this list — reading it back is what
    /// keeps the tick honest if the switch half-worked.
    private func switchAccount(perform: @escaping @Sendable () throws -> Void,
                               reload: () async -> Void,
                               failure: (String?) -> Void) async {
        failure(nil)
        do {
            try await Task.detached(priority: .userInitiated) { try perform() }.value
            await reload()
            showingViewMenu = false
        } catch {
            failure((error as? CommandFailure)?.detail
                ?? error.localizedDescription)
            await reload()
        }
    }

    private func loadGitHubAccounts() async {
        let found = await Task.detached(priority: .userInitiated) {
            GitHubAuth.accounts()
        }.value
        gitHubAccounts = found
        gitHubLoaded = true
    }

    private func select(_ account: GitHubAccount) async {
        await switchAccount(perform: { try GitHubAuth.select(account) },
                            reload: loadGitHubAccounts) { gitHubFailure = $0 }
    }

    /// The mode, and who you're signed in as once that's known — which is only
    /// after the menu has been opened once, since that's what reads it.
    private var help: String {
        var lines = [compact ? "View — \(mode.title)" : "View"]
        if let github = gitHubAccounts.first(where: \.isActive)?.login {
            lines.append("GitHub: \(github)")
        }
        if let azure = azureAccounts.first(where: \.isActive)?.user {
            lines.append("Azure: \(azure)")
        }
        return lines.joined(separator: "\n")
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
