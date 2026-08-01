import SwiftUI

/// One line of a unified diff.
struct DiffRow: Identifiable, Codable {
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

        var rows: [DiffRow] = []
        var o = 0, n = 0
        while o < oldLines.count || n < newLines.count {
            if let line = removed[o] {
                rows.append(DiffRow(old: o + 1, new: nil, kind: .del, text: line))
                o += 1
            } else if let line = inserted[n] {
                rows.append(DiffRow(old: nil, new: n + 1, kind: .add, text: line))
                n += 1
            } else if o < oldLines.count && n < newLines.count {
                rows.append(DiffRow(old: o + 1, new: n + 1, kind: .context, text: oldLines[o]))
                o += 1; n += 1
            } else {
                break
            }
        }
        return trim(rows, context: context)
    }

    /// Keep only rows within `context` of a change. Without this a two-line
    /// edit to a thousand-line file renders the whole file.
    private static func trim(_ rows: [DiffRow], context: Int) -> [DiffRow] {
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

    @Environment(\.proseScale) private var scale
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false
    @State private var highlighted: [AttributedString]?

    private var added: Int { rows.filter { $0.kind == .add }.count }
    private var removed: Int { rows.filter { $0.kind == .del }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.rule)
            body(for: rows)
                // A refused change is a proposal, not a record. Dimming it
                // says so without hiding what was going to happen. A *failed*
                // edit is left at full strength — the agent tried, so what it
                // tried is worth reading.
                .opacity(state.isRefused ? 0.45 : 1)
        }
        .modifier(InsetSurface())
        .task(id: "\(scheme)\u{1}\(file)\u{1}\(rows.count)") {
            let joined = rows.map(\.text).joined(separator: "\n")
            highlighted = SyntaxHighlighter.shared.lines(
                code: joined,
                language: SyntaxHighlighter.language(forPath: file),
                dark: scheme == .dark)
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
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
                .strikethrough(state.isRefused, color: .secondary)

            Spacer(minLength: 8)

            // Showing a change to a file and offering no way to look at the
            // file left you copying the path out to a terminal — the exact
            // errand this app exists to remove.
            if hovering {
                FileActionButtons(url: FileActions.resolve(file))
                    .transition(.opacity)
            }

            if state.isDeclined || state.isFailed {
                Text(state.isDeclined ? "Declined" : "Failed")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.diffDelText)
                    .help(state.message ?? "")
            } else {
                // Tally reads as one unit, so the counts sit tight together.
                HStack(spacing: 6) {
                    if added > 0 {
                        Text("+\(added)").foregroundStyle(Color.diffAddText)
                    }
                    if removed > 0 {
                        Text("−\(removed)").foregroundStyle(Color.diffDelText)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .onHover { hovering = $0 }
        .animation(Motion.reveal, value: hovering)
    }

    private func body(for rows: [DiffRow]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
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
                    text(for: row)
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
        }
        .padding(.vertical, 5)
    }

    /// Highlighted where possible.
    ///
    /// Code blocks got 192 languages and diffs kept plain grey, which is
    /// backwards — a diff is where code is read most carefully. Rows are
    /// highlighted together rather than one at a time so a string or a comment
    /// spanning lines is still understood as one.
    private func text(for row: DiffRow) -> Text {
        guard let highlighted,
              let index = rows.firstIndex(where: { $0.id == row.id }),
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
