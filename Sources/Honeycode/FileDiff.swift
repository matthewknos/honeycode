import SwiftUI

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

/// Small file contents, cached against the file's own mtime and size.
///
/// Keyed by path so two cards showing the same file share one copy, and
/// revalidated on every ask so an edit lands immediately — the point is to stop
/// re-*reading* an unchanged file, not to stop noticing a changed one.
enum WrittenFile {
    private struct Entry {
        let modified: Date?
        let size: Int
        let text: String
        /// When the entry was last checked against the file.
        var checked: Date
    }

    /// How long a revalidation is good for.
    ///
    /// The stat this saves isn't free: a diff card asks on every body
    /// evaluation, and a transcript being streamed into evaluates up to sixty
    /// times a second — so an applied card was one `attributesOfItem` syscall
    /// per frame, on the main thread, for a file that changes at most once a
    /// turn. Short enough that an edit still lands within a frame or two of
    /// arriving, which is the behaviour this cache was written to preserve.
    private static let revalidate: TimeInterval = 0.25

    /// These are documents an agent just wrote, not gigabytes. Past this, a
    /// preview isn't what you want anyway.
    private static let sizeLimit = 2_000_000

    nonisolated(unsafe) private static var cache: [String: Entry] = [:]
    nonisolated(unsafe) private static var order: [String] = []
    private static let lock = NSLock()

    static func contents(_ url: URL) -> String? {
        let now = Date()
        lock.lock()
        let cached = cache[url.path]
        lock.unlock()
        // Checked recently enough that asking the filesystem again would be
        // asking a question we already have this frame's answer to.
        if let cached, now.timeIntervalSince(cached.checked) < revalidate {
            return cached.text
        }

        guard let attributes = try? FileManager.default
            .attributesOfItem(atPath: url.path) else { return nil }
        let size = attributes[.size] as? Int ?? 0
        guard size < sizeLimit else { return nil }
        let modified = attributes[.modificationDate] as? Date

        if let cached, cached.size == size, cached.modified == modified {
            lock.lock()
            cache[url.path]?.checked = now
            lock.unlock()
            return cached.text
        }

        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        lock.lock()
        if cache[url.path] == nil { order.append(url.path) }
        cache[url.path] = Entry(modified: modified, size: size, text: text, checked: now)
        while order.count > 40 {
            cache.removeValue(forKey: order.removeFirst())
        }
        lock.unlock()
        return text
    }
}

/// A file diff, styled as a review surface rather than a code listing.
///
/// This is the one thing a GUI does that a terminal genuinely can't do well,
/// so it gets more structure than anything else in the transcript: a header
/// carrying the path and the +/- tally, then paired old/new gutters so you can
/// see which side a line came from.
struct FileDiffView: View {
    let file: String
    let rows: [DiffRow]
    var state: ToolState = .pending
    /// A later edit to the same file exists, so this one keeps its header and
    /// folds everything else away.
    var superseded = false

    @Environment(\.proseScale) private var scale
    @Environment(\.colorScheme) private var scheme
    @State private var highlighted: [AttributedString]?
    /// Nil until the first layout decides. A plain `false` default would show
    /// the diff for one frame before flipping to the preview, which reads as a
    /// flicker rather than as a choice.
    @State private var showingSource: Bool?
    @State private var measured: CGFloat?
    /// Whether a superseded card has been opened again.
    @State private var unfolded = false
    /// Whether this card is drawing every row it has, rather than the head.
    @State private var wholeDiff = false

    private func previewing(_ markup: String?) -> Bool {
        opensRendered(markup) && !(showingSource ?? false)
    }

    /// Nothing below the header, until you ask.
    private var folded: Bool { superseded && !unfolded }

    /// The +/− tally, counted in one pass.
    ///
    /// Two `filter`s meant two full traversals of the rows — each allocating an
    /// array of the matching rows only to take its count — on every redraw of
    /// every diff card in the transcript.
    private var tally: (added: Int, removed: Int) {
        var added = 0, removed = 0
        for row in rows {
            switch row.kind {
            case .add: added += 1
            case .del: removed += 1
            case .context: break
            }
        }
        return (added, removed)
    }

    var body: some View {
        // Read once per evaluation and handed down, rather than asked for again
        // by the header and by `opensRendered`.
        let markup = written
        return VStack(alignment: .leading, spacing: 0) {
            header(markup)
            if folded {
                EmptyView()
            } else {
            Divider().overlay(Theme.rule)
            if previewing(markup), let markup {
                WebPreview(source: .html(markup), fitting: Self.previewCap) { measured = $0 }
                    .frame(height: min(max(measured ?? 300, 80), Self.previewCap))
            } else {
                body(for: rows)
                    // A refused change is a proposal, not a record. Dimming it
                    // says so without hiding what was going to happen. A *failed*
                    // edit is left at full strength — the agent tried, so what it
                    // tried is worth reading.
                    .opacity(state.isDeclined ? 0.45 : 1)
            }
            }
        }
        .modifier(InsetSurface())
        .animation(Motion.disclose, value: unfolded)
        .task(id: "\(scheme)\u{1}\(file)\u{1}\(rows.count)") {
            let joined = rows.map(\.text).joined(separator: "\n")
            highlighted = await SyntaxHighlighter.shared.lines(
                code: joined,
                language: SyntaxHighlighter.language(forPath: file),
                dark: scheme == .dark)
        }
    }

