import SwiftUI

/// The prose rhythm, ported from shadcn's Typeset.
///
/// The idea worth taking is not any single number — it's that a document has
/// exactly **three** free variables (size, leading, flow) and every other
/// measurement derives from them. The previous version of this file had a
/// hand-picked constant per block type, which is how a transcript ends up with
/// headings that sit closer to the paragraph above than the one below.
///
/// Values are Typeset's, converted from `em` at our 13.5pt base. Leading is the
/// one deliberate departure: Typeset ships 1.75, which is right for a blog
/// column and too airy for a desktop transcript you scan rather than read, so
/// this sits at 1.6.
enum Prose {
    static let base: CGFloat = 13.5

    /// Everything takes a scale factor.
    ///
    /// Typeset's whole point is that a document has one size and everything
    /// derives from it — which means a reader control is a single multiplier
    /// rather than a table of overrides. Spacing scales with the type, because
    /// larger text at unchanged leading reads as cramped, not as larger.
    static func size(_ scale: CGFloat = 1) -> Font { .system(size: base * scale) }

    /// Space between blocks — Typeset's `--typeset-flow`, 1.25em.
    static func flow(_ scale: CGFloat = 1) -> CGFloat { 17 * scale }

    /// A heading owns the space *below* it: the gap to its own content is
    /// tighter than the gap that separates it from the section above. This one
    /// rule does more for perceived structure than any amount of weight or size.
    static func afterHeading(_ scale: CGFloat = 1) -> CGFloat { base * scale }

    static func leading(_ scale: CGFloat = 1) -> CGFloat { Theme.lineSpacing * scale }

    /// Headings. Typeset's ladder, scaled: h1 1.75em … h4 1em.
    static func heading(_ level: Int, _ scale: CGFloat = 1) -> Font {
        let size: CGFloat
        let weight: Font.Weight
        switch level {
        case 1:  size = 20;   weight = .semibold
        case 2:  size = 16.5; weight = .semibold
        case 3:  size = 15;   weight = .semibold
        case 4:  size = 13.5; weight = .semibold
        case 5:  size = 12;   weight = .medium
        default: size = 11;   weight = .medium
        }
        return .system(size: size * scale, weight: weight)
    }

    /// Inline code — 0.85em mono on a muted chip.
    static func inlineCode(_ scale: CGFloat = 1) -> Font {
        .system(size: 11.5 * scale, design: .monospaced)
    }

    /// Marker ladder for nested bullets: disc, circle, square.
    static func bullet(_ depth: Int) -> String {
        switch depth {
        case 0:  return "•"
        case 1:  return "◦"
        default: return "▪"
        }
    }

    /// `padding-inline-start: 1.5em` per level.
    static func indent(_ depth: Int, _ scale: CGFloat = 1) -> CGFloat {
        CGFloat(depth) * 20 * scale
    }
}

/// Renders the markdown the agents actually emit.
///
/// SwiftUI's `Text(AttributedString(markdown:))` handles inline syntax but
/// flattens block structure — fenced code becomes one long line, and lists lose
/// their hanging indent. So blocks are split here and only the inline pass is
/// handed to Foundation.
///
/// `interpretedSyntax: .inlineOnlyPreservingWhitespace` matters: the default
/// collapses runs of whitespace, which mangles anything alignment-sensitive.
struct MarkdownText: View {
    let raw: String
    /// Draw a caret after the final paragraph — set only while text is still
    /// arriving on this block.
    var caret: Bool = false

    var body: some View {
        // `caret` is set only while text is still arriving, which makes it the
        // signal for "don't cache this one" — see `blocks`.
        BlockStack(blocks: Self.blocks(raw, caching: !caret), caret: caret)
    }

