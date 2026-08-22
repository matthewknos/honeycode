import Foundation

/// The slash commands, defined once.
///
/// They were three string literals in a `switch`, which is fine until something
/// else needs to know what they are. Two things now do — `/help` prints them
/// and Tab completes them — and a list that three places derive separately is a
/// list that disagrees with itself the first time one gains an entry. So this
/// is the list, and the switch, the help text and the completer all read it.
struct Command {

    /// Without the slash, which is punctuation rather than part of the name.
    let name: String
    /// Other spellings that reach the same place. Not shown in help: an alias
    /// is there for the fingers that already type it, and printing four ways to
    /// quit makes quitting look complicated.
    let aliases: [String]
    /// What it takes, in the form help should show it. Nil for the ones that
    /// take nothing.
    let argument: String?
    let blurb: String

    init(_ name: String, aliases: [String] = [], argument: String? = nil, _ blurb: String) {
        self.name = name
        self.aliases = aliases
        self.argument = argument
        self.blurb = blurb
    }

    /// `/models [account]`, for the help column.
    var usage: String { "/" + name + (argument.map { " " + $0 } ?? "") }
}

enum Commands {

    static let all: [Command] = [
        Command("help", aliases: ["?"], "what all of this is"),
        Command("accounts", aliases: ["agents"], "who is here, and what each still needs"),
        Command("models", argument: "[account]", "what an account can run"),
        Command("cost", "what this month has come to"),
        Command("cwd", "the folder the work happens in"),
        Command("clear", "clear the screen"),
        Command("quit", aliases: ["exit", "q"], "leave"),
    ]

    /// Every spelling, for the completer. Canonical names first so Tab offers
    /// `/quit` before `/q` when both match.
    static var spellings: [String] {
        all.map(\.name) + all.flatMap(\.aliases)
    }

    /// The command a typed line names, and whatever followed it.
    ///
    /// Nil for a line that isn't one — including a line that merely starts with
    /// a slash, which is not the same thing. `/usr/bin/env is a path` is a
    /// perfectly reasonable thing to say to an agent and this must not eat it.
    static func parse(_ line: String) -> (command: Command, argument: String)? {
        guard line.hasPrefix("/") else { return nil }
        let body = line.dropFirst()
        let split = body.firstIndex(of: " ")
        let name = String(body[body.startIndex..<(split ?? body.endIndex)]).lowercased()
        var argument = ""
        if let split {
            argument = String(body[body.index(after: split)...])
                .trimmingCharacters(in: .whitespaces)
        }
        guard let command = all.first(where: { $0.name == name || $0.aliases.contains(name) })
        else { return nil }
        return (command, argument)
    }
}
