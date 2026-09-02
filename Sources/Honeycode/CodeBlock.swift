import SwiftUI
import AppKit

/// Preview, expand and send-to-panel, for markup that already exists as a file.
///
/// The same three affordances an inline artifact gets, offered from a diff card.
/// Kept as its own view so the buttons and the sheet stay in one place: the
/// inline block and the written file are the same artifact in different
/// wrappers, and two copies of "expand" would drift.
struct ArtifactButtons: View {
    let artifact: Artifact

    @Environment(\.openArtifact) private var openArtifact
    @State private var expanded = false
    @State private var zoom: CGFloat = 1

    var body: some View {
        HStack(spacing: 6) {
            CodeBlock.iconButton("arrow.up.left.and.arrow.down.right", "Preview") {
                expanded = true
            }
            if let openArtifact {
                CodeBlock.iconButton("sidebar.right", "Open in the browser panel") {
                    openArtifact(artifact)
                }
            }
        }
        .sheet(isPresented: $expanded) {
            VStack(spacing: 0) {
                HStack {
                    Text(artifact.label)
                        .font(.system(size: Theme.t4, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    ZoomControl(zoom: $zoom)
                    if let openArtifact {
                        Button("Move to Panel") {
                            expanded = false
                            openArtifact(artifact)
                        }
                    }
                    Button("Done") { expanded = false }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(Theme.s5)
                Divider().overlay(Theme.rule)
                SandboxedPreview(source: .html(artifact.markup), scrolls: true,
                                 fitting: 700, zoom: zoom)
            }
            .frame(width: 1000, height: 780)
        }
    }
}

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
        _settled = State(initialValue: source)
        _lines = State(initialValue: source.components(separatedBy: "\n"))
    }

    @Environment(\.proseScale) private var scale
    @Environment(\.openArtifact) private var openArtifact
    @Environment(\.plainProse) private var plain

    private var artifact: Artifact { Artifact(language: language, markup: source) }

    @State private var copied = false
    @State private var highlighted: [AttributedString]?
    /// The plain text each highlighted line was produced from.
    ///
    /// Kept beside the attributed lines so the per-line "does this colouring
    /// still belong to this text" check is a string comparison rather than a
    /// fresh `String(…​.characters)` — which allocated one string per visible
    /// line of every code block, on every redraw.
    @State private var highlightedPlain: [String] = []
    /// The source split once per change rather than once per redraw.
    ///
    /// `components(separatedBy:)` from the body meant a four-hundred-line block
    /// was re-split — and its array of four hundred strings re-allocated — every
    /// time anything in the transcript moved, including for the blocks that
    /// hadn't changed at all.
    @State private var lines: [String]
    /// The source the preview is showing, which lags the live one by the same
    /// settle the highlighter waits out.
    ///
    /// `WebPreview` reloads whenever its source changes, and an `html` fence
    /// opens rendered — so a streaming page was re-running `loadHTMLString`,
    /// a full parse, layout and the JS height probe on every delta. Nobody can
    /// read a page being rebuilt sixty times a second, and the intermediate
    /// states are torn markup anyway.
    @State private var settled: String
    @State private var previewing = false
    @State private var expanded = false
    @State private var measured: CGFloat?
    /// Only the expanded sheet zooms. The inline card is already fitted to the
    /// content and its header carries five controls; a sixth would make the
    /// strip above a preview busier than the preview.
    @State private var zoom: CGFloat = 1
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

    private var gutterWidth: CGFloat {
        // Size the gutter to the widest number so the code column doesn't shift
        // between a 9-line and a 100-line block.
        CGFloat(String(max(lines.count, 1)).count) * 7 * scale + 12
    }

    var body: some View {
        if plain { stub } else { full }
    }

    /// What a code block becomes in the floating chat: one line saying what
    /// went past.
    ///
    /// Not hidden outright. "I wrote you 400 lines of HTML" and "I wrote you
    /// nothing" have to look different, and a reply that silently drops its
    /// central block reads as a bug in the app rather than a choice about
    /// space.
    private var stub: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 9.5))
            Text(language.isEmpty ? "code" : language.lowercased())
                .font(Theme.captionStrong)
            Text("·")
            Text("\(lines.count) line\(lines.count == 1 ? "" : "s")")
                .font(Theme.caption)
                .monospacedDigit()
        }
        .foregroundStyle(.tertiary)
        .padding(.horizontal, Theme.s4)
        .padding(.vertical, Theme.s2)
        .overlay(Capsule().strokeBorder(Theme.rule, lineWidth: 1))
    }

    private var full: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.rule)
            if previewing {
                SandboxedPreview(source: .html(settled), fitting: Self.previewCap) { measured = $0 }
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
                        .font(.system(size: Theme.t4, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    ZoomControl(zoom: $zoom)
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
                SandboxedPreview(source: .html(source), scrolls: true, fitting: 700, zoom: zoom)
            }
            .frame(width: 1000, height: 780)
        }
        // Re-split on the source changing, not on the view being redrawn.
        .onChange(of: source) { _, new in
            lines = new.components(separatedBy: "\n")
        }
        .task(id: highlightKey) {
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            settled = source
            // `await`, and the work happens on the highlighter's own queue. It
            // used to run here, which is the main actor, so a 20k block put a
            // JavaScriptCore parse in the middle of a streaming frame.
            let result = await SyntaxHighlighter.shared.lines(
                code: source, language: language, dark: scheme == .dark)
            guard !Task.isCancelled else { return }
            highlighted = result
            highlightedPlain = result?.map { String($0.characters) } ?? []
        }
    }

    /// What the highlight is keyed on.
    ///
    /// This used to be `"\(scheme)\u{1}\(language)\u{1}\(source)"`, which
    /// interpolated the entire source into a fresh string on every body
    /// evaluation purely to decide whether anything had changed — hundreds of
    /// kilobytes copied per frame, per visible block, to answer a question a
    /// hash answers.
    private struct HighlightKey: Equatable {
        let dark: Bool
        let language: String
        let length: Int
        let digest: Int
    }

    private var highlightKey: HighlightKey {
        HighlightKey(dark: scheme == .dark, language: language,
                     length: source.utf8.count, digest: source.hashValue)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            Text(language.isEmpty ? "text" : language)
                .font(Theme.captionStrong)
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
                        .font(Theme.captionStrong)
                }
                .foregroundStyle(copied ? AnyShapeStyle(Color.diffAddText)
                                        : AnyShapeStyle(.tertiary))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .animation(Motion.reveal, value: copied)
        }
        .padding(.horizontal, Theme.s5)
        .padding(.vertical, 6)
    }

    private var code: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                // Same reason as the diff gutter: wrapped lines must keep
                // their number aligned to the first visual row.
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    // `String(...)`, the way the diff gutter three files over
                    // already does it. Interpolated into a `Text` this is a
                    // `LocalizedStringKey`, which group-separates: line 1000 of
                    // a long file drew as "1,000", in a gutter sized for four
                    // characters, so it truncated as well as lying.
                    Text(String(index + 1))
                        .font(.system(size: Theme.t1 * scale, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .frame(width: gutterWidth, alignment: .trailing)
                        .padding(.trailing, 8)
                    text(for: line, at: index)
                        .font(.system(size: Theme.t3 * scale, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, Theme.s5)
                }
                .padding(.vertical, Theme.s1)
            }
        }
        .padding(.vertical, Theme.s4)
    }

    /// Highlighted per line, for the lines the highlight still matches.
    ///
    /// This used to require the whole highlight to match the whole source —
    /// `highlighted.count == lines.count` — which is true only in the gaps
    /// between deltas. While a block streams, every new line invalidated the
    /// entire result, so all of it fell back to plain at once and then all of it
    /// came back coloured 60ms later. Thirty times a second that isn't a
    /// fallback, it's a strobe, and it's what made watching an artifact arrive
    /// in Source view unpleasant.
    ///
    /// Comparing each line to the text it was highlighted from is a stricter
    /// check than the count ever was — it's what actually prevents one line's
    /// colours landing on another's text — and it lets the lines that haven't
    /// changed keep their colour while the tail catches up. Nothing ever
    /// un-highlights; new lines simply arrive plain and colour in.
    private func text(for line: String, at index: Int) -> Text {
        if let highlighted, index < highlighted.count,
           index < highlightedPlain.count,
           !highlightedPlain[index].isEmpty,
           highlightedPlain[index] == line {
            return Text(highlighted[index])
        }
        return Text(line.isEmpty ? " " : line)
    }

    static func iconButton(_ symbol: String, _ label: String,
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