    /// Renderable markup opens *rendered*, exactly as an inline artifact does.
    ///
    /// A written page arrived as 410 lines of green diff, which is the appendix
    /// where the answer should be — and the same 410 lines an inline block would
    /// have shown as a floor plan. Where the markup came from is a fact about
    /// the agent, not about what you asked for, so it shouldn't change what you
    /// get to look at. Source is one click away either way.
    ///
    /// Only for a change that *landed*: a declined or failed edit has no file
    /// behind it to render, and rendering the previous contents would be a
    /// quiet lie about what just happened.
    /// A superseded card never previews, even opened: the newest card and the
    /// browser panel are both already showing the file as it is now, and a
    /// third copy of it is what this whole change is trying to stop.
    private func opensRendered(_ markup: String?) -> Bool {
        // `written` already carries the renderable / applied / superseded
        // guards, so markup being present is the whole test.
        markup != nil
    }

    /// Same cap as the inline card, so an artifact is the same size whichever
    /// way it reached the transcript.
    private static let previewCap: CGFloat = 460

    /// The file's own extension, for anything that renders.
    private var language: String {
        (file as NSString).pathExtension.lowercased()
    }

    private var renderable: Bool { CodeBlock.isRenderable(language) }

    /// The file as it is now.
    ///
    /// Read from disk rather than reassembled from the diff rows: the rows are
    /// only the change, and for anything but a brand-new file that would be a
    /// fragment of a page rather than a page. Nil when the file has since been
    /// moved or deleted, which correctly hides the buttons.
    ///
    /// "Cheap enough to do inline" was the old note here and it wasn't true. A
    /// body evaluation reached this three times — the preview branch, the
    /// header, and `opensRendered` — and body runs on every transcript redraw,
    /// which during streaming is up to sixty a second. That was a synchronous
    /// full-file read on the main thread per applied card per frame, in a file
    /// whose own transcript filter warns that touching the disk in a hot path
    /// is how the transcript starts stuttering.
    ///
    /// Two guards now. Nothing that can't render one asks at all, and what's
    /// left goes through a content cache validated by modification date and
    /// size — so a repeat evaluation costs a `stat` rather than a read.
    private var written: String? {
        guard renderable, state.isApplied, !superseded else { return nil }
        return WrittenFile.contents(FileActions.resolve(file))
    }

