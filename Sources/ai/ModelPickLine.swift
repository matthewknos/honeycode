import Foundation

/// How `/models` prints one row.
///
/// Split from `ModelPick` when the picker moved into AgentKit, and the seam is
/// exactly where it should be: resolving `@copilot:free` to a model is a
/// question about entitlements that the app asks too, whereas padding a name to
/// twenty-eight columns and dimming an id is a question about a terminal.
extension ModelPick {

    /// One line per model, for `/models`.
    static func describe(_ model: AgentModel, current: Bool) -> String {
        let mark = current ? "•" : " "
        let price: String
        if let usage = model.usage {
            price = usage == 0 ? "free" : (usage == floor(usage)
                ? "\(Int(usage))×" : String(format: "%g×", usage))
        } else {
            price = ""
        }
        let column = max(28, model.title.count)
        let name = model.title.padding(toLength: column, withPad: " ", startingAt: 0)
        // The id is the one part that can be given up. On a narrow window it is
        // also the longest thing on the line, and the title beside it already
        // says which model this is.
        let id = Console.fit(model.id, to: max(8, Console.width - column - 11))
        return "  \(mark) \(name)\(price.padding(toLength: 7, withPad: " ", startingAt: 0))\(Console.dim(id))"
    }
}
