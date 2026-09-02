import SwiftUI

@main
struct HoneycodeApp: App {

    /// Owned here rather than in `RootView` so the menu bar can drive it —
    /// `.commands` sits outside the view hierarchy and can't reach view state.
    @StateObject private var workspace = Workspace()
    @StateObject private var background = BackgroundStore()
    /// Built empty and handed the roster in `onAppear`. It can't take one at
    /// init: `@StateObject` initialisers are stored properties, so they run
    /// before this type's own `init` body and before `workspace` exists.
    @StateObject private var agents = AgentStore()
    @State private var showPalette = false

    /// Every colour in the app is semantic, so the whole thing follows the
    /// system appearance for free. This override exists only so you can judge
    /// light against dark without going to System Settings and back.
    @AppStorage("appearance") private var appearance = Appearance.system
    @AppStorage("transcript.mode") private var transcriptMode = TranscriptMode.normal
    @AppStorage("transcript.terminal") private var codingMode = false
    /// The two panels either side of the pane. Owned by `RootView`; watched
    /// here on the same keys so the View menu can drive them.
    ///
    /// A second wrapper on one key is exactly what the `appearance` binding
    /// above is threaded down to avoid — but that one is different: the app
    /// also hangs `NSApp.appearance` off its `onChange`. These two have no side
    /// effect beyond the layout, so two views of one default is all they are.
    ///
    /// They are in this menu because the collapsed rail lost its own expand
    /// button in the redesign — deliberately, so there is one of it — and a
    /// window switch reachable from exactly one 24pt glyph and no menu and no
    /// key is a switch somebody will not find.
    @AppStorage("sidebarExpanded") private var sidebarExpanded = true
    @AppStorage("inspector.shown") private var inspectorShown = true

    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: return "Match System"
            case .light:  return "Light"
            case .dark:   return "Dark"
            }
        }
        var scheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light:  return .light
            case .dark:   return .dark
            }
        }

        /// The same choice, for AppKit.
        ///
        /// `preferredColorScheme` reaches the window it's applied to and no
        /// further — and a popover is presented in a window of its own. With
        /// the app on Dark over a Light system, popover windows kept the
        /// system's light material while their SwiftUI content drew dark text,
        /// which is how session names came out black on a dark menu. Setting it
        /// on `NSApplication` covers every window the app opens, including the
        /// ones SwiftUI makes on our behalf.
        var appKit: NSAppearance? {
            switch self {
            case .system: return nil  // nil means "follow the system".
            case .light:  return NSAppearance(named: .aqua)
            case .dark:   return NSAppearance(named: .darkAqua)
            }
        }

        /// The glyph for the state this *is*, not for what pressing it does.
        ///
        /// The title bar cycles the three from one button, and a button whose
        /// icon described the next state would be a control you have to press
        /// to find out what it currently says. A sun means light.
        var symbol: String {
            switch self {
            case .system: return "circle.lefthalf.filled"
            case .light:  return "sun.max"
            case .dark:   return "moon"
            }
        }

        /// Light → Dark → Match System, and round.
        ///
        /// Three states on one button works because the cycle is short and the
        /// glyph says where you are. A popup menu for three options that are
        /// each one word is a menu you open to press the item next to the one
        /// already selected.
        var next: Appearance {
            switch self {
            case .light:  return .dark
            case .dark:   return .system
            case .system: return .light
            }
        }
    }

    var body: some Scene {
        Window("Honeycode", id: "main") {
            RootView(workspace: workspace, background: background, agents: agents,
                     showPalette: $showPalette, appearance: $appearance)
                .preferredColorScheme(appearance.scheme)
                .environmentObject(background)
                .environmentObject(workspace)
                .onAppear {
                    // Notifications, the quit hook and "is anyone looking at
                    // this" — everything the engine hands back to its host.
                    AppHost.shared.attach(to: workspace)
                    NSApp.appearance = appearance.appKit
                    // `kill -USR1 $(pgrep Honeycode)` writes a PNG of this
                    // window. Costs nothing until the signal arrives.
                    SelfCapture.install()
                    // Starts the clock. Also the catch-up pass — an interval
                    // agent that missed fourteen fires while the app was quit
                    // runs once, not fourteen times.
                    agents.attach(to: workspace)
                }
                .onChange(of: appearance) { _, choice in
                    NSApp.appearance = choice.appKit
                }
        }
        // No titlebar: the sidebar's material runs to the top edge behind the
        // traffic lights, which is what removes the band and the rule across
        // the top of the window.
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1160, height: 760)
        .commands {
            // Under About, where an application's own setup belongs. There is
            // no other route back into the flow — Settings holds every switch
            // it sets, but not the order or the reasons.
            CommandGroup(after: .appInfo) {
                Button("Set Up Honeycode…") {
                    Setup.rerun()
                    workspace.showingSetup = true
                }
            }

            // Declared here because there is no `Settings` scene to declare it
            // for us any more. Same place in the menu, same key, and the same
            // key a second time closes it — which the scene's own item could
            // never do, since a window that is already open has nothing to
            // toggle.
            CommandGroup(replacing: .appSettings) {
                Button(workspace.showingSettings ? "Close Settings" : "Settings…") {
                    withAnimation(Motion.panel) { workspace.showingSettings.toggle() }
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            CommandGroup(after: .toolbar) {
                Button(sidebarExpanded ? "Hide Sidebar" : "Show Sidebar") {
                    withAnimation(Motion.panel) { sidebarExpanded.toggle() }
                }
                .keyboardShortcut(Shortcuts.toggleSidebar.key,
                                  modifiers: Shortcuts.toggleSidebar.modifiers)
                Button(inspectorShown ? "Hide Inspector" : "Show Inspector") {
                    withAnimation(Motion.panel) { inspectorShown.toggle() }
                }
                .keyboardShortcut(Shortcuts.toggleInspector.key,
                                  modifiers: Shortcuts.toggleInspector.modifiers)
                Divider()
                Picker("Appearance", selection: $appearance) {
                    ForEach(Appearance.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                Divider()
                // A toggle rather than a member of the detail picker below.
                // The four detail levels are all the same renderer; this one
                // swaps the renderer, and putting it in that list would say
                // "less detail again" when it means "different machine".
                Button(codingMode ? "Leave Coding Mode" : "Coding Mode") {
                    codingMode.toggle()
                }
                    .keyboardShortcut(Shortcuts.codingMode.key,
                                      modifiers: Shortcuts.codingMode.modifiers)
                Divider()
                ForEach(TranscriptMode.allCases) { option in
                    Button(option.title) { transcriptMode = option }
                        .keyboardShortcut(option.shortcut, modifiers: [.command, .option])
                }
                Divider()
                // In the menu that already holds what the window is showing,
                // rather than in Settings: this is a switch you flip while
                // looking at the thing it changes, not one you open a settings
                // pane to find.
                UsageRailToggle()
                Divider()
            }

            // Nothing in this app is a document, so the stock New/Open/Save
            // group is noise. Replace it with what "new" actually means here.
            CommandGroup(replacing: .newItem) {
                Menu("New Session") {
                    ForEach(Account.enabled) { account in
                        Button(account.title) { newSession(in: account) }
                    }
                }
                Button("New Session…") { newSession(in: currentAccount) }
                    .keyboardShortcut(Shortcuts.newSession.key,
                                      modifiers: Shortcuts.newSession.modifiers)
            }

            CommandMenu("Session") {
                Button("Quick Open…") { showPalette = true }
                    .keyboardShortcut(Shortcuts.quickOpen.key,
                                      modifiers: Shortcuts.quickOpen.modifiers)

                Divider()

                // Still every account you have, and a key only for the ones
                // that have one — an added account belongs in this menu whether
                // or not it can be reached from the keyboard.
                ForEach(Account.enabled) { account in
                    let item = Button(account.title) { workspace.focus(account) }
                    if let key = account.shortcut {
                        item.keyboardShortcut(key, modifiers: .command)
                    } else {
                        item
                    }
                }

                Divider()

                Button("Next Session") { workspace.step(1) }
                    .keyboardShortcut(Shortcuts.nextSession.key,
                                      modifiers: Shortcuts.nextSession.modifiers)
                Button("Previous Session") { workspace.step(-1) }
                    .keyboardShortcut(Shortcuts.previousSession.key,
                                      modifiers: Shortcuts.previousSession.modifiers)

                Divider()

                // One title for both directions, because it's one window and
                // one key: press it on the conversation that's already out
                // there and it comes back.
                Button(workspace.selection != nil
                       && workspace.poppedOut == workspace.selection
                       ? "Bring Back" : "Pop Out") {
                    guard let id = workspace.selection else { return }
                    if workspace.poppedOut == id {
                        workspace.popIn()
                    } else {
                        workspace.popOut(id)
                    }
                }
                .keyboardShortcut(Shortcuts.popOut.key,
                                  modifiers: Shortcuts.popOut.modifiers)
                .disabled(workspace.selected == nil)

                Divider()

                // Offers whatever you last copied, from the focused column, to
                // any other session — with an optional instruction applied on
                // the sending side first. See `Relay`.
                Button("Send Clipboard to Session…") { workspace.clipboardRelayTick += 1 }
                    .keyboardShortcut(Shortcuts.sendTo.key,
                                      modifiers: Shortcuts.sendTo.modifiers)
                    .disabled(workspace.sessions.count < 2)

                Divider()

                // No key equivalent. Esc belongs to the composer — see
                // `Shortcuts.composer`.
                Button("Interrupt") { workspace.selected?.interrupt() }
                    .disabled(workspace.selected?.isRunning != true)

                Button("Rename…") {
                    guard let session = workspace.selected else { return }
                    workspace.renaming = session.id
                }
                .disabled(workspace.selected == nil)

                Button("Reveal in Finder") {
                    guard let session = workspace.selected else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([session.directory])
                }
                .keyboardShortcut(Shortcuts.reveal.key,
                                  modifiers: Shortcuts.reveal.modifiers)

                Divider()

                Button("Delete Session…") {
                    guard let session = workspace.selected else { return }
                    workspace.requestDelete(session)
                }
                .keyboardShortcut(Shortcuts.delete.key,
                                  modifiers: Shortcuts.delete.modifiers)
            }
        }
    }

    /// ⌘N adds to whichever account you're already in, which is nearly always
    /// what you meant. The submenu covers the other two.
    private var currentAccount: Account { workspace.selected?.account ?? .personal }

    private func newSession(in account: Account) {
        workspace.requestNewSession(account)
    }
}