    /// Block-pair spacing. Typeset expresses this as `margin-block-start`
    /// overridden by adjacency selectors; the SwiftUI equivalent is asking each
    /// pair what belongs between them.
    static func spacing(after previous: Block, before current: Block,
                        scale: CGFloat = 1) -> CGFloat {
        if case .heading = previous {
            // …unless a rule follows, which is a section break, not content.
            if case .rule = current {} else { return Prose.afterHeading(scale) }
        }
        switch current {
        case .rule:
            return Prose.flow(scale) * 2.4
        case .heading(_, let level):
            if case .rule = previous { return Prose.flow(scale) }
            // h2 is the section marker in agent output and earns extra air.
            return level <= 2 ? Prose.flow(scale) * 1.4 : Prose.flow(scale)
        default:
            return Prose.flow(scale)
        }
    }

    // MARK: Inline

    /// A steady block caret. Deliberately not blinking: the text underneath is
    /// already moving, and a second competing rhythm reads as noise.
    static func caretRun(_ show: Bool) -> AttributedString {
        guard show else { return AttributedString() }
        var caret = AttributedString(" ▌")
        caret.foregroundColor = Color.secondary
        return caret
    }

    /// Memoised, for the same reason `blocks` is — and more urgently.
    ///
    /// `blocks` was cached and this wasn't, which left the expensive half
    /// uncached: every paragraph, list item and table cell on screen re-ran a
    /// full Foundation markdown parse plus run re-attribution on every body
    /// evaluation. While a reply streams that's every visible block in the
    /// transcript, up to sixty times a second, to produce a value identical to
    /// the one thrown away a frame ago.
    ///
    /// Scale is part of the key because it picks the inline-code font.
    private struct InlineKey: Hashable {
        let text: String
        let scale: CGFloat
    }

    nonisolated(unsafe) private static var inlineCache: [InlineKey: AttributedString] = [:]
    nonisolated(unsafe) private static var inlineOrder: [InlineKey] = []

    static func inline(_ text: String, scale: CGFloat = 1) -> AttributedString {
        let key = InlineKey(text: text, scale: scale)
        cacheLock.lock()
        let hit = inlineCache[key]
        cacheLock.unlock()
        if let hit { return hit }

        let rendered = renderInline(text, scale: scale)
        cacheLock.lock()
        inlineCache[key] = rendered
        inlineOrder.append(key)
        // Oldest-first, like `blocks`. The streaming tail mints a new key per
        // delta, so without a ceiling this grows without bound — and clearing
        // wholesale would throw away every settled paragraph at precisely the
        // moment the cache is earning its keep.
        while inlineOrder.count > 1_200 {
            inlineCache.removeValue(forKey: inlineOrder.removeFirst())
        }
        cacheLock.unlock()
        return rendered
    }

    /// Bold, italic, strikethrough and inline code.
    ///
    /// Foundation marks each with a presentation intent but picks no styling, so
    /// the runs are re-attributed here. Code gets a muted chip rather than only
    /// a font change — a bare monospace swap inside a sentence is nearly
    /// invisible at 13.5pt, which is what the previous version shipped.
    ///
    /// The colours are SwiftUI's dynamic ones, so a cached run still follows a
    /// light/dark change without being re-parsed.
    private static func renderInline(_ text: String, scale: CGFloat) -> AttributedString {
        var attributed = (try? AttributedString(
            markdown: text,
            options: .init(allowsExtendedAttributes: true,
                           interpretedSyntax: .inlineOnlyPreservingWhitespace,
                           failurePolicy: .returnPartiallyParsedIfPossible)))
            ?? AttributedString(text)

        for run in attributed.runs {
            guard let intent = run.inlinePresentationIntent else { continue }
            if intent.contains(.code) {
                attributed[run.range].font = Prose.inlineCode(scale)
                attributed[run.range].backgroundColor = Theme.well
                // A code span naming a file that's actually there becomes a
                // link to its preview. Agents announce what they made in
                // exactly this shape — "Done — `/Users/you/Desktop/Deck.pptx`"
                // — and the only way to see it was to go to the Finder.
                if let link = FilePreview.link(for: String(attributed[run.range]
                    .characters)) {
                    attributed[run.range].link = link
                }
            }
            if intent.contains(.strikethrough) {
                attributed[run.range].strikethroughStyle = .single
                attributed[run.range].foregroundColor = .secondary
            }
        }

        // Links keep the text colour and carry an underline, per Typeset —
        // a wall of blue inside body prose fights the text it's part of.
        for run in attributed.runs where run.link != nil {
            attributed[run.range].underlineStyle = .single
        }
        return attributed
    }

