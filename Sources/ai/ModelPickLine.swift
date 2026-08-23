import Foundation

/// How `/models` prints one row.
///
/// Split from `ModelPick` when the picker moved into AgentKit, and the seam is
/// exactly where it should be: resolving `@copilot:free` to a model is a
/// question about entitlements that the app asks too, whereas lining names up in
/// a column and dimming an id is a question about a terminal.
extension ModelPick {

    /// One line per model, for `/models`.
    ///
    /// - Parameter column: how wide the widest title in *this* list is. It was
    ///   a flat 28, which aligns a Copilot roster of twenty and leaves Kimi's
    ///   three names floating half a screen from their ids.
    static func describe(_ model: AgentModel, current: Bool, column: Int) -> String {
        let mark = current ? "•" : " "
        let price: String
        if let usage = model.usage {
            price = usage == 0 ? "free" : (usage == floor(usage)
                ? "\(Int(usage))×" : String(format: "%g×", usage))
        } else {
            price = ""
        }
        let width = max(column, model.title.count)
        let name = model.title.padding(toLength: width, withPad: " ", startingAt: 0)
        // The id is the one part that can be given up. On a narrow window it is
        // also the longest thing on the line, and the title beside it already
        // says which model this is.
        // 13 is what `Answer` and this line put in front of the id: four of
        // indent, the mark and its space, and seven of price column.
        let id = Console.fit(model.id, to: max(8, Console.width - width - 13))
        return "\(mark) \(name)\(price.padding(toLength: 7, withPad: " ", startingAt: 0))\(Console.dim(id))"
    }
}
