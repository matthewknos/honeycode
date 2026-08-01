import SwiftUI
import AppKit

/// A fenced code block: language label, copy button, numbered lines.
///
/// The copy affordance matters more here than in a web page — you can't select
/// a terminal's output cleanly, and lifting a snippet out of an agent's reply
/// is one of the most common things you do with one.
struct CodeBlock: View {
    let language: String
    let source: String

    /// Renderable markup opens *rendered*.
    ///
    /// Source-first was the cautious default and it's the wrong one: when an
    /// agent hands you a dashboard, the dashboard is the answer and the markup
    /// is the appendix. The toggle is still one click away either way.
    init(language: String, source: String) {
        self.language = language
        self.source = source
        _previewing = State(initialValue: Self.isRenderable(language))
    }

    @Environment(\.proseScale) private var scale
    @Environment(\.openArtifact) private var openArtifact

    private var artifact: Artifact { Artifact(language: language, markup: source) }

    @State private var copied = false
    @State private var highlighted: [AttributedString]?
    @State private var previewing = false
    @State private var expanded = false
    @State private var measured: CGFloat?
    @Environment(\.colorScheme) private var scheme

    /// Markup with something to show. A `swift` fence obviously has none.
    static func isRenderable(_ language: String) -> Bool {
        ["html", "svg", "xml"].contains(language.lowercased())
    }

    private var renderable: Bool { Self.isRenderable(language) }

    /// Capped, but never taller than the content needs.
    private var previewHeight: CGFloat { min(max(measured ?? 260, 80), Self.previewCap) }

    /// Generous, because most artifacts are a page rather than a banner.
    private static let previewCap: CGFloat = 460

    private var lines: [String] { source.components(separatedBy: "\n") }
    private var gutterWidth: CGFloat {
        // Size the gutter to the widest number so the code column doesn't shift
        // between a 9-line and a 100-line block.
        CGFloat(String(max(lines.count, 1)).count) * 7 * scale + 12
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.rule)
            if previewing {
                WebPreview(source: .html(source), fitting: Self.previewCap) { measured = $0 }
                    .frame(height: previewHeight)
            } else {
                code
            }
        }
        .modifier(InsetSurface())
        // Keyed on the content *and* the appearance, so both a new delta and a
        // light/dark flip re-run it. The 60ms pause is the important part: a
        // streaming block changes on every token, and `task(id:)` cancels the
        // previous run, so only text that settles ever gets highlighted.
        .sheet(isPresented: $expanded) {
            VStack(spacing: 0) {
                HStack {
                    Text(language.isEmpty ? "Artifact" : language)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let openArtifact {
                        Button("Move to Panel") {
                            expanded = false
                            openArtifact(artifact)
                        }
                    }
                    Button("Open in Browser") { openExternally() }
                    Button("Done") { expanded = false }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(Theme.s5)
                Divider().overlay(Theme.rule)
                // Fitted here too. Expanding to a window you then have to
                // scroll defeats the point — you expanded it to see the whole
                // thing. Scrolling stays enabled as the fallback for a page so
                // long it hits the zoom floor.
                WebPreview(source: .html(source), scrolls: true, fitting: 700)
            }
            .frame(width: 1000, height: 780)
        }
        .task(id: "\(scheme)\u{1}\(language)\u{1}\(source)") {
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            highlighted = SyntaxHighlighter.shared.lines(
                code: source, language: language, dark: scheme == .dark)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 9.5))
                .foregroundStyle(.quaternary)
            Text(language.isEmpty ? "text" : language)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.tertiary)

            Spacer(minLength: 8)

            if renderable {
                // A switch, not a replacement: the source stays one click away,
                // because half the time the markup *is* the answer.
                Picker("", selection: $previewing) {
                    Text("Source").tag(false)
                    Text("Preview").tag(true)
                }
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .labelsHidden()
                .fixedSize()

                if previewing {
                    iconButton("arrow.up.left.and.arrow.down.right", "Expand") {
                        expanded = true
                    }
                    // The one that keeps you in the loop: the artifact goes to
                    // the panel beside the conversation, where you can click
                    // around it and ask for changes without closing anything.
                    // The sheet and the external browser both make you leave.
                    if let openArtifact {
                        iconButton("sidebar.right", "Open in the browser panel") {
                            openArtifact(artifact)
                        }
                    }
                    iconButton("safari", "Open in browser") { openExternally() }
                }
            }

            Button(action: copy) {
                HStack(spacing: 4) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 9, weight: .semibold))
                    Text(copied ? "Copied" : "Copy")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .foregroundStyle(copied ? AnyShapeStyle(Color.diffAddText)
                                        : AnyShapeStyle(.tertiary))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .animation(Motion.reveal, value: copied)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
    }

    private var code: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                // Same reason as the diff gutter: wrapped lines must keep
                // their number aligned to the first visual row.
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("\(index + 1)")
                        .font(.system(size: 10.5 * scale, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.quaternary)
                        .frame(width: gutterWidth, alignment: .trailing)
                        .padding(.trailing, 8)
                    text(for: line, at: index)
                        .font(.system(size: 12 * scale, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, 10)
                }
                .padding(.vertical, 1)
            }
        }
        .padding(.vertical, 7)
    }

    /// Highlighted when it's ready and still matches the source, plain
    /// otherwise. The count check matters: a stale result from the previous
    /// delta would otherwise paint one line's colours onto another's text.
    private func text(for line: String, at index: Int) -> Text {
        if let highlighted, highlighted.count == lines.count,
           !highlighted[index].characters.isEmpty {
            return Text(highlighted[index])
        }
        return Text(line.isEmpty ? " " : line)
    }

    private func iconButton(_ symbol: String, _ label: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.tertiary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
    }

    /// Written out before opening, because there's no file behind an inline
    /// artifact — and the browser gets the real thing rather than the
    /// sandboxed rendering, which is the point of asking for it.
    private func openExternally() {
        guard let url = artifact.write() else { return }
        NSWorkspace.shared.open(url)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(source, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}
