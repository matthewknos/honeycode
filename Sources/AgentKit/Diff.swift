import Foundation

/// One line of a unified diff.
struct DiffRow: Identifiable, Codable, Sendable {
    enum Kind: String, Codable { case context, add, del }

    let id = UUID()
    let old: Int?
    let new: Int?
    let kind: Kind
    let text: String

    /// `id` is deliberately absent: it exists for `ForEach`, not for the file
    /// on disk, and leaving it out lets it stay a `let` with a default rather
    /// than something the decoder has to be told to skip.
    private enum CodingKeys: String, CodingKey { case old, new, kind, text }
}

enum Diff {

    /// Unified diff between two file contents, trimmed to `context` lines
    /// either side of each change.
    ///
    /// Built on `CollectionDifference`, which gives insertions and removals
    /// keyed by offset; walking both sides in step turns that into the
    /// interleaved old/new rows a unified diff needs.
    static func rows(from old: String, to new: String, context: Int = 3) -> [DiffRow] {
        let oldLines = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let newLines = new.isEmpty ? [] : new.components(separatedBy: "\n")

        let difference = newLines.difference(from: oldLines)
        var removed: [Int: String] = [:]
        var inserted: [Int: String] = [:]
        for change in difference {
            switch change {
            case .remove(let offset, let element, _): removed[offset] = element
            case .insert(let offset, let element, _): inserted[offset] = element
            }
        }

        // Walked as plain tuples first, and turned into `DiffRow`s only once
        // `trim` has decided which survive.
        //
        // Every `DiffRow` mints a `UUID`, and building one per line of the file
        // meant a thousand secure random draws to render a two-line edit — all
        // but a handful of them allocated, hashed into a set, and thrown away
        // in the same breath. This runs on every Write and every Edit.
        var rows: [(old: Int?, new: Int?, kind: DiffRow.Kind, text: String)] = []
        var o = 0, n = 0
        while o < oldLines.count || n < newLines.count {
            if let line = removed[o] {
                rows.append((o + 1, nil, .del, line))
                o += 1
            } else if let line = inserted[n] {
                rows.append((nil, n + 1, .add, line))
                n += 1
            } else if o < oldLines.count && n < newLines.count {
                rows.append((o + 1, n + 1, .context, oldLines[o]))
                o += 1; n += 1
            } else {
                break
            }
        }
        return trim(rows, context: context)
            .map { DiffRow(old: $0.old, new: $0.new, kind: $0.kind, text: $0.text) }
    }

    private typealias Line = (old: Int?, new: Int?, kind: DiffRow.Kind, text: String)

    /// Keep only rows within `context` of a change. Without this a two-line
    /// edit to a thousand-line file renders the whole file.
    private static func trim(_ rows: [Line], context: Int) -> [Line] {
        let changed = rows.indices.filter { rows[$0].kind != .context }
        guard !changed.isEmpty else { return [] }

        var keep = Set<Int>()
        for index in changed {
            for offset in (index - context)...(index + context) where rows.indices.contains(offset) {
                keep.insert(offset)
            }
        }
        return rows.indices.filter(keep.contains).map { rows[$0] }
    }
}