    // MARK: Blocks

    struct Item {
        let marker: String
        let text: String
        let depth: Int
        /// Numbered rather than bulleted. Tracked because an ordered list
        /// directly after an unordered one is two lists, not one.
        let ordered: Bool
        /// `nil` for an ordinary bullet. Agents emit GFM task lists constantly
        /// — plans, checklists, "what's left" — and they were rendering with
        /// literal square brackets in the prose.
        var checked: Bool?
    }

    struct Table {
        enum Align { case leading, center, trailing }
        let header: [String]
        let rows: [[String]]
        let alignment: [Align]
    }

    /// `indirect` because a blockquote contains blocks — including, in the wild,
    /// code fences and nested quotes.
    indirect enum Block {
        case paragraph(String)
        case heading(String, Int)
        case list([Item])
        case code(String, String)
        case quote([Block])
        case rule
        case table(Table)
        case chart(ChartSpec)
        /// `![alt](path)` on its own line. Agents produce screenshots and
        /// generated diagrams and then link them; drawing the literal markdown
        /// was showing you the reference instead of the thing.
        case image(String, String)
    }

    /// Parsed blocks, memoised.
    ///
    /// `body` parses on every evaluation, and SwiftUI re-evaluates every
    /// visible block whenever any one of them changes — so a streaming reply
    /// was re-parsing every *other* reply in the transcript on every batch.
    /// The cache is keyed on the exact source, so a block that hasn't changed
    /// costs a dictionary lookup.
    nonisolated(unsafe) private static var cache: [String: [Block]] = [:]
    nonisolated(unsafe) private static var cacheOrder: [String] = []
    private static let cacheLock = NSLock()

    /// - Parameter caching: false while this block is still streaming.
    ///
    /// The cache was built for *settled* blocks — a batch of deltas used to
    /// re-parse every other reply in the transcript — and for those it does
    /// exactly what it says. For the one block still arriving it was three
    /// separate costs and no benefit, because the key is the block's own text
    /// and every tick mints a new one:
    ///
    /// - the lookup hashes the whole reply, and always misses;
    /// - the miss stores a key, so the cache retains that generation of the
    ///   string — which is what silently defeated `Session.appendAssistant`.
    ///   That function blanks the array slot so `+=` can extend the buffer in
    ///   place, and it works right up until something else holds a reference.
    ///   Measured over a 120KB reply: 0.2ms when the buffer is unique against
    ///   282ms when a cache holds the previous generation;
    /// - and the 400 retained keys are 400 progressively longer copies of one
    ///   reply, which is where the memory went.
    ///
    /// So a streaming block parses and returns, touching neither.
    static func blocks(_ raw: String, caching: Bool = true) -> [Block] {
        guard caching else { return parse(raw) }
        cacheLock.lock()
        let hit = cache[raw]
        cacheLock.unlock()
        if let hit { return hit }

        let parsed = parse(raw)
        cacheLock.lock()
        // Streaming mints a new key per batch, so this needs a ceiling — but
        // evict oldest-first rather than clearing. Wiping wholesale threw away
        // every settled block in the transcript each time a streaming reply
        // filled the cache, which turned the memoisation into a re-parse storm
        // at exactly the moment it was needed.
        cache[raw] = parsed
        cacheOrder.append(raw)
        while cacheOrder.count > 400 {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
        cacheLock.unlock()
        return parsed
    }

    private static func parse(_ raw: String) -> [Block] {
        let lines = raw.components(separatedBy: "\n")
        var out: [Block] = []
        var paragraph: [String] = []
        var items: [Item] = []
        var quoted: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            out.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }
        func flushList() {
            guard !items.isEmpty else { return }
            out.append(.list(normalise(items)))
            items = []
        }
        func flushQuote() {
            guard !quoted.isEmpty else { return }
            out.append(.quote(blocks(quoted.joined(separator: "\n"))))
            quoted = []
        }
        func flush() { flushParagraph(); flushList(); flushQuote() }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code. An unterminated fence is normal mid-stream, so the
            // scan runs to the end of the input rather than giving up.
            if trimmed.hasPrefix("```") {
                flush()
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                index += 1
                while index < lines.count,
                      !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    body.append(lines[index])
                    index += 1
                }
                index += 1
                let source = body.joined(separator: "\n")
                // A `chart` fence whose JSON doesn't parse falls back to being
                // a code block. Showing the raw spec beats showing nothing, and
                // it's the only way to tell that the chart was *attempted*.
                if language.lowercased() == "chart", let spec = ChartSpec.parse(source) {
                    out.append(.chart(spec))
                } else if language.lowercased() == "svg",
                          let vector = VectorArtifact.write(source) {
                    // Vectors go down the image path rather than the web view:
                    // `NSImage` reads SVG natively, so there's no JavaScript to
                    // sandbox and it stays crisp when expanded.
                    out.append(.image(vector.path, "SVG"))
                } else {
                    out.append(.code(source, language))
                }
                continue
            }

