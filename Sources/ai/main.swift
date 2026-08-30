import Foundation

// `ai` — every subscription in one terminal session.
//
// Name several accounts in one message and the first one named leads: it plans
// the work, hands pieces to the others, and assembles what comes back.
//
//     > a one-page site for a dentist @claude-p @claude-w @kimi
//
// The engine underneath is AgentKit, the same code Honeycode.app runs on, which
// is why this is a few hundred lines rather than a rewrite.

/// What version of this it is.
///
/// The same string the app's bundle carries, kept here by hand because `ai` has
/// no bundle to read it out of. It is one line in two files rather than a build
/// step to make it one line in one.
let version = "0.1"

@MainActor
final class Program {

    private let crew: Crew
    private let directory: URL
    private let editor: LineEditor
    /// Reading stdin blocks, and the main queue has to stay free for the
    /// adapters' callbacks — they deliver every streamed token on it.
    private let input = DispatchQueue(label: "ai.input")

    /// Whether the last thing that happened was ctrl-c on an empty line. Two in
    /// a row leave, which is the convention every agent CLI has settled on and
    /// is better than the alternatives: one is too easy to do by accident, and
    /// none at all means the only way out of a program you entered by typing
    /// two letters is to remember a slash command.
    private var interruptedOnce = false

    init(directory: URL) {
        self.directory = directory
        self.crew = Crew(directory: directory,
                         reporter: ConsoleReporter(title: Program.title(directory)))
        self.editor = LineEditor(directory: directory)
        crew.onIdle = { [weak self] in self?.prompt() }
    }

    /// Everything that has to happen before the first turn, whichever way the
    /// program was entered. `adopt` first: the migrations that follow read and
    /// write preferences, and they should be reading the shared domain.
    ///
    /// `seedDefaults` is the one that was missing, and its absence was the
    /// worst thing about arriving here first. Which accounts you have is a
    /// preference with a default of *yes*, written by the app's setup flow —
    /// so on a Mac that had only ever run `ai`, nothing had written it and all
    /// four accounts read as switched on. The roster said `@claude-p @claude-w
    /// @kimi @copilot` on a machine with none of them installed, and every one
    /// of those mentions failed at the point of use. Seeding here writes the
    /// same detected answer the app would, without marking the app's first run
    /// as done — that flow is still worth showing, and this is not it.
    private func begin() {
        Prefs.adopt()
        Migration.run()
        Support.prepare()
        if !Setup.hasRun { Setup.seedDefaults() }
        Audit.begin()
    }

    /// One message, printed, then out. `ai -p "…"`.
    ///
    /// The point of it is that it composes: a coding agent already sitting in a
    /// terminal can hand work to the other subscriptions through the shell it
    /// already has, with nothing to install, register or approve. Whatever an
    /// organisation decides about agent-to-agent protocols later, running a
    /// program stays allowed.
    func once(_ text: String) {
        begin()
        guard ready(orExplain: true) else { exit(1) }
        crew.onIdle = { exit(0) }
        crew.submit(text)
    }

    /// `ai --models [account]`, then out.
    ///
    /// The same answer `/models` gives, reachable without a terminal session to
    /// type into. That gap is not cosmetic: anything driving `ai -p` could ask
    /// for work to be done but could not ask what was available to do it with,
    /// so it had to guess — and did.
    func listModels(_ argument: String) {
        begin()
        models(argument) { exit(0) }
    }

    /// `ai --describe`, then out.
    func describe() {
        begin()
        Describe.run(crew) { exit(0) }
    }

    /// What the window calls itself while this is running.
    static func title(_ directory: URL) -> String {
        "ai · " + (directory.lastPathComponent.isEmpty ? directory.path
                                                       : directory.lastPathComponent)
    }

    func run() {
        begin()
        Terminal.title(Program.title(directory))

        Console.line()
        Console.line(Console.paint("ai", "244", bold: true)
                     + Console.dim("  \(version)  ·  ")
                     + Console.dim(Console.fit(directory.path, to: Console.width - 14)))
        guard ready(orExplain: true) else { return prompt() }

        let roster = Account.enabled
            .map { Console.paint("@" + AgentMention.handle($0), Console.tint($0)) }
            .joined(separator: "  ")
        Console.line("  " + roster)
        // The line that used to sit here said `tab completes · /help`, which is
        // now under the prompt where it stays rather than scrolling away.
        gettingStarted(Diagnostic.readiness())
        prompt()
    }

