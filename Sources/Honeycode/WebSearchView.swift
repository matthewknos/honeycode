import SwiftUI
import AppKit

/// A web search: the query while it runs, the sources once it lands.
///
/// The query is the useful part and it's shown in full — a search card that
/// says only "Searching…" tells you nothing about whether the agent understood
/// the question. Results collapse because they're reference material, not
/// something you read top to bottom.
struct WebSearchView: View {
    let query: String
    let results: [SearchResult]
    let state: ToolState

    @State private var collapsed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isRunning: Bool { if case .pending = state { return true }; return false }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !collapsed && !results.isEmpty { list }
        }
        .animation(Motion.disclose, value: collapsed)
        .animation(Motion.disclose, value: results.count)
    }

    private var header: some View {
        Button {
            guard !results.isEmpty else { return }
            withAnimation(Motion.disclose) { collapsed.toggle() }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10.5))
                    .frame(width: 13)

                if isRunning && !reduceMotion {
                    ShimmerLabel(text: "Searching “\(query)”", enabled: true)
                } else {
                    Text("\(isRunning ? "Searching" : "Searched") “\(query)”")
                        .font(Theme.label)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !results.isEmpty {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(collapsed ? -90 : 0))
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.tertiary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var list: some View {
        // A hairline rail rather than a box: these are subordinate to the
        // search above them, and a bordered card would give them equal weight.
        HStack(alignment: .top, spacing: Theme.s5) {
            RoundedRectangle(cornerRadius: 0.5)
                .fill(Theme.rule)
                .frame(width: 1)
                .padding(.leading, 6)

            VStack(alignment: .leading, spacing: Theme.s3) {
                ForEach(results) { result in
                    SourceRow(result: result)
                }
            }
        }
        .padding(.top, Theme.s4)
    }
}

private struct SourceRow: View {
    let result: SearchResult
    @State private var hovering = false

    var body: some View {
        Button {
            if let url = URL(string: result.url.hasPrefix("http")
                             ? result.url : "https://" + result.url) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(result.title)
                    .font(Theme.row)
                    .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                Text("·").foregroundStyle(.quaternary)
                Text(result.url)
                    .font(Theme.monoSmall)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(hovering ? 1 : 0)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(result.url)
    }
}
