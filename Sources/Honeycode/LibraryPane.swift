import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

/// The Academia DLC's half of the sidebar, and the surface beside it.
///
/// The pane a `SidebarMode` puts on screen replaces the session columns
/// entirely, which is what makes this the shape a DLC wanted: in Library mode
/// there is no header bar with a branch on it, no Changes tab, no dev server
/// and no terminal, because none of those are in this view. Nothing had to be
/// hidden. A paper is not a repository, and the way to say so was to give it
/// its own pane rather than to teach the coding chrome about papers.
///
/// What is here instead is a document, the marks on it, and one conversation
/// floating over it.

// MARK: - The list

/// Papers, not sessions.
struct LibrarySidebar: View {
    @ObservedObject var library: LibraryStore

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $library.selection) {
                section("Reading", library.papers.filter { $0.kind == .reading })
                section("Writing", library.papers.filter { $0.kind == .writing })
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .onAppear { library.reload() }

            if library.papers.isEmpty { empty }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ papers: [Paper]) -> some View {
        if !papers.isEmpty {
            Section(title) {
                ForEach(papers) { paper in
                    row(paper).tag(paper.id)
                }
            }
        }
    }

    private func row(_ paper: Paper) -> some View {
        VStack(alignment: .leading, spacing: Theme.s1) {
            Text(paper.title)
                .font(Theme.sidebarRow)
                .lineLimit(2)
            if !paper.highlights.isEmpty {
                Text(paper.highlights.count == 1
                     ? "1 highlight" : "\(paper.highlights.count) highlights")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, Theme.s1)
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([paper.file])
            }
            Divider()
            // Says what it does. "Delete" here would be read as deleting the
            // PDF, which this never touches — see `Library.forget`.
            Button("Remove from Library", role: .destructive) {
                library.forget(paper.id)
            }
        }
    }

    private var empty: some View {
        VStack(spacing: Theme.s4) {
            Text("No papers yet")
                .font(Theme.rowStrong)
                .foregroundStyle(.secondary)
            Text("Add a PDF to read, or a Word document you are writing.")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Add…") { library.importFromPanel() }
                .controlSize(.small)
        }
        .padding(Theme.s6)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - The pane

struct LibraryPane: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var workspace: Workspace

    /// What the reader has handed the composer, waiting to be picked up.
    @State private var quoted: String?

    var body: some View {
        Group {
            if let paper = library.selectedPaper {
                reader(paper)
            } else {
                WorkbenchEmpty(symbol: "books.vertical",
                               title: "Nothing open",
                               blurb: "Pick a paper from the list, or add one.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
    }

    @ViewBuilder
    private func reader(_ paper: Paper) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                VStack(spacing: 0) {
                    LibraryBar(paper: paper, library: library, quoted: $quoted)
                    Divider().overlay(Theme.rule)

                    switch paper.kind {
                    case .reading:
                        PaperReader(paper: paper) { page, text in
                            let highlight = Highlight(page: page, text: text)
                            library.mark(highlight, on: paper.id)
                            quoted = Library.quote(highlight, from: paper)
                        }
                    case .writing:
                        // Not a word processor, and not pretending to be. What
                        // this app has that Word doesn't is the agent, so the
                        // document is previewed here and edited where documents
                        // like it are edited — while the same conversation is
                        // one click away and can rewrite the file on disk.
                        WritingSurface(paper: paper)
                    }
                }

                // The same card that floats over a preview, over a page. It was
                // already the window in the request — a real composer and a
                // real transcript, draggable, position remembered — and what it
                // was missing was a way for the thing underneath to hand it
                // something. That is `quoted`.
                if let session = workspace.selected {
                    MiniChat(session: session, workspace: workspace,
                             bounds: proxy.size, quoted: $quoted)
                }
            }
        }
    }
}

/// The one row of chrome a paper gets.
///
/// Everything on it is about *this document* — what it is called, what has been
/// marked in it, and handing the whole thing to the conversation. Nothing about
/// a branch, a working directory or a server, because there isn't one.
private struct LibraryBar: View {
    let paper: Paper
    @ObservedObject var library: LibraryStore
    /// The same channel the reader uses. One passage or the whole paper both
    /// arrive in the composer the same way, because from the composer's side
    /// they are the same thing: something from the document, in front of the
    /// question you are about to ask about it.
    @Binding var quoted: String?
    @State private var showingHighlights = false