    /// What to do next, with what is already done ticked off.
    ///
    /// The idea is Claude Code's, and the half that makes it work is the tick:
    /// a list of four tips is a thing you skip, and a list that has noticed
    /// which two of them you have already done is a list about *this* machine.
    /// `Diagnostic.readiness` has had the answer all along and only ever used
    /// it to complain.
    ///
    /// Shown on a first run, and after that only when something is actually
    /// waiting. Somebody whose four accounts all work does not need to be told
    /// so every time they open a terminal.
    private func gettingStarted(_ roster: [AccountReadiness]) {
        let waiting = roster.filter { !$0.isReady }
        let greeted = Prefs.store.bool(forKey: Program.greetedKey)
        guard !greeted || !waiting.isEmpty else { return }
        Prefs.store.set(true, forKey: Program.greetedKey)

        Console.line()
        Console.line(Console.hint("  Getting started:"))
        Console.line()

        let ready = roster.filter(\.isReady).map { AgentMention.handle($0.account) }
        if !ready.isEmpty {
            step("✓", names(ready) + (ready.count == 1 ? " is ready" : " are ready"))
        }
        // Three at most. Past that it is the same list `/accounts` prints, and
        // this is a greeting rather than a report.
        for state in waiting.prefix(3) {
            step("·", AgentMention.handle(state.account) + " is " + state.summary
                    + " — /accounts")
        }
        step(" ", "Name several in one message and the first one leads")
        step(" ", "Tab completes handles, models and paths")
    }

    private static let greetedKey = "ai.greeted"

    private func step(_ mark: String, _ text: String) {
        let symbol = mark == "✓" ? Console.paint(mark, "71") : Console.dim(mark)
        Console.line("  " + symbol + "  " + Console.hint(text))
    }

    /// `claude-p, claude-w and kimi`.
    private func names(_ list: [String]) -> String {
        guard list.count > 1, let last = list.last else { return list.first ?? "" }
        return list.dropLast().joined(separator: ", ") + " and " + last
    }

    /// Whether there is anybody to talk to, and what to do about it if not.
    ///
    /// This is the whole of `ai`'s setup. There is no flow to run and there
    /// shouldn't be — a terminal program that interviews you before it will
    /// take an instruction is a worse terminal program — so the answer is to
    /// say plainly what is missing and print the line that fixes it, which is
    /// the same line `Diagnostic` gives the app's buttons and `doctor.sh`
    /// prints. One source, three faces.
    @discardableResult
    private func ready(orExplain explain: Bool) -> Bool {
        let roster = Diagnostic.readiness()
        if roster.contains(where: { $0.isReady }) { return true }
        guard explain else { return false }

        Console.line()
        if roster.isEmpty {
            Console.failure("no accounts switched on")
            Console.line(Console.dim("  Nothing on this Mac looks like an agent CLI yet."))
        } else {
            Console.failure("nothing is ready to run")
        }
        Console.line()
        let all = Diagnostic.readinessOfAll()
        let width = column(of: all)
        // No connector: nothing asked for this. It is what the program says
        // when it opens and finds it has nothing to work with.
        let answer = Answer(indent: "", connector: false)
        for state in all { report(state, into: answer, column: width) }
        Console.line()
        Console.line(Console.dim("  ./tools/doctor.sh checks the same things in more detail."))
        return false
    }

    /// One account, as a line and — when there is something to do about it —
    /// the line that does it.
    ///
    /// - Parameter column: how wide the widest handle in this roster is, so the
    ///   summaries line up. Four accounts whose states each start at a
    ///   different column is a list you have to read rather than scan, and
    ///   scanning it is the entire reason it is printed.
    private func report(_ state: AccountReadiness, into answer: Answer, column: Int) {
        let handle = "@" + AgentMention.handle(state.account)
        let name = Console.paint(handle, Console.tint(state.account), bold: true)
        let mark = state.isReady ? "✓" : "·"
        let off = state.account.isEnabled ? "" : "  (switched off)"
        let pad = String(repeating: " ", count: max(0, column - handle.count))
        answer.line(mark + " " + name + pad + Console.dim("  " + state.summary + off))
        // Wrapped rather than cut. A remedy is the one line here somebody is
        // going to act on — `npx comes with Node.js…` runs to about a hundred
        // and thirty characters — and half of an instruction is worse than a
        // second line of one.
        guard let remedy = state.remedy else { return }
        for text in Console.wrap(remedy, to: Console.width - 12, indent: "   ") {
            answer.line(Console.dim(text))
        }
    }

    /// The width to align a roster's summaries to.
    private func column(of roster: [AccountReadiness]) -> Int {
        roster.map { AgentMention.handle($0.account).count + 1 }.max() ?? 0
    }