            if trimmed.isEmpty {
                // A blank line ends a paragraph but not a list — agents put
                // blank lines between bullets constantly, and splitting there
                // turns one list into five.
                flushParagraph()
                flushQuote()
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph(); flushList()
                var rest = String(trimmed.dropFirst())
                if rest.hasPrefix(" ") { rest.removeFirst() }
                quoted.append(rest)
                index += 1
                continue
            }
            flushQuote()

            if isRule(trimmed) {
                flush()
                out.append(.rule)
                index += 1
                continue
            }

            // Only a whole-line image becomes a block. Inline images inside a
            // sentence stay inline, where Foundation's parser handles them.
            if trimmed.hasPrefix("!["), trimmed.hasSuffix(")"),
               let close = trimmed.firstIndex(of: "]"),
               trimmed[trimmed.index(after: close)] == "(" {
                let alt = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<close])
                let path = String(trimmed[trimmed.index(close, offsetBy: 2)...].dropLast())
                flush()
                out.append(.image(path, alt))
                index += 1
                continue
            }

            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix(while: { $0 == "#" }).count
                if level <= 6, trimmed.dropFirst(level).hasPrefix(" ") {
                    flush()
                    out.append(.heading(
                        String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces),
                        level))
                    index += 1
                    continue
                }
            }

            // A table needs its delimiter row to exist before the first row can
            // be claimed — otherwise a line of prose containing pipes is eaten.
            if trimmed.hasPrefix("|"), index + 1 < lines.count,
               let alignment = delimiters(lines[index + 1]) {
                flush()
                let header = cells(trimmed)
                var rows: [[String]] = []
                index += 2
                while index < lines.count,
                      lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(cells(lines[index].trimmingCharacters(in: .whitespaces)))
                    index += 1
                }
                out.append(.table(Table(header: header, rows: rows, alignment: alignment)))
                continue
            }

            if let item = listItem(line) {
                flushParagraph()
                // Bullets giving way to numbers at the same level is a new
                // list. Without this an agent's "steps, then caveats" pattern
                // renders as one run with the markers changing halfway down.
                if let last = items.last, last.depth == item.depth,
                   last.ordered != item.ordered {
                    flushList()
                }
                items.append(item)
                index += 1
                continue
            }

            flushList()
            paragraph.append(line)
            index += 1
        }

        flush()
        return out
    }

    // MARK: Line classifiers

    private static func isRule(_ trimmed: String) -> Bool {
        guard trimmed.count >= 3 else { return false }
        let stripped = trimmed.replacingOccurrences(of: " ", with: "")
        return stripped.allSatisfy { $0 == "-" } || stripped.allSatisfy { $0 == "*" }
            || stripped.allSatisfy { $0 == "_" }
    }

    /// Bullet or ordered item. `depth` carries the **raw indent width** at this
    /// stage; `normalise` turns it into a level once the whole list is known.
    private static func listItem(_ line: String) -> Item? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let width = indent.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        for marker in ["- ", "* ", "+ "] where trimmed.hasPrefix(marker) {
            var body = String(trimmed.dropFirst(2))
            var checked: Bool?
            // GFM task list: `- [ ] todo` / `- [x] done`. The trailing space is
            // optional, because `- [x]` on its own is a checked item with no
            // label — rare, but it used to fall through and render the brackets
            // literally, which looks like the parser giving up.
            if body.count >= 3, body.hasPrefix("["), body.dropFirst(2).hasPrefix("]") {
                let box = body[body.index(after: body.startIndex)]
                if box == " " || box == "x" || box == "X" {
                    checked = box != " "
                    body = String(body.dropFirst(3))
                    if body.hasPrefix(" ") { body.removeFirst() }
                }
            }
            return Item(marker: "", text: body,
                        depth: width, ordered: false, checked: checked)
        }
        if let dot = trimmed.firstIndex(where: { $0 == "." || $0 == ")" }),
           dot > trimmed.startIndex,
           trimmed[trimmed.startIndex..<dot].allSatisfy(\.isNumber),
           trimmed.index(after: dot) < trimmed.endIndex,
           trimmed[trimmed.index(after: dot)] == " " {
            return Item(marker: String(trimmed[trimmed.startIndex...dot]),
                        text: String(trimmed[trimmed.index(dot, offsetBy: 2)...]),
                        depth: width, ordered: true)
        }
        return nil
    }

    /// Turn raw indent widths into nesting levels by *ranking* them.
    ///
    /// Dividing by a fixed step is the obvious approach and it's wrong: agents
    /// nest with two spaces, three, or four, and sometimes switch partway
    /// through a reply. Ranking the distinct widths actually present means a
    /// four-space list reads as one level deep rather than two, whatever
    /// convention produced it.
    private static func normalise(_ items: [Item]) -> [Item] {
        let levels = Set(items.map(\.depth)).sorted()
        return items.map { item in
            let depth = min(levels.firstIndex(of: item.depth) ?? 0, 3)
            return Item(marker: item.marker.isEmpty ? Prose.bullet(depth) : item.marker,
                        text: item.text,
                        depth: depth, ordered: item.ordered, checked: item.checked)
        }
    }

    /// `| --- | :--: | ---: |` → per-column alignment, or nil if this isn't one.
    private static func delimiters(_ line: String) -> [Table.Align]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|") else { return nil }
        let parts = cells(trimmed)
        guard !parts.isEmpty else { return nil }

        var out: [Table.Align] = []
        for part in parts {
            let body = part.replacingOccurrences(of: " ", with: "")
            let left = body.hasPrefix(":")
            let right = body.hasSuffix(":")
            // GFM needs only a single dash, and agents emit `|--|` and `|:-:|`
            // as often as the tidy three-dash form.
            let dashes = body.dropFirst(left ? 1 : 0).dropLast(right ? 1 : 0)
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            if left && right { out.append(.center) }
            else if right { out.append(.trailing) }
            else { out.append(.leading) }
        }
        return out
    }

    private static func cells(_ row: String) -> [String] {
        var body = row
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|") { body.removeLast() }
        return body.components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

// MARK: - Block rendering

/// A run of blocks, spaced by pair.
///
/// Split out from `MarkdownText` because a blockquote contains blocks, so the
/// view hierarchy is genuinely recursive — and a recursive `some View` can't
/// type-check, since the opaque type would be defined in terms of itself. The
/// cycle is broken with a single `AnyView` at the quote, which is the only
/// place it's needed.
private struct BlockStack: View {
    @Environment(\.proseScale) private var scale
    let blocks: [MarkdownText.Block]
    var caret: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                BlockView(block: block,
                          isLast: index == blocks.count - 1,
                          caret: caret)
                    // First block sits flush; every other one is spaced against
                    // the block it follows, not by a flat stack spacing.
                    .padding(.top, index == 0 ? 0
                             : MarkdownText.spacing(after: blocks[index - 1],
                                                    before: block, scale: scale))
            }
        }
    }
}