    var body: some View {
        HStack(spacing: Theme.s4) {
            Text(paper.title)
                .font(Theme.rowStrong)
                .lineLimit(1)
                .truncationMode(.middle)

            if !paper.authors.isEmpty {
                Text(paper.authors)
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Theme.s4)

            if !paper.highlights.isEmpty {
                Button {
                    showingHighlights.toggle()
                } label: {
                    Text(paper.highlights.count == 1
                         ? "1 highlight" : "\(paper.highlights.count) highlights")
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(HoverCapsule())
                .popover(isPresented: $showingHighlights, arrowEdge: .bottom) {
                    HighlightList(paper: paper, library: library)
                }
            }

            if paper.kind == .writing {
                Button("Open in Word") { NSWorkspace.shared.open(paper.file) }
                    .controlSize(.small)
                    .help("Opens in whatever edits .docx on this Mac")
            }

            // The whole paper, rather than one passage: what it is, where the
            // file is, and everything marked in it, in page order. An agent
            // that can open the PDF can go and read the rest; one that can't
            // still has the parts somebody thought were worth marking, which
            // is the useful half either way.
            Button("Ask about this") {
                quoted = Library.context(for: paper) + "\n\n"
            }
            .controlSize(.small)
        }
        .padding(.horizontal, Theme.s5)
        .frame(height: Theme.headerHeight)
    }
}

/// What you marked, and the way to put any of it in front of the agent.
private struct HighlightList: View {
    let paper: Paper
    @ObservedObject var library: LibraryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PopoverHeader("Highlights")
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.s4) {
                    ForEach(paper.highlights.sorted { $0.page < $1.page }) { mark in
                        VStack(alignment: .leading, spacing: Theme.s1) {
                            Text("p\(mark.page + 1)")
                                .font(Theme.caption)
                                .foregroundStyle(.secondary)
                            Text(mark.quoted())
                                .font(Theme.row)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .contextMenu {
                            Button("Remove") { library.unmark(mark.id, on: paper.id) }
                        }
                    }
                }
                .padding(Theme.s5)
            }
        }
        .frame(width: 320, height: 360)
    }
}

// MARK: - The reading surface

/// A paper, rendered so it can be read rather than glanced at.
///
/// PDFKit, and this is the one part of Academia with no seam already in the
/// tree. `FilePreview` renders PDFs through Quick Look and `BrowserPanel`
/// through WebKit; both are right for *previewing* and both are dead ends for
/// *reading*, because neither gives you a text selection you can capture.
///
/// So there are three PDF renderers in the app now, and the rule for which one
/// runs is worth stating: Quick Look for a file chip in a transcript, WebKit for
/// a PDF that arrived over the web, PDFKit here — where selecting a passage is
/// the entire point of the surface existing.
private struct PaperReader: NSViewRepresentable {
    let paper: Paper
    /// Page index and text, straight from `PDFSelection`.
    let onMark: (Int, String) -> Void

    func makeNSView(context: Context) -> MarkingPDFView {
        let view = MarkingPDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        // The pane already draws the app's ground; PDFKit's default is a grey
        // that belongs to Preview.app and reads as a second window inside this
        // one.
        view.backgroundColor = .honeycodeCanvas
        view.onMark = onMark
        return view
    }

    func updateNSView(_ view: MarkingPDFView, context: Context) {
        view.onMark = onMark
        // Only on a real change: reloading the document throws away the scroll
        // position, which on a redraw means losing your place mid-sentence.
        guard view.document?.documentURL != paper.file else {
            view.show(paper.highlights)
            return
        }
        view.document = PDFDocument(url: paper.file)
        view.show(paper.highlights)
    }
}

