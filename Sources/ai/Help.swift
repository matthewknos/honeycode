import Foundation

/// The one help text, shared by `/help` and `--help`.
///
/// It was two, and the CLI-facing one was the poorer: it named `-p` and nothing
/// else, so the colon syntax and `/models` existed only for someone already
/// sitting in the REPL. That is backwards — the flag surface is the one another
/// program reads, and it was the half that documented least.
///
/// The command half is built from `Commands.all` rather than typed out, which
/// is the whole reason that list exists: a command you can type, cannot see in
/// help, and cannot Tab to is a command nobody has.
///
/// Outside `Program` because `Program` is `@MainActor` and `--help` is answered
/// before there is a main actor worth hopping to.
enum Help {

    static var lines: [String] {
        var out = [
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
            "  tab completes handles, qualifiers, commands and paths",
            "  up and down walk back through what you have asked",
            "",
        ]
        let column = (Commands.all.map(\.usage.count).max() ?? 0) + 2
        for command in Commands.all {
            out.append("  " + command.usage.padding(toLength: column,
                                                    withPad: " ", startingAt: 0)
                       + command.blurb)
        }
        out += [
            "",
            "  ai                      interactive",
            "  ai -p \"<message>\"       one message, printed, then exit",
            "  ai --models [account]   what an account can run",
            "  ai --describe           all of the above as JSON, for other tools",
            "  ai --version",
            "",
            "  anything piped in is added to the message:",
            "    git diff | ai -p \"review this @claude-p\"",
        ]
        return out
    }
}
