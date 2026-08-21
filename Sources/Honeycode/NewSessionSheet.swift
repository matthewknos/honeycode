import SwiftUI
import AppKit

/// Starting a conversation, once.
///
/// There were six ways into a new session and every one of them did the same
/// thing: open an `NSOpenPanel` and hand back a directory. Six doors into one
/// room would have been fine. What they actually were was six copies of a flow
/// with no memory — a file chooser is the right control for a folder you have
/// never opened and the wrong one for the repository you were in twenty minutes
/// ago, and it was being used for both because it was the only one there was.
///
/// So the doors all lead here now, and here remembers. Recent folders first,
/// the account picker beside them so you can change your mind about which
/// subscription without going back out, and the file panel still one click away
/// for the case it was always right for.
///
/// It also says which accounts can actually run. An account whose CLI is not
/// installed used to be a perfectly ordinary-looking choice that produced a
/// spawn error after you had chosen a folder and typed a message.
struct NewSessionSheet: View {
    @ObservedObject var workspace: Workspace
    let initial: Account

    @State private var account: Account
    @State private var recents: [URL] = []
    @State private var readiness: [AccountReadiness] = []
    @State private var highlighted: URL?

    init(workspace: Workspace, initial: Account) {
        self.workspace = workspace
        self.initial = initial
        _account = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.rule)
            accounts
            Divider().overlay(Theme.rule)
            list
            Divider().overlay(Theme.rule)
            footer
        }
        .frame(width: 520, height: 460)
        .task {
            recents = RecentProjects.all
            highlighted = recents.first
            readiness = await Task.detached(priority: .utility) {
                Diagnostic.readiness()
            }.value
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.s1) {
            Text("New session")
                .font(.system(size: 15, weight: .semibold))
            Text("A conversation with one agent, about one folder.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Theme.s6)
        .padding(.vertical, Theme.s5)
    }

    // MARK: Which subscription

    /// The four accounts as rows rather than a segmented control, because a
    /// segment cannot say "not installed" and this needs to.
    private var accounts: some View {
        HStack(spacing: Theme.s3) {
            ForEach(Account.allCases) { candidate in
                accountChip(candidate)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.s6)
        .padding(.vertical, Theme.s4)
    }

    private func accountChip(_ candidate: Account) -> some View {
        let state = readiness.first { $0.account == candidate }
        let usable = state?.isReady ?? true
        let on = account == candidate
        return Button { account = candidate } label: {
            HStack(spacing: Theme.s3 - Theme.s1) {
                Circle()
                    .fill(candidate.accent)
                    .opacity(usable ? 1 : 0.3)
                    .frame(width: 6, height: 6)
                Text(candidate.shortTitle)
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(on ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, Theme.s4)
            .padding(.vertical, Theme.s3)
            .background(on ? Theme.well : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // Still selectable when the CLI is missing. Refusing would be the app
        // deciding you cannot open a conversation on a subscription you pay
        // for because a `stat` failed; saying so and letting you through is the
        // honest version, and the footer repeats it where the decision is made.
        .help(state?.remedy ?? "\(candidate.title) — ready")
    }

    // MARK: Which folder

    @ViewBuilder
    private var list: some View {
        if recents.isEmpty {
            VStack(spacing: Theme.s4) {
                Image(systemName: "folder")
                    .font(.system(size: 20))
                    .foregroundStyle(.quaternary)
                Text("No recent folders")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Choose one below. It will be here next time.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(recents, id: \.self) { url in
                        row(url)
                    }
                }
                .padding(.vertical, Theme.s3)
            }
        }
    }

    private func row(_ url: URL) -> some View {
        let on = highlighted == url
        return Button {
            highlighted = url
        } label: {
            HStack(spacing: Theme.s4) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(url.lastPathComponent)
                        .font(.system(size: 12.5))
                    Text(Self.shorten(url))
                        .font(Theme.monoSmall)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: Theme.s4)
                if on {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, Theme.s6)
            .padding(.vertical, Theme.s3 + 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRow())
        // Double-click opens, which is what a list of folders implies.
        .simultaneousGesture(TapGesture(count: 2).onEnded { open(url) })
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            Divider()
            Button("Remove from this list") {
                RecentProjects.forget(url)
                recents = RecentProjects.all
                if highlighted == url { highlighted = recents.first }
            }
        }
    }

    /// `~/Workspace/Personal/honeycode`. Home is the one prefix everybody's
    /// path has and nobody needs to read.
    private static func shorten(_ url: URL) -> String {
        let path = url.path
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: Doing it

    private var footer: some View {
        HStack(spacing: Theme.s4) {
            Button("Browse…") { browse() }

            if let state = readiness.first(where: { $0.account == account }),
               !state.isReady {
                Text("\(account.shortTitle) is \(state.summary)")
                    .font(Theme.label)
                    .foregroundStyle(Theme.stateHeld)
                    .help(state.remedy ?? "")
            }

            Spacer(minLength: Theme.s4)

            Button("Cancel") { workspace.newSessionRequest = nil }
                .keyboardShortcut(.cancelAction)
            Button("Open") { if let highlighted { open(highlighted) } }
                .keyboardShortcut(.defaultAction)
                .disabled(highlighted == nil)
        }
        .padding(.horizontal, Theme.s6)
        .padding(.vertical, Theme.s5)
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Session"
        panel.message = "Choose a working directory for this \(account.title) session."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    private func open(_ url: URL) {
        workspace.newSessionRequest = nil
        workspace.add(account: account, directory: url)
    }
}

/// `Account` as a sheet subject.
///
/// `.sheet(item:)` needs `Identifiable`, and `Account` is an engine type that
/// already has an `id` meaning something else — the string a custom account is
/// keyed by. Wrapping is cheaper than conflating the two.
struct NewSessionRequest: Identifiable {
    let account: Account
    var id: String { account.id }

    init(_ account: Account) { self.account = account }
}
