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

/// The one help text, shared by `/help` and `--help`.
///
/// It was two, and the CLI-facing one was the poorer: it named `-p` and nothing
/// else, so the colon syntax and `/models` existed only for someone already
/// sitting in the REPL. That is backwards — the flag surface is the one another
/// program reads, and it was the half that documented least.
///
/// Outside `Program` because `Program` is `@MainActor` and `--help` is answered
/// before there is a main actor worth hopping to.
enum Help {
    static let lines: [String] = [
        "",
        "  @claude-p @claude-w @kimi @copilot   who does the work",
        "  first one named leads: it plans, delegates, and assembles",
        "  no mention reuses whoever led last",
        "",
        "  pick a model with a colon — every handle, not just copilot:",
        "    @kimi:k3           any part of the title or id",
        "    @copilot:free      cheapest that costs no quota at all",
        "    @copilot:cheap     lowest usage multiplier on offer",
        "    @copilot:best      the strongest one available",
        "    @claude-w:haiku    exact ids work too, if you know them",
        "  it sticks for the session, and becomes that account's default",
        "",
        "  and how hard it thinks, on Claude accounts:",
        "    @claude-p:max      low · medium · high · xhigh · max",
        "    @claude-p:opus:max both at once, in either order",
        "",
        "  what's on offer:",
        "    ai --models [account]   from a shell",
        "    /models [account]       from here",
        "    ai --describe           all of the above as JSON, for other tools",
        "",
        "  ai                      interactive",
        "  ai -p \"<message>\"       one message, printed, then exit",
        "  /help  /quit",
    ]
}

@MainActor
final class Program {

    private let crew: Crew
    private let directory: URL
    /// Reading stdin blocks, and the main queue has to stay free for the
    /// adapters' callbacks — they deliver every streamed token on it.
    private let input = DispatchQueue(label: "ai.input")

    init(directory: URL) {
        self.directory = directory
        self.crew = Crew(directory: directory, reporter: ConsoleReporter())
        crew.onIdle = { [weak self] in self?.prompt() }
    }

    /// Everything that has to happen before the first turn, whichever way the
    /// program was entered. `adopt` first: the migrations that follow read and
    /// write preferences, and they should be reading the shared domain.
    private func begin() {
        Prefs.adopt()
        Migration.run()
        Support.prepare()
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

    func run() {
        begin()

        let accounts = Account.allCases.map { "@" + AgentMention.handle($0) }.joined(separator: "  ")
        Console.line()
        Console.line(Console.paint("ai", "244", bold: true) + Console.dim("  ·  " + directory.path))
        Console.line(Console.dim("  " + accounts))
        Console.line(Console.dim("  name several and the first one leads. ctrl-c stops, ctrl-d quits."))
        prompt()
    }

    private func prompt() {
        input.async { [weak self] in
            Console.write("\n" + Console.paint("> ", "244", bold: true))
            guard let line = readLine(strippingNewline: true) else {
                // ctrl-d.
                DispatchQueue.main.async { Console.line(); exit(0) }
                return
            }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                guard let self else { return }
                switch trimmed {
                case "":
                    self.prompt()
                case "/quit", "/exit":
                    exit(0)
                case "/help":
                    self.help()
                    self.prompt()
                case _ where trimmed == "/models" || trimmed.hasPrefix("/models "):
                    self.models(String(trimmed.dropFirst("/models".count))
                        .trimmingCharacters(in: .whitespaces)) { self.prompt() }
                default:
                    self.crew.submit(trimmed)
                }
            }
        }
    }

    private func help() {
        for line in Help.lines { Console.line(line) }
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
            wanted = Account.allCases
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
                Console.line(Console.paint("@" + AgentMention.handle(account),
                                           Console.tint(account), bold: true)
                             + Console.dim("  \(models.count) available"))
                // The whole list only when asked for one account. Four accounts
                // at twenty models each is a page you have to scroll past to
                // get back to the prompt.
                let shown = argument.isEmpty
                    ? models.filter { $0.id == current }
                    : models
                for model in shown {
                    Console.line(ModelPick.describe(model, current: model.id == current))
                }
                if argument.isEmpty && models.count > 1 {
                    Console.line(Console.dim("    /models \(AgentMention.handle(account)) for the rest"))
                }
                next()
            }
        }
        next()
    }

    func stop() { crew.interrupt() }
}

// ctrl-c interrupts the run rather than killing the process — a crew mid-flight
// has child processes to stop, and the default handler would orphan them.
let arguments = Array(CommandLine.arguments.dropFirst())

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
signal(SIGINT, SIG_IGN)
let interrupts = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interrupts.setEventHandler { MainActor.assumeIsolated { program.stop() } }
interrupts.resume()

switch arguments.first {
case nil:
    MainActor.assumeIsolated { program.run() }
case "-p", "--print":
    let message = arguments.dropFirst().joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
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
default:
    // Bare words are the message, so `ai "do the thing @kimi"` works without
    // the flag — the flag exists for the case where the message starts with
    // something that looks like one.
    let message = arguments.joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !message.isEmpty, !message.hasPrefix("-") else { usage() }
    MainActor.assumeIsolated { program.once(message) }
}
RunLoop.main.run()
