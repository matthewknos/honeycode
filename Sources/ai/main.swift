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

@MainActor
final class Program {

    private let crew: Crew
    private let directory: URL
    /// Reading stdin blocks, and the main queue has to stay free for the
    /// adapters' callbacks — they deliver every streamed token on it.
    private let input = DispatchQueue(label: "ai.input")

    init(directory: URL) {
        self.directory = directory
        self.crew = Crew(directory: directory)
        crew.onIdle = { [weak self] in self?.prompt() }
    }

    func run() {
        Migration.run()
        Support.prepare()

        let accounts = Account.allCases.map { "@" + Mention.handle($0) }.joined(separator: "  ")
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
                        .trimmingCharacters(in: .whitespaces))
                default:
                    self.crew.submit(trimmed)
                }
            }
        }
    }

    private func help() {
        Console.line()
        Console.line("  @claude-p @claude-w @kimi @copilot   who does the work")
        Console.line("  first one named leads: it plans, delegates, and assembles")
        Console.line("  no mention reuses whoever led last")
        Console.line()
        Console.line("  pick a model with a colon — no need to remember ids:")
        Console.line("    @copilot:free     cheapest that costs no quota at all")
        Console.line("    @copilot:cheap    lowest usage multiplier on offer")
        Console.line("    @copilot:best     the strongest one available")
        Console.line("    @copilot:haiku    any part of the name also works")
        Console.line()
        Console.line("  /models [account]   what each one can run")
        Console.line("  /help  /quit")
    }

    /// `/models` for the line-up, `/models copilot` for everything that
    /// account offers.
    private func models(_ argument: String) {
        let wanted: [Account]
        if argument.isEmpty {
            wanted = Account.allCases
        } else if let one = Mention.account(forHandle:
                    argument.trimmingCharacters(in: CharacterSet(charactersIn: "@"))) {
            wanted = [one]
        } else {
            Console.failure("no account called \u{22}\(argument)\u{22}")
            return
        }

        // Sequential rather than all at once: the ACP accounts answer after a
        // wait, and four overlapping waits would print the four blocks in
        // whatever order they happened to land.
        var queue = wanted
        func next() {
            guard !queue.isEmpty else { self.prompt(); return }
            let account = queue.removeFirst()
            self.crew.catalogue(for: account) { models, current in
                Console.line()
                Console.line(Console.paint("@" + Mention.handle(account),
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
                    Console.line(Console.dim("    /models \(Mention.handle(account)) for the rest"))
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
let program = MainActor.assumeIsolated {
    Program(directory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
}
signal(SIGINT, SIG_IGN)
let interrupts = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interrupts.setEventHandler { MainActor.assumeIsolated { program.stop() } }
interrupts.resume()

MainActor.assumeIsolated { program.run() }
RunLoop.main.run()