/// A `PDFView` that knows what to do with a selection.
///
/// The one action is in the context menu rather than on a button that follows
/// the selection around the page. PDFKit already puts Copy and Look Up there,
/// which is where somebody who has just highlighted something goes looking, and
/// a floating control is one more thing to dismiss.
///
/// Marking is never automatic. A selection is a selection — dragging the
/// pointer is how you read a PDF as much as how you quote one — and a reader
/// that filed every drag would fill the list with accidents.
final class MarkingPDFView: PDFView {
    var onMark: ((Int, String) -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard currentSelection?.string?.isEmpty == false else { return menu }
        let item = NSMenuItem(title: "Highlight and Ask",
                              action: #selector(markSelection(_:)), keyEquivalent: "")
        item.target = self
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    @objc private func markSelection(_ sender: Any?) {
        guard let selection = currentSelection,
              let page = selection.pages.first,
              let index = page.document?.index(for: page)
        else { return }
        let text = selection.string ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onMark?(index, text)
        clearSelection()
    }

    /// Draw the marks that are already recorded.
    ///
    /// As `PDFAnnotation`s on the in-memory document, never written back to the
    /// file. The PDF is somebody's — often somebody else's, downloaded from a
    /// publisher — and a library that edited the documents it was given would
    /// be modifying files it does not own to store state it has a JSON file
    /// for. `Library.json` is the record; this is the rendering of it.
    func show(_ highlights: [Highlight]) {
        guard let document else { return }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for existing in page.annotations where existing.type == "Highlight" {
                page.removeAnnotation(existing)
            }
            for mark in highlights where mark.page == index {
                // `source`, not `text`. What is searched for has to be what is
                // on the page, and `text` is what it reads as once the
                // typesetting has been taken out of it.
                guard let found = page.document?.findString(mark.source, withOptions: [])
                        .first(where: { $0.pages.first == page })
                else { continue }
                for bounds in found.selectionsByLine().map({ $0.bounds(for: page) }) {
                    let annotation = PDFAnnotation(bounds: bounds,
                                                   forType: .highlight, withProperties: nil)
                    annotation.color = .systemYellow.withAlphaComponent(0.4)
                    page.addAnnotation(annotation)
                }
            }
        }
    }
}

/// A paper you are writing.
///
/// Quick Look, because rendering a `.docx` is somebody else's job and Quick Look
/// already does it. What this surface is for is having the document on screen
/// while the conversation about it is on top — the editing happens in Word, and
/// the agent edits the same file on disk.
private struct WritingSurface: View {
    let paper: Paper

    var body: some View {
        FilePreview(url: paper.file)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - The store

/// The library, as something a view can watch.
///
/// `Library` itself is plain functions over a JSON file, in AgentKit, with no
/// Combine in it — the engine has none and shouldn't grow some. This is the
/// same arrangement `Skills`/`SkillStore` already uses: the model is testable
/// and headless, and exactly one small object on this side publishes changes.
final class LibraryStore: ObservableObject {
    @Published private(set) var papers: [Paper] = []
    @Published var selection: Paper.ID?

    var selectedPaper: Paper? { papers.first { $0.id == selection } }

    /// Reads nothing. The list asks on appear — which is also how a paper
    /// added to the JSON from outside the app turns up without a relaunch, the
    /// same stance `Skills.all()` takes and for the same reason.
    init() {}

    func reload() { papers = Library.all() }

    /// Add files, and open the first of them.
    ///
    /// Opening it is the point of having added it. A library that files
    /// something away silently is one you then have to go and find it in.
    func add(_ urls: [URL]) {
        var first: Paper?
        for url in urls {
            let paper = Library.add(url)
            if first == nil { first = paper }
        }
        reload()
        if let first { selection = first.id }
    }

    func importFromPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        // `.docx` has no `UTType` constant, and asking the system for it by
        // extension is the honest way to name a type this app does not own.
        panel.allowedContentTypes =
            [UTType.pdf] + [UTType(filenameExtension: "docx")].compactMap { $0 }
        panel.prompt = "Add"
        panel.message = "A PDF to read, or a Word document you are writing."
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    func forget(_ id: Paper.ID) {
        Library.forget(id)
        if selection == id { selection = nil }
        reload()
    }

    func mark(_ highlight: Highlight, on id: Paper.ID) {
        guard var paper = papers.first(where: { $0.id == id }) else { return }
        paper.highlights.append(highlight)
        paper.openedAt = Date()
        Library.save(paper)
        reload()
    }

    func unmark(_ highlight: Highlight.ID, on id: Paper.ID) {
        guard var paper = papers.first(where: { $0.id == id }) else { return }
        paper.highlights.removeAll { $0.id == highlight }
        Library.save(paper)
        reload()
    }
}
