import Foundation

// MARK: - What Academia keeps

/// One document in the library, and what you have marked in it.
///
/// Deliberately not a wrapper around a `PDFDocument`. The model is in AgentKit,
/// which cannot import PDFKit — `build.sh` fails the build if it tries, and
/// PDFKit is on that list for the same reason SwiftUI is: `honeycoded` links
/// this half and a daemon has no windows. So a paper is a path, some facts
/// about it, and the marks you made, all of which are answerable without a
/// renderer and all of which are therefore testable.
///
/// The page numbers here are PDFKit's — zero-based indices into the document,
/// not the numbers printed on the paper. Those two disagree in almost every
/// published article, and the one this app can be sure of is the index. What is
/// shown to a person, and what is handed to an agent, adds one.
struct Paper: Identifiable, Codable, Equatable, Sendable {

    /// What you do with it, decided by the file rather than by a switch.
    ///
    /// Reading and writing are the same shelf on purpose: the paper you are
    /// citing and the paper you are writing are the same project, and a library
    /// that could only hold one of them would send you somewhere else for the
    /// other. What differs is the surface — a PDF is read in the window, a Word
    /// document is opened in the program that edits Word documents.
    enum Kind: String, Codable, Sendable {
        case reading
        case writing

        /// `.docx` is writing, everything else is reading.
        ///
        /// Word rather than Markdown because this is the format that leaves the
        /// building: journals take it, co-authors comment in it, and a tool
        /// that produced something else would be a tool you export out of at
        /// the exact moment the work gets shared.
        static func of(_ file: URL) -> Kind {
            ["docx", "doc", "dotx"].contains(file.pathExtension.lowercased())
                ? .writing : .reading
        }
    }

    let id: UUID
    /// The paper's own title where one is known, the filename otherwise.
    var title: String
    /// Free text, because "authors" is not a structured field anybody types
    /// correctly and the library is not a citation manager.
    var authors: String
    var year: Int?
    /// Where the document is. Papers are referenced, not copied: somebody's
    /// PDFs are already somewhere they chose, and a library that moved them
    /// would break every other thing pointing at them.
    var file: URL
    var addedAt: Date
    var openedAt: Date?
    var highlights: [Highlight]
    /// Your own notes on the whole paper, as opposed to on one passage.
    var notes: String

    var kind: Kind { Kind.of(file) }

    init(id: UUID = UUID(), title: String, authors: String = "", year: Int? = nil,
         file: URL, addedAt: Date = Date(), openedAt: Date? = nil,
         highlights: [Highlight] = [], notes: String = "") {
        self.id = id
        self.title = title
        self.authors = authors
        self.year = year
        self.file = file
        self.addedAt = addedAt
        self.openedAt = openedAt
        self.highlights = highlights
        self.notes = notes
    }

    /// A new paper from a file, named after it until somebody says otherwise.
    ///
    /// The filename is a poor title and a much better one than an empty row.
    /// Underscores and hyphens become spaces because that is what a downloaded
    /// paper's filename is: a title with the spaces taken out.
    static func imported(_ file: URL, at now: Date = Date()) -> Paper {
        let stem = file.deletingPathExtension().lastPathComponent
        let spaced = stem
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return Paper(title: spaced.isEmpty ? stem : spaced, file: file, addedAt: now)
    }

    /// The marks on one page, in the order they were made.
    func highlights(onPage page: Int) -> [Highlight] {
        highlights.filter { $0.page == page }
    }
}

/// A passage you marked, and anything you said about it.
struct Highlight: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    /// Zero-based, as PDFKit counts pages. See the note on `Paper`.
    var page: Int
    /// The passage as it reads. This is what is shown, quoted and sent.
    var text: String
    /// The passage exactly as the renderer produced it — line breaks, soft
    /// hyphens and all.
    ///
    /// Kept for one job: finding the passage again in the document so the mark
    /// can be drawn on it next time the paper is opened. A search for `text`
    /// would fail on almost every mark worth making, because tidying it is
    /// precisely the act of making it no longer match the page. Never shown to
    /// anybody, and never sent to an agent.
    var source: String
    /// Your own words about this passage. Empty is the common case — most marks
    /// are "this bit", not "this bit, because".
    var note: String
    var madeAt: Date

    init(id: UUID = UUID(), page: Int, text: String,
         note: String = "", madeAt: Date = Date()) {
        self.id = id
        self.page = page
        self.source = text
        // A selection dragged across a column break arrives full of newlines
        // and soft hyphens. Nobody wants those quoted back at them, and an
        // agent handed them reads a different sentence from the one on screen.
        self.text = Highlight.tidy(text)
        self.note = note
        self.madeAt = madeAt
    }

    /// Collapse a PDF selection into the sentence it looks like on the page.
    ///
    /// Two things, both of which come from the same place — a PDF has no lines
    /// of prose, it has glyphs at coordinates, and the text layer is written
    /// line by line as they were typeset:
    ///
    /// - a word broken across a line ends in a hyphen that is not part of it;
    /// - every other line break is a line break, not a paragraph.
    static func tidy(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        // Soft hyphen, and a hard one at end of line, both rejoin the word.
        text = text.replacingOccurrences(of: "\u{00AD}\n", with: "")
        text = text.replacingOccurrences(of: "-\n", with: "")
        text = text.replacingOccurrences(of: "\n", with: " ")
        return text
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// How it reads in a list, and in a quote.
    func quoted(limit: Int = 300) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }
}

