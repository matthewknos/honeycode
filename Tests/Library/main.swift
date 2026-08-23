// The library model, with no renderer anywhere near it.
//
// The point of putting `Paper` and `Highlight` in AgentKit is that everything
// interesting about them is answerable without PDFKit — what a selection reads
// as once the typesetting is taken out of it, which page a mark is on, what an
// agent is handed when you ask about a paper. `build.sh` and `test.sh` both
// refuse the build if AgentKit imports PDFKit, and this suite is what that
// guard is protecting: a model you can check in a second, on any machine, with
// no window open.
//
// Nothing here touches the real library or the real preferences. The round trip
// goes through a file in the temporary directory, and the bundle switch through
// a scratch preferences domain — for the same reason the setup suite uses one: a
// test that proved the library works by emptying yours would be a poor trade.

import Foundation

var failures = 0
func check(_ label: String, _ ok: Bool) {
    print((ok ? "  ok   " : "  FAIL ") + label)
    if !ok { failures += 1 }
}

// --- what a PDF selection reads as ---
//
// A PDF has no lines of prose; it has glyphs at coordinates, written out line
// by line as they were typeset. Everything below is that fact showing up in a
// string somebody is about to have quoted back at them.

check("a line break inside a sentence is a space",
      Highlight.tidy("the quick brown\nfox") == "the quick brown fox")
check("a word hyphenated across a line is put back together",
      Highlight.tidy("hyphen-\nated") == "hyphenated")
check("and so is one broken with a soft hyphen",
      Highlight.tidy("soft\u{00AD}\nbreak") == "softbreak")
check("a real hyphen inside a line survives",
      Highlight.tidy("well-known result") == "well-known result")
check("runs of whitespace collapse",
      Highlight.tidy("  spaced   out \n\n  words ") == "spaced out words")
check("CRLF is a line break like any other",
      Highlight.tidy("one\r\ntwo") == "one two")

// The tidy happens on the way in, so nothing downstream has to remember to —
// and the untidied string is kept, because it is the only one that will ever
// match the page again when the mark has to be drawn back onto it.
let broken = Highlight(page: 0, text: "across a\ncolumn")
check("a highlight is tidied when it is made", broken.text == "across a column")
check("and keeps what was actually on the page", broken.source == "across a\ncolumn")

// --- what a paper is called before anybody names it ---

let downloaded = URL(fileURLWithPath: "/tmp/Attention_Is-All_You_Need.pdf")
check("a downloaded paper is named after its file, with the spaces put back",
      Paper.imported(downloaded).title == "Attention Is All You Need")
check("an untitled file still gets a title",
      !Paper.imported(URL(fileURLWithPath: "/tmp/x.pdf")).title.isEmpty)

// --- reading and writing are the same shelf, told apart by the file ---

check("a PDF is something you read",
      Paper.Kind.of(URL(fileURLWithPath: "/tmp/a.pdf")) == .reading)
check("a Word document is something you write",
      Paper.Kind.of(URL(fileURLWithPath: "/tmp/a.docx")) == .writing)
check("and the extension is matched however it was typed",
      Paper.Kind.of(URL(fileURLWithPath: "/tmp/a.DOCX")) == .writing)

// --- what an agent is handed ---
//
// The two things worth checking are that the marks arrive in page order rather
// than in the order somebody happened to make them, and that the page numbers
// are the ones printed in a reader. PDFKit counts pages from zero; every human
// being counts from one, and a message that says p0 is a message that sends
// somebody to the wrong page.

// Whole seconds, deliberately. These dates are written out as ISO-8601, which
// carries no sub-second component — so a `Date()` here would come back from the
// round trip below a few hundred microseconds different from the one that went
// in, and the equality check would fail for a reason that has nothing to do
// with the library.
let noon = Date(timeIntervalSince1970: 1_700_000_000)

var paper = Paper(title: "On Widgets",
                  authors: "Ada Lovelace",
                  year: 1843,
                  file: URL(fileURLWithPath: "/tmp/widgets.pdf"),
                  addedAt: noon)
paper.highlights = [
    Highlight(page: 4, text: "the later claim", madeAt: noon),
    Highlight(page: 1, text: "the earlier claim", note: "check this", madeAt: noon),
]
let context = Library.context(for: paper)

