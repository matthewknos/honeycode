import Foundation

/// `ai`'s answer to `WorkspaceHost`.
///
/// Both questions have flatter answers here than in the app. The terminal is
/// always "the thing you're looking at" as far as this process can tell — it
/// has no way to know the window is behind a browser, and guessing wrong in the
/// quiet direction is better than beeping at someone who is watching the output
/// scroll past. And a turn finishing is already visible, because the reply is
/// printed as it arrives, so `announce` only rings the bell.
final class CLIHost: WorkspaceHost {
    static let shared = CLIHost()
    private init() {}

    var isForeground: Bool { true }

    func announce(sessionID: UUID, title: String, body: String) {
        // BEL, and only when output isn't being piped somewhere.
        guard isatty(fileno(stdout)) == 1 else { return }
        FileHandle.standardError.write(Data([0x07]))
    }
}