    private func header(_ markup: String?) -> some View {
        HStack(spacing: 7) {
            if superseded {
                Image(systemName: unfolded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.quaternary)
                    .frame(width: 8)
            }
            Image(systemName: state.isDeclined ? "slash.circle"
                  : state.isFailed ? "exclamationmark.triangle" : "doc.text")
                .font(.system(size: 10.5))
                .foregroundStyle(state.isDeclined || state.isFailed
                                 ? AnyShapeStyle(Color.diffDelText) : AnyShapeStyle(.tertiary))
            Text(file)
                .font(Theme.monoSmall)
                .lineLimit(1)
                .truncationMode(.head)
                .foregroundStyle(.secondary)
                .strikethrough(state.isDeclined, color: .secondary)

            Spacer(minLength: 8)

            // A page the agent just wrote is an artifact, whether it arrived
            // inline or as a file on disk.
            //
            // Which of those you get is the agent's choice, not yours: Claude
            // tends to put HTML in a fenced block, Kimi writes it out and tells
            // you the path. Only the first was previewable, so the same request
            // gave you a rendered floor plan on one account and a file path on
            // another. Reading the file back gives the written kind the same
            // controls — preview, expand, panel — from the one thing both
            // agents leave behind.
            if let markup {
                // The same switch the inline card carries, in the same place:
                // half the time the markup *is* what you wanted to look at.
                Picker("", selection: Binding(get: { !previewing(markup) },
                                              set: { showingSource = $0 })) {
                    Text("Source").tag(true)
                    Text("Preview").tag(false)
                }
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .labelsHidden()
                .fixedSize()

                ArtifactButtons(artifact: Artifact(language: language, markup: markup))
            }

            // Showing a change to a file and offering no way to look at the
            // file left you copying the path out to a terminal — the exact
            // errand this app exists to remove.
            //
            // Shown always, not on hover. These sit in a row that already has
            // two permanent buttons next to them, so revealing them on hover
            // didn't hide anything — it shifted the ones already there
            // sideways every time the pointer crossed the card, and made a
            // control you can't see until you go looking for it out of a
            // control that was already paid for in space.
            FileActionButtons(url: FileActions.resolve(file), style: .bare)

            if state.isDeclined || state.isFailed {
                Text(state.isDeclined ? "Declined" : "Failed")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.diffDelText)
                    .help(state.message ?? "")
            } else {
                // Tally reads as one unit, so the counts sit tight together.
                let tally = tally
                HStack(spacing: 6) {
                    if tally.added > 0 {
                        Text("+\(tally.added)").foregroundStyle(Color.diffAddText)
                    }
                    if tally.removed > 0 {
                        Text("−\(tally.removed)").foregroundStyle(Color.diffDelText)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture { if superseded { unfolded.toggle() } }
        .help(superseded ? "An earlier edit to this file — click to see what changed" : "")
    }

    /// How many rows a card draws before it stops and offers the rest.
    ///
    /// This is the transcript's single biggest source of views, and the reason
    /// every mode but Summary scrolled badly. Summary hides ordinary diffs
    /// outright, so it never pays for them; the other three drew every row of
    /// every edit in the conversation, and each row is four `Text`s with
    /// selection enabled on the one that matters. A session with forty edits
    /// averaging a hundred rows is sixteen thousand text views standing in an
    /// eager stack — all built, all measured, all hit-tested as the pointer
    /// crosses them. That is the lag, and it is linear in how much the agent has
    /// edited rather than in anything on screen.
    ///
    /// Eighty is about two screens of diff: enough that the overwhelming
    /// majority of edits are shown whole and nothing changes for them, and the
    /// ones that aren't are the ones nobody reads line by line in a chat
    /// transcript anyway. The rest is one click away, and it's the card you
    /// clicked that pays for it rather than all forty at once.
    private static let rowCap = 80

    private func body(for rows: [DiffRow]) -> some View {
        // Drawn by index rather than by enumerating into an array, because the
        // highlighted line for a row is found by position — looking that
        // position up with `firstIndex(where:)` per row made rendering a
        // 400-line diff a quadratic scan on every redraw — and because a range
        // needs no allocation to iterate, where `Array(rows.enumerated())` built
        // and threw away a parallel array of every row each time.
        let limit = wholeDiff ? rows.count : min(rows.count, Self.rowCap)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<limit, id: \.self) { index in
                line(rows[index], at: index)
            }
            if limit < rows.count { more(rows.count - limit) }
        }
        .padding(.vertical, 5)
    }

    private func line(_ row: DiffRow, at index: Int) -> some View {
        // firstTextBaseline, not centre: a line that wraps to four
        // visual rows would otherwise float its number against the
        // middle of the block, and the gutter stops meaning anything.
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            gutter(row.old)
            gutter(row.new)
            Text(sign(row.kind))
                .font(Theme.monoSmall)
                .foregroundStyle(.tertiary)
                .frame(width: 14)
            text(for: row, at: index)
                .font(.system(size: 12 * scale, design: .monospaced))
                .foregroundStyle(row.kind == .context ? .secondary : .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 10)
        }
        .padding(.vertical, 1.5)
        .background(background(row.kind))
    }

    /// The line that says what isn't being shown.
    ///
    /// It says how many, because "…" in the middle of a diff is indistinguishable
    /// from the gap the context trimmer already leaves between hunks — and those
    /// two mean very different things about what you're looking at.
    private func more(_ hidden: Int) -> some View {
        Button {
            wholeDiff = true
        } label: {
            Text("Show \(hidden) more line\(hidden == 1 ? "" : "s")")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Highlighted where possible.
    ///
    /// Code blocks got 192 languages and diffs kept plain grey, which is
    /// backwards — a diff is where code is read most carefully. Rows are
    /// highlighted together rather than one at a time so a string or a comment
    /// spanning lines is still understood as one.
    private func text(for row: DiffRow, at index: Int) -> Text {
        guard let highlighted,
              highlighted.indices.contains(index),
              !highlighted[index].characters.isEmpty else {
            return Text(row.text.isEmpty ? " " : row.text)
        }
        return Text(highlighted[index])
    }

    private func gutter(_ number: Int?) -> some View {
        Text(number.map(String.init) ?? "")
            .font(.system(size: 10.5, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(.quaternary)
            .frame(width: 30, alignment: .trailing)
            .padding(.trailing, 6)
    }

    private func sign(_ kind: DiffRow.Kind) -> String {
        switch kind {
        case .add: return "+"
        case .del: return "−"
        case .context: return " "
        }
    }

    private func background(_ kind: DiffRow.Kind) -> Color {
        switch kind {
        case .add: return .diffAddFill
        case .del: return .diffDelFill
        case .context: return .clear
        }
    }
}

// Diff colours now live in Theme.swift, derived from the system palette so
// they track appearance changes instead of being hand-mixed constants.
