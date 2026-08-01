import SwiftUI

/// Every keyboard shortcut, in one place.
///
/// The menu bar reads its key equivalents from this list rather than declaring
/// its own, so a shortcut can't say one thing in Settings and do another. The
/// composer's keys can't be declared here — they're handled by a local event
/// monitor, not by SwiftUI — so those are marked as documentation only and
/// listed separately.
struct Shortcut: Identifiable {
    let title: String
    let key: KeyEquivalent
    let modifiers: EventModifiers
    /// Written out for the Settings list: ⌘⌥↓ and so on.
    let display: String

    var id: String { title + display }

    init(_ title: String, _ key: KeyEquivalent, _ modifiers: EventModifiers, _ display: String) {
        self.title = title
        self.key = key
        self.modifiers = modifiers
        self.display = display
    }
}

enum Shortcuts {
    static let newSession = Shortcut("New session", "n", .command, "⌘N")
    static let quickOpen = Shortcut("Quick open and search", "k", .command, "⌘K")
    static let nextSession = Shortcut("Next session", .downArrow, [.command, .option], "⌘⌥↓")
    static let previousSession = Shortcut("Previous session", .upArrow, [.command, .option], "⌘⌥↑")
    static let interrupt = Shortcut("Stop the current turn", .escape, [], "Esc")
    static let reveal = Shortcut("Reveal in Finder", "r", [.command, .shift], "⌘⇧R")
    static let delete = Shortcut("Delete session", .delete, .command, "⌘⌫")

    /// Documentation only — these live in the composer's event monitor.
    static let composer: [(String, String)] = [
        ("Send the message", "Return"),
        ("New line without sending", "⇧Return"),
        ("Mention a file", "@"),
        ("Run a slash command", "/"),
        ("Move through suggestions", "↑ ↓"),
        ("Insert the highlighted suggestion", "Return or Tab"),
        ("Dismiss suggestions", "Esc"),
        ("Attach from the clipboard", "⌘V"),
        ("Attach by dropping files", "Drag onto the composer"),
    ]

    static let sessions: [Shortcut] = [
        newSession, quickOpen, nextSession, previousSession, reveal, delete, interrupt,
    ]
}