    // MARK: - The prompt

    private func prompt() {
        Console.paragraph()
        // Read on the main actor and handed to the queue as a value. The editor
        // is not main-actor state and must not be reached through `self` from
        // another queue, which is the same reason the old code unwrapped its
        // `self` only after hopping back.
        let editor = self.editor
        let mark = Console.paint("> ", "244", bold: true)
        input.async {
            let outcome = editor.read(prompt: mark, width: 2)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.handle(outcome)
            }
        }
    }

    private func handle(_ outcome: LineEditor.Outcome) {
        switch outcome {
        case .endOfInput:
            exit(0)
        case .interrupted:
            guard interruptedOnce else {
                interruptedOnce = true
                Console.line(Console.dim("  ctrl-c again to leave, or /quit"))
                prompt()
                return
            }
            exit(0)
        case .line(let text):
            interruptedOnce = false
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return prompt() }
            guard let slash = Commands.parse(trimmed) else {
                return crew.submit(trimmed)
            }
            perform(slash.command, slash.argument)
        }
    }

    private func perform(_ command: Command, _ argument: String) {
        switch command.name {
        case "help":
            for line in Help.lines { Console.line(line) }
            prompt()
        case "accounts":
            accounts { self.prompt() }
        case "models":
            models(argument) { self.prompt() }
        case "cost":
            cost()
            prompt()
        case "cwd":
            Console.line()
            Answer().line(directory.path)
            prompt()
        case "clear":
            Console.write("\u{1B}[2J\u{1B}[H")
            Console.markFresh()
            prompt()
        case "quit":
            exit(0)
        default:
            Console.failure("nothing implements /\(command.name)")
            prompt()
        }
    }

    // MARK: - What the commands say

    /// Every account and what it still needs.
    ///
    /// Off the main queue because it stats a dozen paths and may walk the nvm
    /// tree — quick, but not so quick that it should happen where the adapters
    /// deliver their tokens.
    private func accounts(then finish: @escaping () -> Void) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let roster = Diagnostic.readinessOfAll()
            DispatchQueue.main.async {
                guard let self else { return }
                Console.line()
                let width = self.column(of: roster)
                let answer = Answer()
                for state in roster { self.report(state, into: answer, column: width) }
                finish()
            }
        }
    }

    /// What has been spent, and against what.
    ///
    /// Only what is already known — no polling. `/usage` runs a process per
    /// Claude account and the answer arrives seconds later, which is fine for a
    /// window that can update a row and wrong for a command that has to print
    /// something and give the prompt back.
    private func cost() {
        let store = UsageStore.shared
        let answer = Answer()
        var total = 0.0
        var ceiling = 0.0
        Console.line()
        let column = Account.enabled
            .map { AgentMention.handle($0).count + 1 }.max() ?? 0
        for account in Account.enabled {
            let spent = store.monthlySpend[account] ?? 0
            total += spent
            ceiling += store.cap(for: account)
            let handle = "@" + AgentMention.handle(account)
            let name = Console.paint(handle, Console.tint(account), bold: true)
            let pad = String(repeating: " ", count: max(0, column - handle.count))
            // What the agent says it has left, where it says anything. Money is
            // the fallback rather than the headline: on three of the four
            // accounts a dollar figure is this app's own tally and the
            // percentage is the plan's own answer.
            let left = store.reading(for: account)?.binding
                .map { "  \($0.percent)% \($0.short)" } ?? ""
            answer.line(name + pad + Console.dim(String(format: "  $%.2f", spent) + left))
        }
        answer.line(Console.dim(String(format: "this month  $%.2f of $%.2f",
                                       total, ceiling)))
    }

    /// `/models` for the line-up, `/models copilot` for everything that
    /// account offers.
    ///
    /// Takes a continuation rather than calling `prompt()` itself, because it
    /// now has two callers that want different things afterwards: the REPL
    /// wants its prompt back, and `ai --models` wants to exit.
    private func models(_ argument: String, then finish: @escaping () -> Void) {
        let wanted: [Account]
        if argument.isEmpty {
            wanted = Account.enabled
        } else if let one = AgentMention.account(forHandle:
                    argument.trimmingCharacters(in: CharacterSet(charactersIn: "@"))) {
            wanted = [one]
        } else {
            Console.failure("no account called \u{22}\(argument)\u{22}")
            finish()
            return
        }

        // Sequential rather than all at once: the ACP accounts answer after a
        // wait, and four overlapping waits would print the four blocks in
        // whatever order they happened to land.
        var queue = wanted
        func next() {
            guard !queue.isEmpty else { finish(); return }
            let account = queue.removeFirst()
            self.crew.catalogue(for: account) { models, current in
                Console.line()
                let answer = Answer()
                answer.line(Console.paint("@" + AgentMention.handle(account),
                                          Console.tint(account), bold: true)
                            + Console.dim("  \(models.count) available"))
                // The whole list only when asked for one account. Four accounts
                // at twenty models each is a page you have to scroll past to
                // get back to the prompt.
                let shown = argument.isEmpty
                    ? models.filter { $0.id == current }
                    : models
                let column = shown.map(\.title.count).max() ?? 0
                for model in shown {
                    answer.line(ModelPick.describe(model, current: model.id == current,
                                                   column: column))
                }
                if argument.isEmpty && models.count > 1 {
                    answer.line(Console.hint("/models \(AgentMention.handle(account)) for the rest"))
                }
                next()
            }
        }
        next()
    }

    func stop() { crew.interrupt() }
}

