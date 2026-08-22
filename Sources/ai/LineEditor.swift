import Foundation

/// The prompt you type into.
///
/// This exists because `readLine` was what was here before, and `readLine` is
/// the line discipline the kernel gives you for free: no history, no arrow
/// keys, no completion, and a left arrow that types `^[[D` into your message.
/// For a program whose entire grammar is `@handles` and `:qualifiers` — names
/// you have to spell exactly or address nobody — not being able to complete
/// them, or to get back the thing you typed a minute ago, is most of the
/// distance between this and the agent CLIs it sits alongside.
///
/// Runs on the input queue, blocking on `read` the whole time, which is the
/// same shape `readLine` had. Nothing draws over it: the prompt only exists
/// when the crew is idle, so the editor owns the bottom of the screen for as
/// long as it is up.
final class LineEditor {

    enum Outcome {
        case line(String)
        /// ctrl-c on an empty line. On a line with something on it, ctrl-c
        /// clears the line and never gets this far.
        case interrupted
        /// ctrl-d on an empty line, or the input ending.
        case endOfInput
    }

    private let history = History()
    private let directory: URL

    private var buffer: [Character] = []
    /// Where the caret is, in characters, from 0 to `buffer.count`.
    private var cursor = 0
    /// The first character drawn. Non-zero only once the line is wider than the
    /// window, which is how a long line scrolls sideways instead of wrapping
    /// into rows this would then have to keep track of.
    private var offset = 0

    private var prompt = ""
    private var promptWidth = 0

    init(directory: URL) {
        self.directory = directory
    }

    // MARK: - The loop

    func read(prompt: String, width: Int) -> Outcome {
        self.prompt = prompt
        self.promptWidth = width
        buffer = []
        cursor = 0
        offset = 0
        history.rewind()

        // A pipe, a redirect, or a terminal that wouldn't go raw. Reading a
        // line is still reading a line — `echo "…" | ai` has to keep working,
        // and it is worth more than any of the editing below.
        guard Terminal.enterRaw() else {
            Console.write(prompt)
            guard let line = readLine(strippingNewline: true) else { return .endOfInput }
            // Nothing is written to history here. A pipe's contents are not
            // things somebody typed, and arrowing back through them next time
            // would be a record of a script rather than of a person.
            return .line(line)
        }
        defer { Terminal.leaveRaw() }

        Terminal.measure()
        // Bracketed paste, so a pasted block arrives as one thing this can
        // fold onto one line rather than as N lines each of which looks like
        // somebody pressing return.
        Terminal.emit("\u{1B}[?2004h")
        defer { Terminal.emit("\u{1B}[?2004l") }

        draw()
        while let byte = Terminal.readByte() {
            switch byte {
            case 0x0D, 0x0A:
                return submit()
            case 0x03:
                guard buffer.isEmpty else {
                    buffer = []; cursor = 0; offset = 0; draw(); break
                }
                Terminal.emit("\n")
                Console.markFresh()
                return .interrupted
            case 0x04:
                guard buffer.isEmpty else { deleteForward(); break }
                Terminal.emit("\n")
                Console.markFresh()
                return .endOfInput
            case 0x09:
                complete()
            case 0x7F, 0x08:
                guard cursor > 0 else { break }
                cursor -= 1
                buffer.remove(at: cursor)
                draw()
            case 0x01: cursor = 0; draw()
            case 0x05: cursor = buffer.count; draw()
            case 0x02: if cursor > 0 { cursor -= 1; draw() }
            case 0x06: if cursor < buffer.count { cursor += 1; draw() }
            case 0x0B: buffer.removeSubrange(cursor..<buffer.count); draw()
            case 0x15: buffer.removeSubrange(0..<cursor); cursor = 0; draw()
            case 0x17: deleteWordBack()
            case 0x0C: Terminal.emit("\u{1B}[2J\u{1B}[H"); draw()
            case 0x1B: escape()
            default:
                // Anything else below space is a control key nothing here binds.
                // Swallowing it is the point: it would otherwise be inserted as
                // an invisible character that makes a mention stop matching.
                guard byte >= 0x20 else { break }
                insert(character(startingWith: byte))
            }
        }
        Terminal.emit("\n")
        Console.markFresh()
        return .endOfInput
    }

