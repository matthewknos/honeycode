import SwiftUI
import AppKit

/// Who you are acting as, at the foot of the sidebar.
///
/// This is the GitHub and Azure switching that used to live inside the status
/// rail's *View* popover, and it was in the wrong place for three separate
/// reasons. An identity is not a view. It is an application-wide fact, and that
/// menu belonged to one column — so with three conversations open there were
/// three controls all claiming to answer a question that has one answer. And
/// it was invisible until opened: the tooltip could only name the active
/// accounts *after* something had read them, which nothing did until you
/// clicked, so the answer to "which tenant am I about to deploy to" required
/// having already asked.
///
/// At the foot of the sidebar it is always on screen, always singular, and in
/// the corner every application on this platform reserves for it. The active
/// logins are read once when the window appears and again whenever the app
/// comes forward — `gh auth switch` and `az login` happen in terminals, so a
/// tick that is only refreshed on open is a tick that is confidently wrong.
struct IdentityMenu: View {
    /// Collapsed to a single glyph in the rail.
    var compact = false

    @State private var showing = false
    @State private var gitHub: [GitHubAccount] = []
    @State private var gitHubLoaded = false
    @State private var gitHubFailure: String?
    @State private var azure: [AzureAccount] = []
    @State private var azureLoaded = false
    @State private var azureFailure: String?

    private var activeGitHub: GitHubAccount? { gitHub.first(where: \.isActive) }
    private var activeAzure: AzureAccount? { azure.first(where: \.isActive) }

    var body: some View {
        Button { showing.toggle() } label: { label }
            .buttonStyle(SidebarFooterButton())
            .help(help)
            .popover(isPresented: $showing, arrowEdge: .trailing) { menu }
            // Read up front rather than on first open. The whole complaint
            // about the old control was that it could not tell you anything
            // until you had already opened it.
            .task { await reload() }
            .onReceive(NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await reload() }
            }
    }

    /// The two logins, named. Not a generic "Accounts" — the point of putting
    /// this on screen permanently is that it *says the answer*.
    @ViewBuilder
    private var label: some View {
        HStack(spacing: Theme.s3) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .frame(width: 12, alignment: .center)

            if !compact {
                VStack(alignment: .leading, spacing: 0) {
                    Text(activeGitHub?.login ?? (GitHubAuth.isInstalled
                                                 ? "Not signed in" : "gh not installed"))
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let azure = activeAzure {
                        Text(azure.user)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.quaternary)
            }
        }
        .padding(.horizontal, compact ? 0 : Theme.s4)
        .padding(.vertical, Theme.s3)
        .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
        .contentShape(Rectangle())
    }

    private var help: String {
        var lines: [String] = []
        lines.append("GitHub: " + (activeGitHub?.login ?? "not signed in"))
        lines.append("Azure: " + (activeAzure?.user ?? "not signed in"))
        return lines.joined(separator: "\n")
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 0) {
            PopoverHeader("GitHub account")
            gitHubRows

            Divider().overlay(Theme.rule).padding(.vertical, Theme.s2)
            PopoverHeader("Azure account")
            azureRows
        }
        .padding(.vertical, Theme.s3)
        .frame(width: 272)
        .task { await reload() }
    }

    // MARK: GitHub

    /// Which GitHub identity a push from this app will use, and the switch.
    @ViewBuilder private var gitHubRows: some View {
        if !GitHubAuth.isInstalled {
            PopoverRow(title: "`gh` isn't installed", blurb: "brew install gh") {}
                .disabled(true)
                .opacity(0.5)
        } else if !gitHubLoaded {
            PopoverRow(title: "Checking…", blurb: nil) {}
                .disabled(true)
                .opacity(0.5)
        } else {
            ForEach(gitHub) { account in
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
                note(gitHubFailure)
            }
            // The way you get a second account, said where you go looking for
            // one. Signing in is `gh`'s job and needs a terminal, so this is a
            // door to it rather than a form.
            PopoverRow(title: gitHub.isEmpty ? "Sign in to GitHub…" : "Add an account…",
                       blurb: "Runs `gh auth login` in a terminal") {
                showing = false
                if let script = GitHubAuth.loginScript() { NSWorkspace.shared.open(script) }
            }
        }
    }

    /// The host when it isn't github.com, and the state when it isn't fine.
    private func blurb(for account: GitHubAccount) -> String? {
        var parts: [String] = []
        if let host = account.hostNote { parts.append(host) }
        if !account.isValid { parts.append("token expired — gh auth login") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Azure

    /// Which Azure identity `az` is acting as. With two tenants in play this is
    /// the difference between deploying to the right estate and the wrong one,
    /// and it is not inferable from a resource-group name.
    @ViewBuilder private var azureRows: some View {
        if !AzureAuth.isInstalled {
            PopoverRow(title: "`az` isn't installed", blurb: "brew install azure-cli") {}
                .disabled(true)
                .opacity(0.5)
        } else if !azureLoaded {
            PopoverRow(title: "Checking…", blurb: nil) {}
                .disabled(true)
                .opacity(0.5)
        } else {
            ForEach(azure) { account in
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
                note(azureFailure)
            }
            PopoverRow(title: azure.isEmpty ? "Sign in to Azure…" : "Add an account…",
                       blurb: "Runs `az login` in a terminal") {
                showing = false
                if let script = AzureAuth.loginScript() { NSWorkspace.shared.open(script) }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, Theme.s5)
            .padding(.top, Theme.s2)
    }

    // MARK: Reading and switching

    private func reload() async {
        await loadGitHub()
        await loadAzure()
    }

    private func loadGitHub() async {
        gitHub = await Task.detached(priority: .userInitiated) { GitHubAuth.accounts() }.value
        gitHubLoaded = true
    }

    private func loadAzure() async {
        azure = await Task.detached(priority: .userInitiated) { AzureAuth.accounts() }.value
        azureLoaded = true
    }

    private func select(_ account: GitHubAccount) async {
        await switchAccount(perform: { try GitHubAuth.select(account) },
                            reload: loadGitHub) { gitHubFailure = $0 }
    }

    private func select(_ account: AzureAccount) async {
        await switchAccount(perform: { try AzureAuth.select(account) },
                            reload: loadAzure) { azureFailure = $0 }
    }

    /// Switch, then re-read rather than assume. The CLI is the record here, not
    /// this list — reading it back is what keeps the tick honest if the switch
    /// half-worked.
    private func switchAccount(perform: @escaping @Sendable () throws -> Void,
                               reload: () async -> Void,
                               failure: (String?) -> Void) async {
        failure(nil)
        do {
            try await Task.detached(priority: .userInitiated) { try perform() }.value
            await reload()
            showing = false
        } catch {
            failure((error as? CommandFailure)?.detail ?? error.localizedDescription)
            await reload()
        }
    }
}
