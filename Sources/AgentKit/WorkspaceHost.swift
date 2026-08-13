import Foundation

/// What a `Workspace` needs from whatever is showing it.
///
/// The engine drives agents, owns transcripts and decides when a turn is worth
/// announcing. What it must not know is *who is watching* — that answer is
/// completely different for the two things that host it. Honeycode.app knows
/// because it can ask `NSApp`; `honeycoded` knows because it counts attached
/// clients, and with none attached the honest answer is nobody.
///
/// So the two questions that used to be answered by reaching for AppKit from
/// inside `Models.swift` are asked through here instead. Both have a safe
/// headless default: a nil host means nothing is in the foreground and nothing
/// gets announced, which leaves the unread mark as the only signal — exactly
/// what a daemon with no UI should do.
protocol WorkspaceHost: AnyObject {

    /// Whether the person is looking at this workspace at all.
    ///
    /// Only ever narrows a notification decision — `Workspace` still checks
    /// that the finished session is one of the visible columns. Being frontmost
    /// is not the same as watching *that* conversation, and the pair of
    /// conditions is what stops a reply landing in a column you can see from
    /// posting a banner about it.
    var isForeground: Bool { get }

    /// A turn finished in a session nobody is watching.
    ///
    /// Delivery is entirely the host's business: a banner, a terminal bell, a
    /// line on a status bar, or nothing at all.
    func announce(sessionID: UUID, title: String, body: String)
}