private struct BlockView: View {
    @Environment(\.proseScale) private var scale
    let block: MarkdownText.Block
    let isLast: Bool
    let caret: Bool

    var body: some View {
        switch block {
        case .paragraph(let text):
            // Appended into the AttributedString rather than concatenated with
            // `Text +` (deprecated on macOS 26), so the caret sits on the last
            // line's baseline and reflows with the text.
            Text(MarkdownText.inline(text, scale: scale)
                 + MarkdownText.caretRun(caret && isLast))
                .font(Prose.size(scale))
                .lineSpacing(Prose.leading(scale))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

        case .heading(let text, let level):
            Text(MarkdownText.inline(level >= 6 ? text.uppercased() : text, scale: scale))
                .font(Prose.heading(level, scale))
                .tracking(level >= 6 ? 0.9 : 0)
                .foregroundStyle(level >= 5 ? AnyShapeStyle(.secondary)
                                            : AnyShapeStyle(.primary))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

        case .list(let items):
            ListBlock(items: items)

        case .code(let source, let language):
            CodeBlock(language: language, source: source)

        case .quote(let inner):
            QuoteBlock(inner: inner)

        case .rule:
            Divider().overlay(Theme.rule)

        case .table(let table):
            TableBlock(table: table)

        case .chart(let spec):
            ChartBlock(spec: spec)

        case .image(let path, let alt):
            MarkdownImage(path: path, alt: alt)
        }
    }
}

