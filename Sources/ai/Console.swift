import Foundation

/// Everything this program puts on screen.
///
/// Line-based and streaming rather than a full-screen TUI, which is a decision
/// and not a shortcut. A crew run is a *transcript* — a plan, some work, an
/// answer — and a transcript wants to scroll, be selected, be piped into a
/// file, and still be there tomorrow. Taking over the alternate screen buffer
/// would trade all of that for a layout nobody asked for.
enum Console {

    // MARK: Colour

    private static var colour: Bool {
        isatty(fileno(stdout)) == 1 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
    }

    /// 256-colour codes chosen to match the app's account accents, so the two
    /// faces of the same account look like the same account.
    static func tint(_ account: Account) -> String {
        switch account {
        case .personal: return "208"   // orange
        case .work:     return "33"    // blue
        case .kimi:     return "141"   // purple
        case .copilot:  return "35"    // green
        }
    }

    static func paint(_ text: String, _ code: String, bold: Bool = false) -> String {
        guard colour else { return text }
        return "\u{1B}[\(bold ? "1;" : "")38;5;\(code)m\(text)\u{1B}[0m"
    }

    static func dim(_ text: String) -> String {
        colour ? "\u{1B}[2m\(text)\u{1B}[0m" : text
    }

    // MARK: Writing

    /// Whether the cursor is mid-line. Everything that wants to start on a
    /// fresh line goes through `breakLine()` rather than guessing, because
    /// streamed text ends wherever the model stopped.
    private static var midLine = false

    static func write(_ text: String) {
        guard !text.isEmpty else { return }
        FileHandle.standardOutput.write(Data(text.utf8))
        midLine = !text.hasSuffix("\n")
    }

    static func line(_ text: String = "") {
        write(text + "\n")
    }

    static func breakLine() {
        if midLine { write("\n") }
    }

    /// `▸ claude-p` — who is about to speak.
    static func speaker(_ account: Account, note: String? = nil) {
        breakLine()
        let name = paint("▸ " + AgentMention.handle(account), tint(account), bold: true)
        line("\n" + name + (note.map { " " + dim($0) } ?? ""))
    }

    static func status(_ text: String) {
        breakLine()
        line(dim("  " + text))
    }

    static func failure(_ text: String) {
        breakLine()
        line(paint("  ! " + text, "203"))
    }

    // MARK: Scrollback

    /// Write a drained scrollback, in this account's colours.
    ///
    /// `breakLine` first because the prompt leaves the cursor after `> ` — the
    /// same join the old per-call `Console.status`/`speaker` pair used to do,
    /// now done once for the batch. `Scrollback` owns every newline after that.
    static func emit(_ runs: [ScrollbackRun], accent: String) {
        guard !runs.isEmpty else { return }
        breakLine()
        for run in runs { write(paint(run.text, style: run.style, accent: accent)) }
    }

    /// One place where a scrollback style becomes an escape code.
    ///
    /// The mapping is short on purpose. A terminal has four colours worth
    /// spending — who is talking, what changed, what broke, and everything
    /// quiet — and a palette with a shade per concept reads as decoration.
    static func paint(_ text: String, style: ScrollbackStyle, accent: String) -> String {
        switch style {
        case .prose:                 return text
        case .speaker:               return paint(text, accent, bold: true)
        case .prompt:                return paint(text, "244", bold: true)
        case .activity, .detail,
             .notice:                return dim(text)
        case .added:                 return paint(text, "71")
        case .removed:               return paint(text, "167")
        case .failure:               return paint(text, "203")
        }
    }
}
