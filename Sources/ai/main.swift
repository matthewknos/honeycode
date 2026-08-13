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
        Console.line("  /help  /quit")
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