    private func submit() -> Outcome {
        let text = String(buffer)
        // Redrawn in full rather than left as the scrolled window: this line
        // stops being an editor and becomes a line of the transcript, and a
        // transcript that says `…ge for a dentist @kimi` is a worse record than
        // one that wraps.
        Terminal.emit("\r\u{1B}[K" + prompt + text + "\n")
        Console.markFresh()
        history.add(text)
        return .line(text)
    }

    // MARK: - Keys that arrive as several bytes

    /// Everything that starts with Escape: the arrows, Home and End in their
    /// several spellings, ctrl- and alt-arrow for word motion, and paste.
    private func escape() {
        // Escape on its own — nothing follows it. Left alone deliberately:
        // there is no mode to leave, and guessing would make a stray keypress
        // do something.
        guard Terminal.isPending(within: 40), let next = Terminal.readByte() else { return }

        guard next == UInt8(ascii: "[") || next == UInt8(ascii: "O") else {
            // Meta-b and Meta-f, which is how alt-arrow reaches a terminal that
            // sends Meta rather than a CSI sequence.
            switch next {
            case UInt8(ascii: "b"): moveWordLeft(); draw()
            case UInt8(ascii: "f"): moveWordRight(); draw()
            case 0x7F: deleteWordBack()
            default: break
            }
            return
        }

        var sequence = String(UnicodeScalar(next))
        while sequence.count < 16, let byte = Terminal.readByte() {
            sequence.append(Character(UnicodeScalar(byte)))
            // A CSI sequence ends at the first byte in this range; everything
            // before it is parameters.
            if byte >= 0x40, byte <= 0x7E { break }
        }

        switch sequence {
        case "[A", "OA":
            if let entry = history.previous(from: String(buffer)) { replaceLine(with: entry) }
        case "[B", "OB":
            if let entry = history.next() { replaceLine(with: entry) }
        case "[C", "OC": if cursor < buffer.count { cursor += 1; draw() }
        case "[D", "OD": if cursor > 0 { cursor -= 1; draw() }
        case "[H", "OH", "[1~", "[7~": cursor = 0; draw()
        case "[F", "OF", "[4~", "[8~": cursor = buffer.count; draw()
        case "[3~": deleteForward()
        // ctrl- and alt- arrows. Terminals disagree about the modifier number
        // and agree about nothing else, so both of the common ones are listed.
        case "[1;5C", "[1;3C": moveWordRight(); draw()
        case "[1;5D", "[1;3D": moveWordLeft(); draw()
        case "[200~": paste()
        default: break
        }
    }

