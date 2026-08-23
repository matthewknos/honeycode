import Foundation

/// The terminal as a device rather than as a transcript.
///
/// `Console` decides what the program says; this decides what the tty will let
/// it say. The split is worth having because everything here is POSIX and
/// fiddly and none of it is interesting, and because `Console` has to keep
/// working when there is no terminal at all — `ai -p "…" > out.txt` is a
/// supported way to run this and nothing below is true in it.
enum Terminal {

    /// Both ends, because a line editor needs to read keys *and* draw. A pipe
    /// on either side means cooked reads and no cursor movement.
    static var isInteractive: Bool {
        isatty(fileno(stdin)) == 1 && isatty(fileno(stdout)) == 1
    }

    /// Written straight out, bypassing `Console`'s mid-line bookkeeping —
    /// these are cursor movements, and it would count them as text.
    static func emit(_ text: String) {
        guard !text.isEmpty else { return }
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    /// What the window calls itself.
    ///
    /// Worth one escape sequence: with four terminals open, the one running a
    /// crew is otherwise indistinguishable from the three that aren't. Set
    /// while work is happening and set back when it stops, so the tab says what
    /// it is doing rather than what it was started as.
    ///
    /// Nothing restores this on exit, because there is no sequence that means
    /// "whatever it was before" — every shell rewrites the title at its next
    /// prompt, which is a second later and is the only correct answer anyway.
    static func title(_ text: String) {
        guard isInteractive else { return }
        emit("\u{1B}]0;\(text)\u{07}")
    }

    // MARK: - Raw mode

    nonisolated(unsafe) private static var saved: termios?

    /// Keys as they are pressed, rather than a line at a time.
    ///
    /// `cfmakeraw` and then output post-processing back on: raw mode otherwise
    /// turns off the newline translation as well, and every `\n` this program
    /// has ever printed would start writing from wherever the last line ended.
    /// The rest of raw mode is wanted — no echo, no line discipline, and no
    /// ISIG, which is what makes ctrl-c a byte this can decide about rather
    /// than a signal that arrives whether or not there is anything to cancel.
    @discardableResult
    static func enterRaw() -> Bool {
        guard isInteractive, saved == nil else { return false }
        var current = termios()
        guard tcgetattr(fileno(stdin), &current) == 0 else { return false }
        var raw = current
        cfmakeraw(&raw)
        raw.c_oflag |= tcflag_t(OPOST) | tcflag_t(ONLCR)
        guard tcsetattr(fileno(stdin), TCSAFLUSH, &raw) == 0 else { return false }
        saved = current
        return true
    }

    /// Always paired with `enterRaw`, including on the way out of the program —
    /// a shell left in raw mode is a shell that stops echoing what you type,
    /// and the person it happens to has no reason to connect it to this.
    static func leaveRaw() {
        guard var previous = saved else { return }
        tcsetattr(fileno(stdin), TCSAFLUSH, &previous)
        saved = nil
    }

    // MARK: - Reading

    /// One byte, or nil once there is no more input.
    ///
    /// `EINTR` is retried rather than reported: a terminal resize interrupts
    /// the read, and treating that as end-of-input would quit the program
    /// because somebody dragged a window edge.
    static func readByte() -> UInt8? {
        var byte: UInt8 = 0
        while true {
            let count = read(fileno(stdin), &byte, 1)
            if count == 1 { return byte }
            if count == 0 { return nil }
            if errno == EINTR { continue }
            return nil
        }
    }

    /// Whether a byte is already waiting. Used to tell `ESC [ A` — an arrow
    /// key, which arrives all at once — from the Escape key on its own.
    static func isPending(within milliseconds: Int32) -> Bool {
        var descriptor = pollfd(fd: fileno(stdin), events: Int16(POLLIN), revents: 0)
        return poll(&descriptor, 1, milliseconds) > 0
    }

    // MARK: - Width

    nonisolated(unsafe) private static var measured = 0

    /// How wide to draw, with 80 as the answer when nobody will say.
    ///
    /// `COLUMNS` first because a person who exports it means it — it is how
    /// you ask a program to lay out for something other than the window it
    /// happens to be in.
    static var columns: Int {
        if let text = ProcessInfo.processInfo.environment["COLUMNS"],
           let value = Int(text), value >= 20 { return value }
        return measured >= 20 ? measured : 80
    }

    /// How many times the terminal has been asked and said nothing. Two is
    /// enough to stop asking: a terminal that doesn't answer never starts, and
    /// the alternative is paying the timeout at every single prompt.
    nonisolated(unsafe) private static var refusals = 0

    /// Ask the terminal how wide it is, by walking the cursor into the right
    /// margin and reading back where it stopped.
    ///
    /// The obvious call is `ioctl(TIOCGWINSZ)`, and this deliberately is not
    /// it: `ioctl` is variadic in C, and `TIOCGWINSZ` is a macro, and both of
    /// those are things the Swift importer handles on its own terms. A
    /// cursor-position report needs nothing but `read` and `write`, and
    /// anything that has ever claimed to be a VT100 answers one.
    ///
    /// Raw mode only, and no reply is a perfectly normal outcome — a terminal
    /// that stays quiet keeps whatever width was last known. Called at each
    /// prompt rather than once, which is what makes a resized window take
    /// effect without listening for SIGWINCH.
    static func measure() {
        guard saved != nil, refusals < 2 else { return }
        // An exported COLUMNS is a decision somebody made, and `columns` reads
        // it first regardless — so there is nothing to find out.
        if ProcessInfo.processInfo.environment["COLUMNS"] != nil { return }

        emit("\u{1B}[999C\u{1B}[6n")

        // "\u{1B}[<rows>;<cols>R". Bounded three ways — the first byte may
        // cross an ssh connection, the rest of the reply follows it
        // immediately, and none of it is obliged to arrive at all.
        var reply = ""
        var wait: Int32 = 200
        while reply.count < 32, isPending(within: wait), let byte = readByte() {
            wait = 30
            if byte == UInt8(ascii: "R") { break }
            reply.append(Character(UnicodeScalar(byte)))
        }

        // No cursor restore: every caller redraws from column zero, and the
        // save/restore pair is the one part of this exchange terminals disagree
        // about.
        emit("\r")

        guard let semicolon = reply.lastIndex(of: ";"),
              let value = Int(reply[reply.index(after: semicolon)...]),
              value >= 20 else { refusals += 1; return }
        refusals = 0
        measured = value
    }
}
