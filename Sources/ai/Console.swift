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
        case .custom:
            switch account.custom?.tint {
            case .teal:   return "37"
            case .pink:   return "205"
            case .indigo: return "63"
            case .brown:  return "137"
            case .red:    return "203"
            case .yellow: return "179"
            case nil:     return "245" // grey: a definition that has gone
            }
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

    /// The cursor is at the start of a line, and this didn't put it there.
    ///
    /// `LineEditor` writes through `Terminal` rather than through here, because
    /// what it writes is mostly cursor movement and counting that as text is
    /// how you get a stray blank line above every prompt. It still ends each
    /// line properly, and this is how it says so.
    static func markFresh() { midLine = false }

    // MARK: Room

    /// How wide to lay things out.
    ///
    /// Everything that truncates asks this rather than carrying a number.
    /// Three places used to carry their own — 90, 110 and 28 — which on a wide
    /// window threw away most of what would have fitted and on a narrow one
    /// wrapped every line of a plan into two.
    static var width: Int { Terminal.columns }

    /// Cut to fit, with an ellipsis when there was more.
    ///
    /// Counts characters, so an escape sequence inside `text` would be counted
    /// as the dozen characters it is. Nothing here passes one: this is for the
    /// plain strings — a task, a message, a path — that go *into* a painted
    /// line rather than for the line itself.
    static func fit(_ text: String, to room: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard room > 1, flat.count > room else { return flat }
        return String(flat.prefix(room - 1)) + "…"
    }

    /// `▸ claude-p`, `▸ kimi#2` — who is about to speak.
    ///
    /// Tinted by account, named by seat: two instances of one subscription are
    /// the same colour on purpose, because that is the fact worth seeing at a
    /// glance — what they cost comes out of the same place.
    static func speaker(_ seat: Seat, note: String? = nil) {
        breakLine()
        let name = paint("▸ " + seat.handle, tint(seat.account), bold: true)
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
    /// - Parameter opening: true only for the first batch of a turn.
    ///
    /// This used to break the line on every batch, which shredded the thing it
    /// was printing. A streamed reply arrives in chunks that stop wherever the
    /// network did, so a chunk usually ends mid-word and leaves `midLine` set —
    /// and the next batch, eighty milliseconds later, opened with a newline
    /// through the middle of that word. Measured on a 250-word reply: thirty
    /// mid-word breaks across forty-one lines, in a terminal and in a pipe
    /// alike. It matters most in a pipe, because `ai -p` exists to be read by
    /// another program.
    ///
    /// The break was only ever there to get off the prompt — `Scrollback` owns
    /// every newline after that, which the comment above already said and the
    /// code did not do.
    static func emit(_ runs: [ScrollbackRun], accent: String, opening: Bool) {
        guard !runs.isEmpty else { return }
        if opening { breakLine() }
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