// MARK: - The shelf

/// Every paper, on disk.
///
/// One JSON file rather than a folder of them. The library is a list of
/// references and a handful of highlights per paper — small enough that
/// rewriting the whole thing on a change costs nothing, and small enough that
/// the failure mode of a folder (half of it written, the other half not) buys
/// nothing back.
///
/// It lives in Application Support, beside `Skills`, and is deliberately not
/// deleted when Academia is switched off. `Feature`'s rule is "it hides, it
/// doesn't delete"; here that rule is holding a year of somebody's reading, so
/// it is worth saying out loud.
enum Library {

    static var file: URL {
        Support.folder.appendingPathComponent("Library.json")
    }

    /// Where a paper written *here* is put, when somebody makes a new one
    /// rather than importing one they already had.
    static var folder: URL {
        Support.folder.appendingPathComponent("Papers", isDirectory: true)
    }

    /// Every paper, most recently opened first, then most recently added.
    ///
    /// Read from disk each time, like `Skills.all()` and for the same reasons:
    /// it is one small file, it is read once per redraw of a list, and a cache
    /// would need invalidating from the place somebody is most likely to change
    /// it from — which for a folder of PDFs is the Finder.
    static func all() -> [Paper] {
        guard let data = try? Data(contentsOf: file),
              let papers = try? decoder.decode([Paper].self, from: data)
        else { return [] }
        return papers.sorted {
            ($0.openedAt ?? $0.addedAt) > ($1.openedAt ?? $1.addedAt)
        }
    }

    @discardableResult
    static func save(_ papers: [Paper]) -> Bool {
        do {
            try FileManager.default.createDirectory(at: Support.folder,
                                                    withIntermediateDirectories: true)
            try encoder.encode(papers).write(to: file, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Insert or replace one paper, leaving the rest alone.
    static func save(_ paper: Paper) {
        var papers = all()
        if let index = papers.firstIndex(where: { $0.id == paper.id }) {
            papers[index] = paper
        } else {
            papers.append(paper)
        }
        save(papers)
    }

    /// Add a file to the library, or return the record it already has.
    ///
    /// Matching on the path rather than the title: the same paper imported
    /// twice is one paper, and the second import must not lose the highlights
    /// made after the first.
    @discardableResult
    static func add(_ url: URL, at now: Date = Date()) -> Paper {
        let papers = all()
        if let existing = papers.first(where: { $0.file.standardizedFileURL == url.standardizedFileURL }) {
            return existing
        }
        let paper = Paper.imported(url, at: now)
        save(paper)
        return paper
    }

    /// Forget the record. Never the document.
    ///
    /// The file was somebody's before it was the library's — it is referenced,
    /// not owned — so removing it here is removing a row, and the paper stays
    /// wherever they keep their papers.
    static func forget(_ id: Paper.ID) {
        save(all().filter { $0.id != id })
    }

    // MARK: What an agent is handed

    /// A paper, as context for a question about it.
    ///
    /// Text, not an attachment. The document itself is a PDF the agent may or
    /// may not be able to open, and the part that matters is almost never the
    /// whole of it — it is the passages somebody thought were worth marking.
    /// So the marks go in the message and the path goes with them, which lets
    /// an agent that *can* read the file go and get the rest.
    static func context(for paper: Paper) -> String {
        var lines = ["\(paper.title)"]
        if !paper.authors.isEmpty { lines.append("Authors: \(paper.authors)") }
        if let year = paper.year { lines.append("Year: \(year)") }
        lines.append("File: \(paper.file.path)")

        if !paper.notes.isEmpty {
            lines.append("")
            lines.append("My notes on it:")
            lines.append(paper.notes)
        }

        let marks = paper.highlights.sorted { ($0.page, $0.madeAt) < ($1.page, $1.madeAt) }
        if !marks.isEmpty {
            lines.append("")
            lines.append("What I highlighted, in page order:")
            lines.append(contentsOf: marks.map { mark in
                // Page numbers a person can act on: PDFKit counts from zero and
                // every reader in the world counts from one.
                let note = mark.note.isEmpty ? "" : "\n  (my note: \(mark.note))"
                return "- p\(mark.page + 1): \"\(mark.text)\"\(note)"
            })
        }
        return lines.joined(separator: "\n")
    }

    /// One passage, as the thing you just asked about.
    ///
    /// The shape a composer draft gets when you highlight something and ask.
    /// A blockquote because that is what it is, and because every one of these
    /// agents renders Markdown — the alternative was a paragraph of somebody
    /// else's prose indistinguishable from your own question.
    static func quote(_ highlight: Highlight, from paper: Paper) -> String {
        """
        > \(highlight.text)

        — \(paper.title), p\(highlight.page + 1)


        """
    }

    // MARK: Storage

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
