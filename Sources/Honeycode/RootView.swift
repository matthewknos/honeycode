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
    /// Threaded down from `HoneycodeApp` rather than re-read from `@AppStorage`
    /// here. Two wrappers on one key do stay in sync, but the app also hangs
    /// `NSApp.appearance` off its `onChange` — so a second source of truth for
    /// this one would work until it didn't, in the one place where failing
    /// means popovers drawing dark text on light material.
    @Binding var appearance: HoneycodeApp.Appearance

    /// Which half of the app the sidebar is showing.
    ///
    /// The pill switches the *sidebar*, not the app: the window, the pane and
    /// the chrome are one thing throughout, and Code keeps its column
    /// arrangement while you're off looking at an agent. Persisted, because
    /// which half you were last in is the same kind of fact as which session.
    enum SidebarMode: String, CaseIterable {
        case code, crew, agents

        var title: String {
            switch self {
            case .code:    return "Code"
            case .crew:    return "Crew"
            case .agents:  return "Agents"
            }
        }

        var symbol: String {
            switch self {
            case .code:    return "chevron.left.forwardslash.chevron.right"
            case .crew:    return "person.2"
            case .agents:  return "sparkles"
            }
        }

        /// The switch that decides whether this half of the sidebar exists.
        /// Code has none: a window with no conversations in it is not a
        /// simpler Honeycode, it is a different program.
        var feature: Feature? {
            switch self {
            case .code:    return nil
            case .crew:    return .crew
            case .agents:  return .agents
            }
        }
    }

    @AppStorage("sidebar.mode") private var mode = SidebarMode.code

    /// The halves that are switched on.
    private var modes: [SidebarMode] {
        SidebarMode.allCases.filter { $0.feature.map(Features.isOn) ?? true }
    }

    /// Which one is actually showing.
    ///
    /// Read instead of `mode` everywhere the sidebar branches. The stored value
    /// is left alone: switching Crew off while you are looking at it puts you
    /// back in Code, and switching it on again puts you back where you were
    /// rather than somewhere the app chose.
    private var shownMode: SidebarMode { modes.contains(mode) ? mode : .code }
    @AppStorage("sidebarExpanded") private var expanded = true
    @State private var railTarget: RailTarget?
    @State private var railHovering = false
    @State private var menuHovering = false
    /// Held so the dialog keeps its title through the dismiss animation, which
    /// outlives `pendingDeletion` and was leaving `Delete “”?` on screen.
    @State private var deletionName = ""

    private var sidebarWidth: CGFloat { expanded ? Theme.sidebarWidth : Theme.railWidth }

    /// Whether the inspector is up.
    ///
    /// A window preference, not a session one. Which facts you want beside a
    /// conversation is a thing about how you work, and having it follow the
    /// session would mean the panel flickering in and out as you moved down the
    /// list.
    @AppStorage("inspector.shown") private var inspectorShown = true

    /// Whether the inspector has anything to describe.
    ///
    /// It is about a *session*, so Settings, Crew and Agents are not places it
    /// belongs — and a panel that stays up showing the last session's branch
    /// while you are looking at the agent roster is worse than no panel.
    private var inspectorFits: Bool {
        inspectorShown && describesSession
    }

    /// Whether the pane is showing a conversation at all.
    ///
    /// The inspector and the status strip both describe the focused session, so
    /// both have to know when the pane has been given to something else.
    private var describesSession: Bool {
        !workspace.showingSettings && shownMode == .code && workspace.selected != nil
    }

    /// What the pane is showing instead, for the status strip to name. Nil when
    /// it is a conversation, which is when the strip describes the session.
    private var paneName: String? {
        if workspace.showingSettings { return "Settings" }
        guard shownMode == .code else { return shownMode.title }
        return workspace.selected == nil ? "No session" : nil
    }

    var body: some View {
        ZStack {
            // The backdrop spans the whole window rather than just the pane.
            // That's what lets the collapsed rail read as part of the canvas —
            // the sidebar paints over this, or it doesn't.
            PaneBackground(store: background)

            VStack(spacing: 0) {
                // Across the whole window, above everything, including the
                // sidebar. That is the difference between a title bar and a
                // toolbar: a toolbar belongs to a pane and stops at its edge,
                // and everything in this one — which session, the search, the
                // appearance — is about the window rather than about a pane.
                TitleBar(workspace: workspace, background: background,
                         sidebarExpanded: $expanded,
                         inspectorShown: $inspectorShown,
                         showPalette: $showPalette,
                         appearance: $appearance)

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
                        // Settings covers the pane and leaves the sidebar alone,
                        // which is what makes every way out of it a place you were
                        // already looking at — a session in the list, the pill, or
                        // the footer row you came in by.
                        if workspace.showingSettings {
                            SettingsPane(workspace: workspace, background: background,
                                         appearance: $appearance)
                        } else {
                            switch shownMode {
                            case .code:   SessionPane(workspace: workspace)
                            case .crew:   CrewPane(workspace: workspace)
                            case .agents: AgentsPane(store: agents, workspace: workspace)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if inspectorFits, let session = workspace.selected {
                        Divider().overlay(Theme.rule)
                        Inspector(session: session, workspace: workspace)
                            .frame(width: Theme.inspectorWidth)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .frame(maxHeight: .infinity)

                // Along the foot, and for the same reason as the bar at the
                // top: what it says is true of the window, not of a pane.
                StatusBar(workspace: workspace, elsewhere: paneName)
            }
        }
        .animation(Motion.reveal, value: expanded)
        .animation(Motion.panel, value: inspectorFits)
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 900, minHeight: 580)
        .background(WindowChrome())
        .overlay {
            if showPalette {
                CommandPalette(workspace: workspace, isPresented: $showPalette)
            }
        }
        // One sheet for every route to a new session — the sidebar header, an
        // account's hover `+`, both rail popovers, ⌘N and the File menu. Driven
        // from the workspace rather than from view state because the menu bar
        // sits outside the view hierarchy and could never reach the file panel
        // the other five were each opening for themselves.
        .sheet(item: Binding(get: { workspace.newSessionRequest.map(NewSessionRequest.init) },
                             set: { workspace.newSessionRequest = $0?.account })) { request in
            NewSessionSheet(workspace: workspace, initial: request.account)
        }
        // The first run, or a way back into it from the app menu. Raised here
        // rather than presented from `HoneycodeApp` because a sheet needs a
        // view to hang from, and this is the only one the window has.
        .sheet(isPresented: $workspace.showingSetup) {
            SetupFlow(workspace: workspace)
        }
        // The floating window is reconciled from `poppedOut` rather than opened
        // and closed at the call sites, so every route in — the row menu, the
        // menu bar, a restored arrangement at launch — goes through one path.
        .onAppear {
            PopOut.shared.sync(workspace: workspace, background: background)
            if Setup.needsRun { workspace.showingSetup = true }
        }
        // Asked for by the Features pane. Still a notification rather than a
        // direct write: `FeatureSettings` is a private view several levels down
        // and has no business holding the workspace to set one flag. What it no
        // longer needs is the `NSApp.activate` that used to go with it — the
        // pane asking is in this window now, not in a second one the flow would
        // have opened behind. Settings steps aside so the flow isn't answering
        // questions on top of the pane that sets the same switches.
        .onReceive(NotificationCenter.default.publisher(for: Setup.requested)) { _ in
            workspace.showingSettings = false
            workspace.showingSetup = true
        }
        // Choosing a session is a way out of Settings: you clicked the thing
        // you wanted to look at, so look at it.
        //
        // Watched here rather than handled in the row, because `SidebarRow`
        // documents at length why it carries no tap recogniser — any gesture on
        // a `List` row has to wait out the double-click interval and eats the
        // row's own selection while it does. The cost of watching instead is
        // that re-clicking the row that is *already* selected writes nothing
        // and so doesn't land; the pill, the footer row and Done all do.
        .onChange(of: workspace.selection) { _, _ in
            if workspace.showingSettings {
                withAnimation(Motion.panel) { workspace.showingSettings = false }
            }
        }
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
        } else {
            // The same ground as the pane, and the rule beside it is the whole
            // of the boundary.
            //
            // This was `NSVisualEffectView` on `.sidebar`, which is the Mac's
            // standard treatment and was wrong here for a reason particular to
            // this window. That material is a *vibrancy* layer: it samples the
            // desktop behind the window and lightens, so the panel came out a
            // paler, bluer grey than the canvas two points to its right and
            // drifted as you moved the window over a different wallpaper. In an
            // app whose ground is a deliberate warm neutral — and which can put
            // a photograph behind the pane — a strip down the left that is
            // quietly a different colour from everything else reads as an
            // unfinished seam rather than as depth.
            //
            // The glassy case already did exactly this, and had to: the same
            // reasoning applies whether or not there is a photo behind it.
            Theme.canvas
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
                switch shownMode {
                case .code:   SidebarList(workspace: workspace)
                case .crew:   CrewSidebar(workspace: workspace) { id in
                                  workspace.reveal(id)
                                  withAnimation(Motion.hover) { mode = .code }
                              }
                case .agents: AgentList(store: agents)
                }
                footer
            }
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
            // Symmetric top and bottom, so the two floating controls read as
            // a pair rather than as two things that happen to be near corners.
            // They used to be inset by the traffic-light clearance, which the
            // rail no longer has to think about: the lights are in the title
            // bar above this now.
            .padding(.top, Theme.s5)
            .padding(.bottom, Theme.s5)
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

    /// The collapsed sidebar's contents.
    ///
    /// No expand button of its own any more. It had one, directly under the
    /// title bar's — two positions for one control, which is the trap this
    /// window's own history is a record of: the status rail was replaced
    /// precisely because it drew one thing in two places depending on the
    /// layout. The toggle is in the title bar, in both states, a few points
    /// above where this button used to be.
    private var railGroup: some View {
        VStack(spacing: Theme.s5) {
            // The pill, as icons. All of them always drawn, the inactive ones
            // dimmed — a single glyph that changed its own meaning would be a
            // control you have to press to find out what it does.
            //
            // Off `modes`, like the expanded pill, rather than a hand-written
            // list. The list had the symbols spelled out a second time and did
            // not consult the switches at all, so a collapsed sidebar offered
            // Crew on a Mac with Crew switched off.
            ForEach(modes, id: \.self) { railMode($0) }

            // `shownMode` for the same reason `newButton` reads it: the
            // stored mode can name a half that is switched off.
            if shownMode == .agents {
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
                                ForEach(Account.enabled) { account in
                                    PopoverRow(title: account.title,
                                               blurb: account.agentName) {
                                        railTarget = nil
                                        workspace.requestNewSession(account)
                                    }
                                }
                            }
                        )
                        .frame(width: Theme.popoverWidth)
                    }

                // The rail is the sidebar's own list at 60pt, so it lists
                // what the sidebar lists — including an account switched off
                // that still holds conversations.
                ForEach(workspace.listedAccounts) { account in
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

    private func railMode(_ value: SidebarMode) -> some View {
        let on = shownMode == value
        return Image(systemName: value.symbol)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(on ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .frame(width: 28, height: 22)
            .background(on ? Theme.well : .clear,
                        in: RoundedRectangle(cornerRadius: Theme.cornerChip))
            .contentShape(Rectangle())
            .onHover { if $0 { railTarget = nil } }
            .onTapGesture { withAnimation(Motion.hover) { mode = value } }
            .help(Self.railHelp(value))
    }

    /// One agent, filled while a run is in flight — so the rail reports that
    /// something is happening without having to be expanded.
    private func railAgentDot(_ agent: AgentDefinition) -> some View {
        let running = agents.running[agent.id] != nil
        return AccountDot(agent.account,
                          dimmed: agent.isEnabled ? (running ? 1 : 0.55) : 0.25,
                          size: running ? Theme.dot + Theme.s1 : Theme.dot)
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

        return AccountDot(account, dimmed: sessions.isEmpty ? 0.3 : 1)
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
                            .font(Theme.row)
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
                        workspace.requestNewSession(account)
                    }
                    }
                )
                .frame(width: Theme.popoverWidth)
            }
    }

    /// Just Settings now.
    ///
    /// The identity control that used to sit above it is in the title bar, and
    /// there is exactly one of it — which is the point. It was here *and* in
    /// the expanded sidebar's footer, two controls for one app-wide fact, each
    /// visible in a state the other wasn't. The title bar is up in both states
    /// and is where this platform has always put "who am I signed in as".
    private var railSettings: some View {
        VStack(spacing: Theme.s2) {
            settingsGlyph
        }
        .padding(.vertical, Theme.s2)
        .modifier(RailSurface(glass: background.isGlassy))
    }

    private var settingsGlyph: some View {
        Button {
            withAnimation(Motion.panel) { workspace.showingSettings.toggle() }
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 12.5))
                .foregroundStyle(workspace.showingSettings
                                 ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(workspace.showingSettings ? "Close Settings (⌘,)" : "Settings (⌘,)")
    }

    /// Settings, pinned to the bottom edge.
    ///
    /// A plain button over `Workspace.showingSettings`. It was a `SettingsLink`
    /// — chosen over poking the private `showSettingsWindow:` selector through
    /// `NSApp.sendAction`, which was right while there was a window to open.
    /// There isn't: Settings is a pane now, so this is a row that selects one,
    /// and it shows that the way every other row in this sidebar does.
    private var footer: some View {
        VStack(spacing: 0) {
            Divider().overlay(Theme.rule)

            Button {
                withAnimation(Motion.panel) { workspace.showingSettings.toggle() }
            } label: {
                HStack(spacing: Theme.s3) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12.5))
                        .foregroundStyle(workspace.showingSettings
                                         ? AnyShapeStyle(.primary)
                                         : AnyShapeStyle(.secondary))
                        // Same 12pt leading column the session rows use, so the
                        // footer aligns with the list above rather than sitting
                        // a few points off it.
                        .frame(width: 12, alignment: .center)

                    if expanded {
                        Text("Settings")
                            .font(Theme.sidebarRow)
                        Spacer(minLength: 0)
                        Text("⌘,")
                            .font(Theme.note)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, expanded ? Theme.s4 : 0)
                .padding(.vertical, Theme.s3)
                .frame(maxWidth: .infinity, alignment: expanded ? .leading : .center)
                .contentShape(Rectangle())
            }
            .buttonStyle(SidebarFooterButton(selected: workspace.showingSettings))
            .padding(.horizontal, expanded ? Theme.s4 : Theme.s3)
            .padding(.vertical, Theme.s3)
        }
    }

    /// What the list is, how much of it is live, and how to add to it.
    ///
    /// The collapse button that used to be here is in the title bar now, where
    /// it belongs: the sidebar is one of three columns the window arranges, and
    /// a control for hiding a column that lives *inside* that column is a
    /// control that disappears with the thing it operates.
    ///
    /// What replaced it is the thing the sidebar never said — how many of these
    /// are running. The rows each carry a spinner, so with nine sessions in
    /// four accounts the answer was there but had to be counted, and with the
    /// list scrolled it was not there at all.
    private var header: some View {
        HStack(spacing: Theme.s3) {
            Text(shownMode == .code ? "SESSIONS" : shownMode.title.uppercased())
                .font(Theme.captionStrong)
                .kerning(0.6)
                .foregroundStyle(.secondary)

            if shownMode == .code, live > 0 {
                Text("\(live) live")
                    .font(Theme.caption)
                    .monospacedDigit()
                    .foregroundStyle(Theme.stateLive)
                    .padding(.horizontal, Theme.s3)
                    .padding(.vertical, 1)
                    .background(Theme.stateLive.opacity(0.14), in: Capsule())
                    .transition(.opacity)
                    .help("\(live) of \(workspace.sessions.count) sessions are working")
            }

            Spacer(minLength: 0)

            newButton
        }
        // Fixed, not sized to its contents. Crew's `newButton` is an
        // `EmptyView` — see below — so without this the row is as tall as its
        // text there and as tall as a 24pt button in the other two, and the
        // word at the top of the sidebar jumped seven points as you switched.
        .frame(height: 24)
        .padding(.horizontal, Theme.s5)
        .padding(.bottom, Theme.s3)
        .animation(Motion.reveal, value: live)
    }

    /// How many agents are working right now.
    private var live: Int { workspace.sessions.filter(\.isRunning).count }

    /// Code / Crew / Agents.
    ///
    /// A segmented control rather than tabs or a popup: the halves are all
    /// worth naming, and the one you aren't in should stay visible — a control
    /// that hides the alternative is how a second mode goes undiscovered.
    ///
    /// Nothing at all when Crew and Agents are both switched off. A segmented
    /// control with one segment is a label wearing a control's clothes, and the
    /// thing it would be switching to is the thing already on screen.
    @ViewBuilder
    private var pill: some View {
        if modes.count > 1 {
            HStack(spacing: Theme.s1) {
                ForEach(modes, id: \.self) { value in
                    segment(value)
                }
            }
            .padding(Theme.s1)
            // Concentric with the segments inside it — see `Theme.corner`.
            .background(Theme.well,
                        in: RoundedRectangle(cornerRadius: Theme.corner(
                            around: Theme.cornerChip, inset: Theme.s1)))
            .padding(.horizontal, Theme.s5)
            .padding(.bottom, Theme.s5)
        }
    }

    private func segment(_ value: SidebarMode) -> some View {
        let on = shownMode == value
        return Button {
            withAnimation(Motion.hover) { mode = value }
            // The pill switches the sidebar, and the pane follows it — so
            // reaching for Code while Settings is up has to mean Code.
            if workspace.showingSettings {
                withAnimation(Motion.panel) { workspace.showingSettings = false }
            }
        } label: {
            HStack(spacing: Theme.s2) {
                Image(systemName: value.symbol)
                    .font(.system(size: 10, weight: .medium))
                Text(value.title)
                    .font(Theme.label)
            }
            .foregroundStyle(on ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .frame(maxWidth: .infinity)
            .frame(height: 22)
            .background(on ? Theme.surface : .clear,
                        in: RoundedRectangle(cornerRadius: Theme.cornerChip))
            // One elevation vocabulary — see `Theme.shadowLow`. This was a
            // hand-tuned 0.12/1/0.5, which is close enough to the shared value
            // that the difference was invisible and far enough that it was a
            // second definition of "slightly raised".
            .shadow(color: on ? Theme.shadowLow.colour : .clear,
                    radius: Theme.shadowLow.radius, y: Theme.shadowLow.y)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Self.segmentHelp(value))
    }

    /// One place per mode for the two tooltips, rather than a ternary that
    /// silently mislabels the third the moment a third exists — which is what
    /// `value == .code ? … : …` did the instant Crew was added.
    private static func segmentHelp(_ value: SidebarMode) -> String {
        switch value {
        case .code:    return "Conversations you started"
        case .crew:    return "Who is running, what you have, and your saved teams"
        case .agents:  return "Agents that run on their own"
        }
    }

    private static func railHelp(_ value: SidebarMode) -> String {
        switch value {
        case .code:    return "Sessions"
        case .crew:    return "Crew"
        case .agents:  return "Agents"
        }
    }

    /// The `+` means different things on the two sides, so it does.
    ///
    /// `shownMode`, not `mode`: the stored mode can name a half that is
    /// switched off, and the header would then offer a button for a pane that
    /// isn't on screen. Everything else that branches on the sidebar already
    /// reads `shownMode`; this one had been left behind.
    @ViewBuilder
    private var newButton: some View {
        switch shownMode {
        case .code:
            newSessionMenu
        case .crew:
            // Nothing is created here. A crew is assembled inside a session,
            // and a `+` that quietly switched you to another mode to do it
            // would be a button that answers a question you didn't ask.
            EmptyView()
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
                    choices: Account.enabled.map { account in
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

    private func add(to account: Account) { workspace.requestNewSession(account) }
}

// MARK: - The pane

/// One conversation, filling the pane.
///
/// This replaces `SessionColumns`, which put up to three side by side and
/// divided the pane with draggable weights. Columns were a real feature and
/// they are a real loss; what they cost was every fact about a session having
/// to be said once per column, at whatever width that column happened to be —
/// which is why the header above each transcript grew a ladder of breakpoints
/// shedding the folder, then the branch, then the usage, then the crew chips,
/// in the arrangement where you most wanted them.
///
/// With one conversation in the pane those facts move out to surfaces that are
/// as wide as the window and never compete with the transcript: the breadcrumb
/// in the title bar, the strip along the foot, the inspector down the trailing
/// edge. The pane itself is left to do one thing.
///
/// Two conversations at once is still reachable — `Workspace.popOut` puts one
/// in a floating window that stays above other apps, which is the case columns
/// were mostly being used for.
private struct SessionPane: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        if let session = workspace.selected {
            Group {
                // Out in the floating window. A placeholder rather than the
                // transcript, so there is an obvious way home that doesn't
                // involve finding the floating window first.
                if workspace.poppedOut == session.id {
                    PoppedOutColumn(session: session, workspace: workspace)
                } else {
                    SessionView(session: session, workspace: workspace)
                }
            }
            // Rebuild on identity change, or the transcript's scroll position
            // and the composer's draft leak across sessions.
            .id(session.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            EmptyDetail().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct EmptyDetail: View {
    var body: some View {
        VStack(spacing: Theme.s2) {
            Text("No session")
                .font(Theme.display(Theme.t6))
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
    /// Whether this view has the keyboard. Alone in the pane, always — the
    /// pop-out window and the Agents side pass their own answer.
    var isFocused = true
    /// A way out of this pane, when it was reached from somewhere other than
    /// the session list. The Agents side passes one.
    var onBack: (() -> Void)?
    @State private var draft = ""
    /// Hoisted out of `Workbench`, which used to be the only way to reach the
    /// form. The tab strip offers it too now — the reference for "I am done,
    /// ship this" is the top of the pane, not four rows down inside a list of
    /// diffs — and two entry points to one sheet need one piece of state.
    @State private var openingPullRequest = false
    @AppStorage("transcript.mode") private var mode = TranscriptMode.normal
    @AppStorage("transcript.terminal") private var terminal = false
    @AppStorage("transcript.textScale") private var textScale: Double = 1
    @AppStorage("transcript.width") private var readingWidth: Double = Double(Theme.readingWidth)
    /// A crew run has started, and the workbench isn't showing it.
    ///
    /// The panel itself moved into the workbench's Run tab — see `Workbench`.
    /// What stays here is one line above the composer, and only while the
    /// workbench is closed or looking elsewhere: a run is the one piece of
    /// state that starts without you asking for it, so it has to be able to
    /// announce itself from inside the conversation. Clicking it opens the tab.
    @ViewBuilder
    private func runBanner() -> some View {
        if let run = session.crewRun, run.isBusy, session.paneTab != .run {
            Button {
                withAnimation(Motion.panel) { session.paneTab = .run }
            } label: {
                HStack(spacing: Theme.s3) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.55)
                        .frame(width: 12, height: 12)
                    Text(runHeadline(run))
                        .font(Theme.label)
                        .foregroundStyle(Theme.stateLive)
                    if let phase = run.phase {
                        Text(phase)
                            .font(Theme.label)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: Theme.s4)
                    Text("Watch")
                        .font(Theme.label)
                        .foregroundStyle(Color.accentColor)
                }
                .padding(.horizontal, Theme.s5)
                .padding(.vertical, Theme.s3 + 1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(InsetSurface(radius: Theme.cornerField))
            .frame(maxWidth: terminal ? .infinity : CGFloat(readingWidth))
            .frame(maxWidth: .infinity)
            .padding(.horizontal, terminal ? 0 : Theme.pane)
            .padding(.top, Theme.s5)
            .transition(.opacity)
        }
    }

    private func runHeadline(_ run: CrewRun) -> String {
        let live = run.members.filter {
            $0.state == .working || $0.state == .answering
        }.count
        guard !run.members.isEmpty else { return "Planning" }
        return live == 0
            ? "\(run.members.count) agent\(run.members.count == 1 ? "" : "s")"
            : "\(live) of \(run.members.count) working"
    }

    private func composer(prominent: Bool = false) -> some View {
        // Nothing to match any more: the transcript's scroller is off, so
        // neither side reserves width for one and both centre in the full pane.
        ComposerView(draft: $draft, session: session, workspace: workspace,
                     prominent: prominent,
                     width: CGFloat(readingWidth),
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
            VStack(spacing: 0) {
                // Always, and always first. The strip is what makes the pane a
                // pane: it names the five things this session can show you and
                // which of them you are looking at, including the case the old
                // arrangement had no way to draw — the conversation itself.
                PaneTabs(session: session, workspace: workspace,
                         openingPullRequest: $openingPullRequest,
                         available: geometry.size.width,
                         onBack: onBack)

                if session.paneTab.isAgent {
                    conversation
                } else if session.splitOpen {
                    // The arrangement this app already had: the artefact beside
                    // the conversation that produced it. What changed is only
                    // that it is now a choice with a name on it rather than the
                    // implicit meaning of a panel being open.
                    HStack(spacing: 0) {
                        conversation
                        resizer(in: geometry.size.width)
                        Workbench(session: session, workspace: workspace,
                                  openingPullRequest: $openingPullRequest)
                            .modifier(Elevated(depth: .high))
                            .frame(width: clamped(panelWidth, in: geometry.size.width))
                            // Width follows the pointer exactly while dragging;
                            // an inherited animation would make it lag behind by
                            // whatever the curve's duration is.
                            .transaction { if liveWidth != nil { $0.animation = nil } }
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                } else {
                    Workbench(session: session, workspace: workspace,
                              openingPullRequest: $openingPullRequest)
                }
            }
        }
        .animation(Motion.panel, value: session.paneTab)
        .animation(Motion.panel, value: session.splitOpen)
        .sheet(isPresented: $openingPullRequest) {
            // A sheet, and the one thing here that should be. Opening a pull
            // request is a form with a commit at the end of it — a decision you
            // finish or abandon — which is what a sheet is for.
            PullRequestSheet(session: session,
                             changes: Changes.summarise(session.items),
                             isPresented: $openingPullRequest)
        }
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
        let floor = Theme.workbenchMinWidth
        return min(max(CGFloat(width), floor), max(floor, total - 420))
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
                StartPane(session: session, workspace: workspace,
                          width: CGFloat(readingWidth),
                          suggest: { draft = $0 }) { prominent in
                    composer(prominent: prominent)
                }
            } else if terminal {
                // Coding mode. A different renderer, not a different filter —
                // see `TerminalTranscript`. The composer and everything around
                // it stays: this is a view on the same session, and switching
                // back brings the cards with it.
                TerminalHeader(session: session)
                TerminalTranscript(session: session, mode: mode,
                                   scale: CGFloat(textScale))
                runBanner()
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
                    // Nil with Preview switched off, which is what removes the
                    // Open affordance from every artifact card — `CodeBlock`
                    // already draws the card without one when there is nowhere
                    // to open it. The alternative was a button leading to a tab
                    // that isn't in the row.
                    .environment(\.openArtifact, Features.isOn(.preview) ? { artifact in
                        withAnimation(Motion.panel) {
                            // Written to disk and shown from there. A revision
                            // inherits the same path, so the panel — and your
                            // browser, if you sent it there — reloads into the
                            // new version rather than pointing at a dead one.
                            session.open(artifact)
                        }
                    } : nil)
                runBanner()
                composer()
            }
        }
        // Constraining the transcript and composer *together* aligned them and
        // dragged the scroll view in with them. The scroll view spans the pane;
        // both sides centre a column of the same width inside it.
        .animation(Motion.panel, value: session.items.isEmpty)
        // How much of loopback a preview in this pane may reach. See
        // `WebPreview.loopback` — agent-written markup gets this port or
        // nothing, rather than the run of 127.0.0.1.
        .environment(\.devServerPort, session.devServer.flatMap {
            $0.port ?? ($0.scheme == "https" ? 443 : 80)
        })
        .onAppear { session.prepare() }
    }

}



// The head of an empty session lives in `StartPane` now — it grew a
// roster and a line of grammar, neither of which belongs in the window file.