private struct ListBlock: View {
    @Environment(\.proseScale) private var scale
    let items: [MarkdownText.Item]

    var body: some View {
        // `li { margin-block-start: 0.5em }` — items breathe less than blocks.
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // A real hanging indent: the marker sits in its own column
                    // so wrapped lines align to the text, not back under the
                    // bullet.
                    Group {
                        if let checked = item.checked {
                            Image(systemName: checked ? "checkmark.square.fill" : "square")
                                .font(.system(size: 11 * scale))
                                .foregroundStyle(checked ? AnyShapeStyle(Color.accentColor)
                                                         : AnyShapeStyle(.tertiary))
                        } else {
                            Text(item.marker)
                                .font(Prose.size(scale))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(minWidth: 14 * scale, alignment: .trailing)
                    Text(MarkdownText.inline(item.text, scale: scale))
                        .font(Prose.size(scale))
                        .lineSpacing(Prose.leading(scale) - 1)
                        // Done items step back without becoming unreadable —
                        // struck-through text in a plan you're still working
                        // from is a nuisance.
                        .foregroundStyle(item.checked == true
                                         ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, Prose.indent(item.depth, scale))
            }
        }
    }
}

private struct QuoteBlock: View {
    @Environment(\.proseScale) private var scale
    let inner: [MarkdownText.Block]