// MARK: - Getting in

let arguments = Array(CommandLine.arguments.dropFirst())

/// Whatever was piped in, or nothing.
///
/// Read once, eagerly, before anything decides what to do — a redirect is
/// finite and reading it costs nothing, and the alternative is every branch
/// below having to remember to check.
///
/// This is what makes `ai` compose with the shell it is already sitting in:
/// `git diff | ai -p "review this @claude-p"` needs no flag, no temporary file
/// and no quoting of a diff.
let piped: String? = {
    guard isatty(fileno(stdin)) == 0 else { return nil }
    let data = FileHandle.standardInput.readDataToEndOfFile()
    let text = String(decoding: data, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
}()

/// A message and its input, joined the way a person would read them.
func joined(_ message: String) -> String {
    guard let piped else { return message }
    guard !message.isEmpty else { return piped }
    return message + "\n\n" + piped
}

/// Asked for. Goes to stdout and succeeds — `ai --help | grep` is a reasonable
/// thing to do, and a help text on stderr behind a non-zero exit is not.
func showHelp() -> Never {
    for line in Help.lines { print(line) }
    print()
    exit(0)
}

/// Got it wrong. Short, to stderr, non-zero — the full text is one flag away
/// and repeating it here buries the thing that was actually wrong.
func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: ai                      interactive
           ai -p "<message>"       one message, printed, then exit
           ai --models [account]   what an account can run
           ai --describe           capabilities and catalogue, as JSON
           ai --help               all of it

    Name the agents in the message. The first one leads:
      ai -p "a landing page for a dentist @claude-p @copilot:free @kimi"

    """.utf8))
    exit(2)
}

let program = MainActor.assumeIsolated {
    Program(directory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
}

// ctrl-c interrupts the run rather than killing the process — a crew mid-flight
// has child processes to stop, and the default handler would orphan them. While
// the prompt is up the terminal is in raw mode and ctrl-c is a byte the editor
// reads instead, so this fires only during a turn, which is when it means
// something.
signal(SIGINT, SIG_IGN)
let interrupts = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interrupts.setEventHandler { MainActor.assumeIsolated { program.stop() } }
interrupts.resume()

switch arguments.first {
case nil:
    // Something piped in and no message to attach it to is itself the message.
    // `ai < question.txt` and `echo "… @kimi" | ai` both mean the same thing,
    // and neither of them wants a prompt it has no keyboard to answer.
    if let piped {
        MainActor.assumeIsolated { program.once(piped) }
    } else {
        MainActor.assumeIsolated { program.run() }
    }
case "-p", "--print":
    let message = joined(arguments.dropFirst().joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines))
    guard !message.isEmpty else { usage() }
    MainActor.assumeIsolated { program.once(message) }
case "--models", "-m":
    let account = arguments.dropFirst().joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    MainActor.assumeIsolated { program.listModels(account) }
case "--describe":
    guard arguments.count == 1 else { usage() }
    MainActor.assumeIsolated { program.describe() }
case "-h", "--help":
    showHelp()
case "--version", "-v":
    print("ai \(version)")
    exit(0)
default:
    // Bare words are the message, so `ai "do the thing @kimi"` works without
    // the flag — the flag exists for the case where the message starts with
    // something that looks like one.
    let message = joined(arguments.joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines))
    guard !message.isEmpty, !arguments[0].hasPrefix("-") else { usage() }
    MainActor.assumeIsolated { program.once(message) }
}
RunLoop.main.run()
