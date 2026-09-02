import AppKit

/// Honeycode.app's answer to `WorkspaceHost`.
///
/// Three things the engine deliberately can't do for itself, all of them the
/// same shape: they need to know about a *person*, and the engine only knows
/// about sessions.
///
/// The quit hook is the one worth pausing on. It used to live inside
/// `Workspace.init` as an observer on `NSApplication.willTerminateNotification`
/// — which worked, and which also meant the engine could only ever run inside
/// an AppKit application. `Workspace.flush()` is the same code with the
/// question of *when* handed back to whoever owns the process, so the daemon
/// can call it from a `SIGTERM` handler and get identical behaviour.
@MainActor
final class AppHost: WorkspaceHost {

    static let shared = AppHost()
    private init() {}

    private weak var workspace: Workspace?

    /// `NSApp.isActive` — is Honeycode the app you're actually looking at.
    nonisolated var isForeground: Bool {
        MainActor.assumeIsolated { NSApp.isActive }
    }

    nonisolated func announce(sessionID: UUID, title: String, body: String) {
        guard Features.isOn(.notifications) else { return }
        Notifier.post(sessionID: sessionID, title: title, body: body)
    }

    /// Wire a workspace to this process's lifecycle. Called once, at launch.
    func attach(to workspace: Workspace) {
        self.workspace = workspace
        workspace.host = self
        // Only where they have been asked for. `configure` is what raises the
        // system's permission dialog, and raising it four seconds into a first
        // launch — before there is anything to be notified about — is how an
        // app gets denied by reflex. Setup asks instead, and switching the
        // feature on there calls this.
        if Features.isOn(.notifications) { Notifier.configure() }

        // The transcript's markdown parser, lent to `Relay` so it can tell a
        // reply that *is* a document from one that merely quotes some markup.
        Relay.renderableBlocks = { reply in
            MarkdownText.blocks(reply).compactMap { block in
                guard case .code(let source, let language) = block,
                      CodeBlock.isRenderable(language) else { return nil }
                return source
            }
        }

        // Both blocks reach the workspace through `AppHost.shared` rather than
        // capturing it. An observer block is `@Sendable`, `Workspace` is not,
        // and a `[weak workspace]` capture list smuggles one across that line —
        // which Swift 6 rejects. `shared` is a constant, the stored property is
        // already `weak`, and both bodies were main-actor-only to begin with,
        // so the reference costs nothing and the lifetime is unchanged.

        // The last turn of a session is the one most likely to be lost, so
        // catch the quit rather than relying on each turn's own save.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { AppHost.shared.workspace?.flush() }
        }

        // Clicking a notification jumps to the session that finished.
        NotificationCenter.default.addObserver(
            forName: Notifier.activated, object: nil, queue: .main
        ) { note in
            guard let id = note.userInfo?[Notifier.sessionKey] as? UUID else { return }
            MainActor.assumeIsolated { AppHost.shared.workspace?.selection = id }
        }
    }
}