    /// Everything between the paste markers, as one insertion.
    ///
    /// Newlines become spaces. This editor is one line by construction, and the
    /// alternative — submitting a pasted paragraph as one message per line —
    /// is what happens without bracketed paste and is the thing worth avoiding:
    /// four lines of a stack trace should be one question, not four.
    private func paste() {
        let terminator = Array("\u{1B}[201~".utf8)
        var bytes: [UInt8] = []
        while let byte = Terminal.readByte() {
            bytes.append(byte)
            if bytes.count >= terminator.count,
               Array(bytes.suffix(terminator.count)) == terminator {
                bytes.removeLast(terminator.count)
                break
            }
            if bytes.count > 200_000 { break }
        }
        let text = String(decoding: bytes, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        for letter in text { buffer.insert(letter, at: cursor); cursor += 1 }
        draw()
    }

    /// One character, however many bytes it took.
    ///
    /// Read a byte at a time, so a multi-byte character arrives in pieces and
    /// has to be reassembled before it can be a `Character` — otherwise an
    /// accented letter is three separate insertions of three broken ones, and
    /// the cursor arithmetic that follows counts them as three.
    private func character(startingWith lead: UInt8) -> String {
        var bytes = [lead]
        var wanted = 0
        if lead & 0b1110_0000 == 0b1100_0000 {
            wanted = 1
        } else if lead & 0b1111_0000 == 0b1110_0000 {
            wanted = 2
        } else if lead & 0b1111_1000 == 0b1111_0000 {
            wanted = 3
        }
        for _ in 0..<wanted {
            guard let byte = Terminal.readByte() else { break }
            bytes.append(byte)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Editing

    private func insert(_ text: String) {
        for letter in text { buffer.insert(letter, at: cursor); cursor += 1 }
        draw()
    }

    private func deleteForward() {
        guard cursor < buffer.count else { return }
        buffer.remove(at: cursor)
        draw()
    }

    private func deleteWordBack() {
        let end = cursor
        moveWordLeft()
        guard cursor < end else { return }
        buffer.removeSubrange(cursor..<end)
        draw()
    }

    private func moveWordLeft() {
        while cursor > 0, buffer[cursor - 1].isWhitespace { cursor -= 1 }
        while cursor > 0, !buffer[cursor - 1].isWhitespace { cursor -= 1 }
    }

    private func moveWordRight() {
        while cursor < buffer.count, buffer[cursor].isWhitespace { cursor += 1 }
        while cursor < buffer.count, !buffer[cursor].isWhitespace { cursor += 1 }
    }

    private func replaceLine(with text: String) {
        buffer = Array(text)
        cursor = buffer.count
        offset = 0
        draw()
    }

    // MARK: - Tab

    /// Insert as much as is unambiguous; show the choice when there is one.
    ///
    /// No second-Tab-to-list. That idiom is a shell convention rather than a
    /// discovery mechanism, and the whole reason completion is here is that the
    /// handles and qualifiers this program takes are not guessable — making
    /// somebody press a key twice to be shown them is the wrong half of that.
    private func complete() {
        guard let completion = Completions.of(String(buffer), at: cursor,
                                              directory: directory) else { return }
        guard let applied = completion.applied(to: buffer) else {
            if completion.candidates.count > 1 { list(completion.candidates) }
            return
        }
        buffer = applied.line
        cursor = applied.cursor
        draw()
    }

    /// The candidates, in columns, above a redrawn prompt.
    private func list(_ candidates: [String]) {
        let shown = Array(candidates.prefix(60))
        let column = (shown.map(\.count).max() ?? 0) + 2
        let across = max(1, Terminal.columns / max(column, 1))

        var rows: [String] = []
        var row = ""
        for (index, candidate) in shown.enumerated() {
            row += candidate.padding(toLength: column, withPad: " ", startingAt: 0)
            if (index + 1) % across == 0 { rows.append(row); row = "" }
        }
        if !row.isEmpty { rows.append(row) }
        if candidates.count > shown.count {
            rows.append("… and \(candidates.count - shown.count) more")
        }

        // Straight over the prompt line: the prompt is redrawn underneath, so
        // the list reads as having appeared above where you are typing.
        Terminal.emit("\r\u{1B}[K")
        for line in rows {
            Terminal.emit(Console.dim("  " + line.trimmingCharacters(in: .whitespaces)) + "\n")
        }
        draw()
    }

    // MARK: - Drawing

    /// The whole line, every keystroke.
    ///
    /// Redrawing beats patching. The alternative is working out which cells
    /// changed and moving the cursor to each, which is a great deal of
    /// arithmetic to save writing eighty bytes to a file descriptor — and every
    /// bug in it looks like the terminal is haunted.
    private func draw() {
        let room = max(20, Terminal.columns - promptWidth - 1)

        // Scroll only as far as the cursor demands, and give the room back when
        // the line shrinks — otherwise deleting from a long line leaves the
        // window stuck out to the right of the text still in it.
        if cursor < offset { offset = cursor }
        if cursor - offset > room { offset = cursor - room }
        if buffer.count - offset < room { offset = max(0, buffer.count - room) }
        if cursor < offset { offset = cursor }

        let end = min(buffer.count, offset + room)
        let visible = String(buffer[offset..<end])
        var out = "\r\u{1B}[K" + prompt + visible + "\r"
        let column = promptWidth + (cursor - offset)
        if column > 0 { out += "\u{1B}[\(column)C" }
        Terminal.emit(out)
    }
}
