import Foundation

/// The fenced blocks a crew run uses to talk to itself, and how to keep them
/// off the screen.
///
/// `ai-delegate` and `ai-message` are wire formats. A lead ends its planning
/// turn with a block of JSON assignments; a delegate ends a turn with a block
/// of JSON questions. Both are read by `Crew`, and both are then rendered
/// properly — the plan becomes a list of labelled assignments, a message
/// becomes `@kimi#4 → @claude-p — …`. The raw block is not a second, worse copy
/// of that; it is the transport, and it was never meant to be looked at.
///
/// It was, though, in every mode. The lead's plan arrives as an `.assistant`
/// item in the transcript and a delegate's questions arrive in its mirrored
/// block, and nothing between the CLI and the screen knew those lines were
/// plumbing — so four assignments of three hundred words each went onto the
/// screen as JSON, directly above the same four rendered as a tidy list.
///
/// Hidden rather than collapsed to a placeholder, deliberately. Something has
/// already said what was in the block, on the line below; a `▸ 4 assignments`
/// stub would be a third telling of the same thing.
enum CrewFence {

    /// The fences that are transport. Kept as strings rather than read off
    /// `Crew` so this file has no opinion about `@MainActor`, and checked
    /// against `Crew.fence` / `Crew.messageFence` by the suite.
    static let names = ["ai-delegate", "ai-message"]

    private static let openers = names.map { "```" + $0 }
    private static let closer = "```"
    /// The longest thing `mightOpen` ever has to hold back.
    static let longestOpener = openers.map(\.count).max() ?? 0

    /// A complete line that starts one of these blocks.
    static func opens<S: StringProtocol>(_ line: S) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return openers.contains(trimmed)
    }

    /// A complete line that ends any fenced block. Only consulted while inside
    /// one of ours, so a closing fence elsewhere is none of its business.
    static func closes<S: StringProtocol>(_ line: S) -> Bool {
        line.trimmingCharacters(in: .whitespaces) == closer
    }

    /// Whether a half-arrived line could still turn into an opener.
    ///
    /// A streamed reply splits wherever the network did, so `​```ai-mes` is a
    /// perfectly normal thing to be handed. Holding those few characters back
    /// for one frame is what lets the opener be recognised at all; releasing
    /// them the moment they can't be an opener is what stops an ordinary code
    /// fence from ever being delayed.
    static func mightOpen<S: StringProtocol>(_ partial: S) -> Bool {
        let trimmed = partial.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= longestOpener else { return false }
        return openers.contains { $0.hasPrefix(trimmed) }
    }

    /// Whether `` ```ai- `` appears anywhere — the common prefix of both openers.
    ///
    /// This is the guard on `hidden`, which runs on the block still streaming on
    /// every redraw. The guard used to be `text.contains("```")`, which is true
    /// of most replies a coding agent writes, so nearly every answer fell
    /// through to a full split and rejoin of the whole text per tick — to
    /// rebuild a string identical to the one it was handed.
    ///
    /// Narrowing it to the openers is right and the obvious way to do it is
    /// wrong. `String.contains` is grapheme-aware and has no early exit on a
    /// miss, so asking it for a needle that isn't there costs *more* than the
    /// work it was meant to skip. Over a 130KB reply, per tick: doing nothing
    /// and just splitting cost 1854ms, one `contains("```ai-")` cost 2467ms,
    /// and checking both openers separately cost 5094ms. The first attempt at
    /// this made the app three times slower and only measuring caught it.
    ///
    /// Scanning the UTF-8 bytes costs 58ms. A needle this short and this
    /// unusual doesn't need a real substring algorithm.
    private static func mentionsOpener(_ text: String) -> Bool {
        var found = false
        let scanned: Void? = text.utf8.withContiguousStorageIfAvailable { buf in
            let n = buf.count
            guard n >= 6 else { return }
            var i = 0
            while i <= n - 6 {
                // "```ai-"
                if buf[i] == 0x60, buf[i + 1] == 0x60, buf[i + 2] == 0x60,
                   buf[i + 3] == 0x61, buf[i + 4] == 0x69, buf[i + 5] == 0x2D {
                    found = true
                    return
                }
                i += 1
            }
        }
        // No contiguous storage — a bridged NSString. Do the work rather than
        // skip it: being slow is a cost, wrongly hiding nothing is a bug.
        guard scanned != nil else { return true }
        return found
    }

    /// The whole text with every transport block taken out.
    ///
    /// For a renderer that redraws an item from scratch each time — the card
    /// transcript — where there is no streaming state to keep and the honest
    /// answer is simply to filter the string. An unclosed block runs to the
    /// end: a turn that stopped mid-fence has no prose after it to lose.
    static func hidden(from text: String) -> String {
        guard mentionsOpener(text) else { return text }
        var out: [Substring] = []
        var suppressing = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if suppressing {
                if closes(line) { suppressing = false }
                continue
            }
            if opens(line) { suppressing = true; continue }
            out.append(line)
        }
        // A trailing empty piece is the split of a final newline, and dropping
        // it would eat the blank line a reply legitimately ends on — but a
        // block removed from the end leaves one of its own, so trim there.
        while out.last?.isEmpty == true, suppressing || out.count > 1 { out.removeLast() }
        return out.joined(separator: "\n")
    }
}
