import Foundation

/// Subsequence matching with a gap penalty.
///
/// Lived on `CommandPalette` until `/send` needed the same ranking to resolve a
/// destination by name. Two callers with nothing else in common is the point at
/// which "where it's used" stopped being a good answer to "where it lives" —
/// and the daemon has to resolve `/send enterprise` with no palette in sight.
enum Fuzzy {

    /// Lower is better; nil means the needle isn't a subsequence at all.
    static func score(_ needle: String, in haystack: String) -> Int? {
        let query = Array(needle.lowercased())
        let target = Array(haystack.lowercased())
        var qi = 0, cost = 0, lastHit = -1

        for (index, character) in target.enumerated() where qi < query.count {
            guard character == query[qi] else { continue }
            if lastHit >= 0 { cost += index - lastHit - 1 }   // gaps are penalised
            else { cost += index }                            // so is a late start
            lastHit = index
            qi += 1
        }
        return qi == query.count ? cost : nil
    }
}