    var body: some View {
        // 2px rule, 1em inset — the same shape a user turn uses, which is the
        // point: a quote and a prompt are both "someone else's words here".
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Theme.rule)
                .frame(width: 2)
            AnyView(BlockStack(blocks: inner))
                .foregroundStyle(.secondary)
                .padding(.leading, Prose.base * scale)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Tables

/// A markdown table.
///
/// Agents emit these constantly — comparison matrices, flag tables, file
/// inventories — and until now every one of them rendered as a wall of pipes.
///
/// Rules follow Typeset: separators live on *cells* rather than on
/// `tr:last-child`, which is what makes a table append-safe while it streams in
/// a row at a time. Header text is medium rather than bold, and the leading
/// column loses its inset so the table's left edge lines up with the prose
/// above it instead of floating inward.
private struct TableBlock: View {
    @Environment(\.proseScale) private var scale
    let table: MarkdownText.Table

    private var columns: Int {
        max(table.header.count, table.rows.map(\.count).max() ?? 0)
    }

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(0..<columns, id: \.self) { column in
                    cell(text(table.header, column), column: column, header: true)
                }
            }
            ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                divider
                GridRow {
                    ForEach(0..<columns, id: \.self) { column in
                        cell(text(row, column), column: column, header: false)
                    }
                }
            }
            divider
        }
        .font(Prose.size(scale))
        .fixedSize(horizontal: false, vertical: true)
    }

    private var divider: some View {
        Divider()
            .overlay(Theme.rule)
            .gridCellUnsizedAxes(.horizontal)
            .gridCellColumns(columns)
    }

    private func cell(_ value: String, column: Int, header: Bool) -> some View {
        let align = table.alignment.indices.contains(column)
            ? table.alignment[column] : .leading

        return Text(MarkdownText.inline(value, scale: scale))
            .font(header ? .system(size: 13.5 * scale, weight: .medium) : Prose.size(scale))
            .foregroundStyle(header ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .monospacedDigit()
            .lineSpacing(2)
            .multilineTextAlignment(textAlignment(align))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: frameAlignment(align))
            // Table cells run on their own tuned geometry — 9/10 vertical, 13
            // horizontal, all multiplied by the prose scale — rather than the
            // app's spacing scale. A header row sits a point tighter than a
            // body row, and none of these is a fixed gap the scale could name.
            .padding(.vertical, (header ? 9 : 10) * scale)
            .padding(.leading, column == 0 ? 0 : 13 * scale)
            .padding(.trailing, 13 * scale)
    }

    private func text(_ row: [String], _ column: Int) -> String {
        row.indices.contains(column) ? row[column] : ""
    }

    private func textAlignment(_ align: MarkdownText.Table.Align) -> TextAlignment {
        switch align {
        case .leading:  return .leading
        case .center:   return .center
        case .trailing: return .trailing
        }
    }

    private func frameAlignment(_ align: MarkdownText.Table.Align) -> Alignment {
        switch align {
        case .leading:  return .leading
        case .center:   return .center
        case .trailing: return .trailing
        }
    }
}

/// An image the agent linked.
///
/// Local paths only. A remote URL would mean the app fetching whatever an agent
/// put in a reply, which is a network request nobody asked for.
private struct MarkdownImage: View {
    let path: String
    let alt: String

    /// The file, once it's known to be there.
    ///
    /// Resolved in a `.task` rather than tested in the body: `fileExists` is a
    /// syscall, and the body of every inline image in the transcript runs on
    /// every redraw — which while a reply streams is sixty times a second.
    @State private var resolved: URL?

    var body: some View {
        Group {
            if let resolved {
                AttachmentStrip(files: [resolved])
            } else {
                HStack(spacing: Theme.s3) {
                    Image(systemName: "photo")
                        .font(.system(size: 10))
                    Text(alt.isEmpty ? path : alt)
                        .font(.system(size: 11.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(.tertiary)
                .help(path)
            }
        }
        .task(id: path) {
            let path = path
            resolved = await Task.detached(priority: .utility) {
                // Local paths only. A remote URL would mean the app fetching
                // whatever an agent put in a reply.
                guard !path.hasPrefix("http") else { return nil }
                let url = FileActions.resolve(path)
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            }.value
        }
    }
}
