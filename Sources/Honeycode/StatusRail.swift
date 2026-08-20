import SwiftUI
import AppKit

/// The rail down the side of a session: account, model, spend, project.
///
/// Lifted out of `RootView` unchanged, for the reason `Sidebar.swift` was. At
/// three hundred and sixty lines with its own compact mode, its own copy
/// behaviour and its own summary text, it was the largest thing in that file
/// that had nothing to do with the root view.
struct StatusRail: View {
    @ObservedObject var session: Session
    /// Icons only, stacked to fit the 60pt gutter.
    var compact = false

    @EnvironmentObject private var background: BackgroundStore
    /// Only for the pop-out row below, which is a question about where this
    /// conversation lives rather than about the session itself.
    @EnvironmentObject private var workspace: Workspace
    @AppStorage("transcript.mode") private var mode = TranscriptMode.normal
    @AppStorage("transcript.terminal") private var terminal = false
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
                PopoverHeader("Presentation")
                PopoverRow(title: "Coding mode",
                           blurb: "A terminal instead of cards. \(Shortcuts.codingMode.display)",
                           selected: terminal) {
                    terminal.toggle()
                    showingViewMenu = false
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
