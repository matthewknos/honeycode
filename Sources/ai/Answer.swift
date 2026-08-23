import Foundation

/// A slash command's answer, tied to the command that asked for it.
///
/// `└` on the first line, and everything after it hanging under that line's
/// text rather than under the connector. Two characters, and they earn their
/// place: without them a command's answer is indented text under a prompt,
/// which is also what a plan is, and what a delegate's message is, and what a
/// status line is. With them the answer points back at the question.
///
/// Stateful because "first line" is the whole of the rule, and the callers that
/// need it are loops — `/accounts` prints a row per account, `/models` prints a
/// row per model, and neither of them knows on any given pass whether it is the
/// first one.
@MainActor
final class Answer {

    private let indent: String
    private let connector: Bool
    private var opened = false

    /// - Parameter connector: off for a block nobody asked for. The roster
    ///   printed when `ai` opens and finds nothing installed is the same rows
    ///   in the same columns, but it is not an answer to anything and pointing
    ///   it at the line above would be pointing it at the banner.
    init(indent: String = "  ", connector: Bool = true) {
        self.indent = indent
        self.connector = connector
    }

    /// A blank line stays blank — a connector on nothing would be a connector
    /// to nothing, and it must not count as having opened the block either.
    func line(_ text: String = "") {
        guard !text.isEmpty else { return Console.line() }
        guard connector else { return Console.line(indent + text) }
        Console.line(indent + (opened ? "  " : Console.dim("└") + " ") + text)
        opened = true
    }
}
