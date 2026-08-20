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
    static let reveal = Shortcut("Reveal in Finder", "r", [.command, .shift], "⌘⇧R")
    static let delete = Shortcut("Delete session", .delete, .command, "⌘⌫")

    /// ⌘D for split is the platform's own idiom — Terminal and every terminal
    /// that followed it. ⌘W is left alone: it closes the window, and a key that
    /// closes a pane on one press and the window on the next is a key you stop
    /// trusting.
    static let openBeside = Shortcut("Open session beside", "d", .command, "⌘D")
    static let closeColumn = Shortcut("Close column", "w", [.command, .option], "⌘⌥W")
    static let nextColumn = Shortcut("Focus next column", .rightArrow,
                                     [.command, .option], "⌘⌥→")
    static let previousColumn = Shortcut("Focus previous column", .leftArrow,
                                         [.command, .option], "⌘⌥←")

    /// Coding mode. ⌘⇧T because it's the terminal, and because ⌘T is taken by
    /// the system's own Fonts panel on every Mac ever made.
    static let codingMode = Shortcut("Coding mode", "t", [.command, .shift], "⌘⇧T")

    /// The focused conversation, into the floating window that stays above
    /// other apps — and back again on a second press.
    static let popOut = Shortcut("Pop out the conversation", "p",
                                 [.command, .shift], "⌘⇧P")

    /// Sends whatever you last copied. The transcript's own selection can't be
    /// read — SwiftUI exposes no hook into it — so copying is the step that
    /// turns a selection into something this can act on. See `Relay`.
    static let sendTo = Shortcut("Send the clipboard to another session", "s",
                                 [.command, .shift], "⌘⇧S")

    /// Documentation only — these live in the composer's event monitor.
    ///
    /// Interrupt is among them rather than in the menu list below. As a menu key
    /// equivalent, bare Esc was matched anywhere in the window and ahead of the
    /// focused view, so dismissing a palette or a rename box while a turn ran
    /// stopped the turn instead. It belongs to the composer, which knows whether
    /// Esc means "close this list", "stop that", or nothing at all.
    static let composer: [(String, String)] = [
        ("Send the message", "Return"),
        ("New line without sending", "⇧Return"),
        ("Stop the current turn", "Esc"),
        ("Mention a file", "@"),
        ("Run a slash command", "/"),
        ("Move through suggestions", "↑ ↓"),
        ("Insert the highlighted suggestion", "Return or Tab"),
        ("Dismiss suggestions", "Esc"),
        ("Attach from the clipboard", "⌘V"),
        ("Attach by dropping files", "Drag onto the composer"),
    ]

    static let sessions: [Shortcut] = [
        newSession, quickOpen, nextSession, previousSession, reveal, delete,
    ]

    static let columns: [Shortcut] = [
        openBeside, closeColumn, nextColumn, previousColumn, popOut, sendTo,
    ]

    static let view: [Shortcut] = [codingMode]
}

// MARK: - Key equivalents for engine types
//
// `KeyEquivalent` is SwiftUI, and `Account` and `TranscriptMode` are engine
// types that `honeycoded` also decodes — so which key selects one is a fact
// about this app, not about the type, and it belongs on this side of the line.

extension Account {
    /// ⌘1 / ⌘2 / ⌘3 / ⌘4, and nothing for the rest.
    ///
    /// The four that ship get the four keys. An added account gets none rather
    /// than ⌘5 upwards: the number would depend on the order things were added,
    /// so the same key would mean different accounts on two machines and a
    /// different account on this one after a rename. A shortcut you cannot
    /// predict is worse than no shortcut.
    var shortcut: KeyEquivalent? {
        switch self {
        case .personal: return "1"
        case .work:     return "2"
        case .kimi:     return "3"
        case .copilot:  return "4"
        case .custom:   return nil
        }
    }
}

extension TranscriptMode {
    /// ⌥⌘1…4
    var shortcut: KeyEquivalent {
        switch self {
        case .summary:  return "1"
        case .normal:   return "2"
        case .thinking: return "3"
        case .verbose:  return "4"
        }
    }
}