check("the context names the paper", context.contains("On Widgets"))
check("and its authors and year", context.contains("Ada Lovelace") && context.contains("1843"))
check("and where the file is, so an agent that can read it can",
      context.contains("/tmp/widgets.pdf"))
check("page numbers are the ones a reader shows", context.contains("p2:") && context.contains("p5:"))
check("never the zero-based index PDFKit uses", !context.contains("p0:") && !context.contains("p1:"))
check("marks are in page order, not the order they were made",
      (context.range(of: "p2:")?.lowerBound ?? context.endIndex)
          < (context.range(of: "p5:")?.lowerBound ?? context.startIndex))
check("a note on a passage comes with it", context.contains("check this"))

let bare = Paper(title: "Nothing Marked",
                 file: URL(fileURLWithPath: "/tmp/bare.pdf"), addedAt: noon)
check("a paper with no marks says nothing about marks",
      !Library.context(for: bare).contains("highlighted"))

// --- one passage, as the thing you just asked about ---

let quote = Library.quote(Highlight(page: 2, text: "a passage"), from: paper)
check("a quote is a blockquote", quote.hasPrefix("> a passage"))
check("and says which paper and page it came from",
      quote.contains("On Widgets") && quote.contains("p3"))
check("and ends with room to type after it", quote.hasSuffix("\n\n"))

// --- a long mark is shortened for a list, not for the message ---

let long = Highlight(page: 0, text: String(repeating: "word ", count: 200), madeAt: noon)
check("a list entry is trimmed", long.quoted(limit: 40).count <= 41)
check("with an ellipsis so it reads as trimmed", long.quoted(limit: 40).hasSuffix("…"))
check("but the passage itself is whole", long.text.count > 400)

// --- the shelf on disk ---

let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("honeycode-library-tests-\(ProcessInfo.processInfo.processIdentifier)")
try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scratch) }

// `Library.file` reads `Support.folder`, which is the real one. Rather than
// making that settable for a test — a seam in shipping code that exists only
// for the test is a cost the shipping code pays forever — the round trip is
// checked against the same encoder through a file of our own.
let store = scratch.appendingPathComponent("Library.json")
let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601
let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601

do {
    try encoder.encode([paper, bare]).write(to: store)
    let read = try decoder.decode([Paper].self, from: Data(contentsOf: store))
    check("a library survives being written and read back", read == [paper, bare])
    check("with its marks", read.first?.highlights.count == 2)
} catch {
    check("a library survives being written and read back — \(error)", false)
}

// --- the bundle switch ---
//
// The one thing about `DLC` that differs from `Feature` and would be easy to
// get wrong: an unset feature means an install that predates the switches and
// stays on, and an unset DLC means nobody ever asked for it.

let domain = "com.matthewquigley.honeycode.tests.library"
let preferences = UserDefaults(suiteName: domain)!
preferences.removePersistentDomain(forName: domain)
Setup.store = preferences
defer { preferences.removePersistentDomain(forName: domain) }

check("a bundle nobody has asked for is off", !DLCs.isOn(.academia))
check("which is not what an unset feature means", Features.isOn(.crew))

Setup.prepare(returning: false)
check("a fresh install decides every bundle", DLC.allCases.allSatisfy {
    preferences.object(forKey: Setup.dlcKey($0)) != nil
})
check("and decides them off", !DLCs.isOn(.academia))

// The key directly rather than `DLCs.set`, which also installs the DLC's skills
// — into the real `Skills.folder`, which is not this suite's to write into.
Setup.store.set(true, forKey: Setup.dlcKey(.academia))
check("switching one on is all it takes to read as on", DLCs.isOn(.academia))

check("Academia brings skills with it, because that is the one instruction "
      + "channel all four accounts share", !DLC.academia.skills.isEmpty)
check("and each of them has a slug an agent can be pointed at",
      DLC.academia.skills.allSatisfy { !$0.slug.isEmpty && !$0.body.isEmpty })

print(failures == 0 ? "Library: ok" : "Library: \(failures) failed")
exit(failures == 0 ? 0 : 1)
