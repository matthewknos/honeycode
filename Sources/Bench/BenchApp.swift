import SwiftUI

@main
struct BenchApp: App {

    /// Owned here rather than in `RootView` so the menu bar can drive it —
    /// `.commands` sits outside the view hierarchy and can't reach view state.
    @StateObject private var workspace = Workspace()
    @StateObject private var background = BackgroundStore()
    @State private var showPalette = false

    /// Every colour in the app is semantic, so the whole thing follows the
    /// system appearance for free. This override exists only so you can judge
    /// light against dark without going to System Settings and back.
    @AppStorage("appearance") private var appearance = Appearance.system
    @AppStorage("transcript.mode") private var transcriptMode = TranscriptMode.normal

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
    }

    var body: some Scene {
        Window("Honeycode", id: "main") {
            RootView(workspace: workspace, background: background, showPalette: $showPalette)
                .preferredColorScheme(appearance.scheme)
                .environmentObject(background)
                .environmentObject(workspace)
                .onAppear {
                    Notifier.configure()
                    NSApp.appearance = appearance.appKit
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
            CommandGroup(after: .toolbar) {
                Picker("Appearance", selection: $appearance) {
                    ForEach(Appearance.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                Divider()
                ForEach(TranscriptMode.allCases) { option in
                    Button(option.title) { transcriptMode = option }
                        .keyboardShortcut(option.shortcut, modifiers: [.command, .option])
                }
                Divider()
            }

            // Nothing in this app is a document, so the stock New/Open/Save
            // group is noise. Replace it with what "new" actually means here.
            CommandGroup(replacing: .newItem) {
                Menu("New Session") {
                    ForEach(Account.allCases) { account in
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

                ForEach(Account.allCases) { account in
                    Button(account.title) { workspace.focus(account) }
                        .keyboardShortcut(account.shortcut, modifiers: .command)
                }

                Divider()

                Button("Next Session") { workspace.step(1) }
                    .keyboardShortcut(Shortcuts.nextSession.key,
                                      modifiers: Shortcuts.nextSession.modifiers)
                Button("Previous Session") { workspace.step(-1) }
                    .keyboardShortcut(Shortcuts.previousSession.key,
                                      modifiers: Shortcuts.previousSession.modifiers)

                Divider()

                Button("Interrupt") { workspace.selected?.interrupt() }
                    .keyboardShortcut(Shortcuts.interrupt.key,
                                      modifiers: Shortcuts.interrupt.modifiers)
                    .disabled(workspace.selected?.isRunning != true)

                Button("Rename…") { }
                    .disabled(true)

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

        Settings {
            SettingsView(background: background, appearance: $appearance)
                .preferredColorScheme(appearance.scheme)
        }
    }

    /// ⌘N adds to whichever account you're already in, which is nearly always
    /// what you meant. The submenu covers the other two.
    private var currentAccount: Account { workspace.selected?.account ?? .personal }

    private func newSession(in account: Account) {
        guard let url = chooseDirectory(for: account) else { return }
        workspace.add(account: account, directory: url)
    }
}
