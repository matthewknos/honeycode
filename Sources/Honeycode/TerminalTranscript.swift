import SwiftUI
import AppKit
import Combine

/// Coding mode: the transcript as a terminal.
///
/// Not another `TranscriptMode` — those are filters over the same renderer.
/// This is a *second renderer*, and it exists because the first one has a floor
/// it can't get under. `TranscriptView` is an eager stack by necessity (a lazy
/// one mis-estimates its height and breaks the scroll to the end), each row is
/// a real view tree with parsed markdown and highlighted code in it, and every
/// delta rewrites the last element of a `@Published` array. So the cost of
/// drawing one new word is the cost of the whole conversation, sixty times a
/// second, and it gets worse the longer you talk.
///
/// A terminal has never had that problem, for one reason: it appends. There is
/// no view identity to diff, no layout above the insertion point to invalidate,
/// and no second pass to decide what a paragraph looks like. This is that —
/// one `NSTextView`, one `NSTextStorage`, and `Scrollback` deciding what's new.
/// Drawing a token costs the token.
///
/// What you give up is the machinery the cards are for: diffs you can apply
/// from, file previews, charts, artifacts, the second-opinion panel. Coding
/// mode is a view on the same session, so leaving it brings all of that back —
/// nothing here is destructive, and nothing is stored differently.
struct TerminalTranscript: NSViewRepresentable {

    /// Deliberately **not** `@ObservedObject`.
    ///
    /// The whole point is to stay out of SwiftUI's update graph: observing here
    /// would re-evaluate this view sixty times a second to hand `updateNSView`
    /// a session it already has. The coordinator subscribes to the session
    /// directly and drives the text view itself, so a streaming reply never
    /// touches the view tree at all.
    let session: Session
    var mode: TranscriptMode = .normal
    var scale: CGFloat = 1

    /// Applied to the text view as an `NSAppearance` rather than trusted to be
    /// inherited. The content pane overrides its own scheme when a background
    /// artwork demands it, and an AppKit view nested inside that reads the
    /// *window's* appearance instead — which is how you get light type on a
    /// dark ground in one pane and nowhere else.
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1, assembled by hand rather than taken from
        // `NSTextView(frame:)`, which hands back TextKit 2.
        //
        // This is the one place the older stack is the right answer:
        // `allowsNonContiguousLayout` is exactly the guarantee an append-only
        // log wants — glyphs are laid out for the viewport and nothing forces
        // the layout of the megabyte above it. TextKit 2 gets there differently
        // and mostly as well, but it has no equivalent of appending straight to
        // an `NSTextStorage` without going through a content-manager round trip.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = true
        storage.addLayoutManager(layout)

        let container = NSTextContainer(size: NSSize(width: CGFloat.zero,
                                                     height: .greatestFiniteMagnitude))
        // The one thing a terminal emulator gets for free and this doesn't:
        // a column count. `widthTracksTextView` would wrap at the pane, and a
        // pane is two thousand points wide — a hundred and eighty characters
        // to a line, which is unreadable for the same reason no one widens
        // Terminal.app to fill a display. The measure is capped in
        // `applyMeasure` instead, and the text view still spans the pane so
        // the ground is continuous.
        container.widthTracksTextView = false
        layout.addTextContainer(container)

        let textView = NSTextView(frame: .zero, textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        // Rich, despite nothing here being editable: with `isRichText` off,
        // `NSTextView` reserves the right to flatten the storage to its own
        // `font` and `textColor`, and the colours are the whole grammar.
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = .honeycodeCanvas
        textView.textContainerInset = NSSize(width: Theme.s6, height: Theme.s6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: .greatestFiniteMagnitude)
        // Selection is the whole copy story here — there's no card to hover and
        // no menu to reach for, and what lands on the clipboard is the plain
        // text you can see, which in a terminal is what you wanted anyway.
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .honeycodeCanvas
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.scrollerStyle = .overlay

        scrollView.appearance = appearance
        scrollView.contentView.postsFrameChangedNotifications = true
        context.coordinator.attach(scrollView: scrollView, textView: textView,
                                   session: session, mode: mode, scale: scale)
        return scrollView
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        // Configuration only. A delta never arrives through here.
        view.appearance = appearance
        context.coordinator.reconfigure(session: session, mode: mode, scale: scale)
    }

    private var appearance: NSAppearance? {
        NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator {

        /// How much scrollback to keep. Past this the head is dropped a chunk
        /// at a time — a session that has run all afternoon is otherwise a
        /// multi-megabyte attributed string that every layout pass carries.
        private static let cap = 600_000
        private static let trimTo = 400_000

        /// Columns. Wide enough for code and a unified diff, narrow enough to
        /// track from the end of one line to the start of the next — which is
        /// the thing a full-pane measure costs you and the reason every
        /// terminal in the world is about this wide.
        private static let columns: CGFloat = 104

        private weak var scrollView: NSScrollView?
        private weak var textView: NSTextView?
        private var session: Session?
        private var scrollback: Scrollback?
        private var feed: AnyCancellable?
        private var mode: TranscriptMode = .normal
        private var scale: CGFloat = 1
        /// A pump is already booked for the next frame.
        private var scheduled = false
        /// Items at the last pump. A transcript only ever grows — except when
        /// it doesn't: `/clear` empties it and a compaction rewrites it. Both
        /// leave the high-water marks pointing at ids that no longer exist,
        /// and the only honest answer to that is to draw it again.
        private var itemCount = 0
        /// How far the inline markdown pass has run. Always a line boundary.
        private var styledUpTo = 0
        /// Inside a fenced code block, where `**` is code and not emphasis.
        private var inFence = false
        private var resize: NSObjectProtocol?

        private var font: NSFont {
            .monospacedSystemFont(ofSize: 12 * scale, weight: .regular)
        }

        func attach(scrollView: NSScrollView, textView: NSTextView,
                    session: Session, mode: TranscriptMode, scale: CGFloat) {
            self.scrollView = scrollView
            self.textView = textView
            self.mode = mode
            self.scale = scale
            resize = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: scrollView.contentView, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.applyMeasure() }
                }
            applyMeasure()
            bind(to: session)
        }

        deinit {
            if let resize { NotificationCenter.default.removeObserver(resize) }
        }

        /// Cap the wrap width, and keep the text view itself pane-wide.
        ///
        /// Two different widths on purpose: the container decides where lines
        /// break, the view decides how far the background reaches. Tying them
        /// together is what gives you either a hundred-and-eighty-character
        /// line or a column of text floating on a stripe of window colour.
        private func applyMeasure() {
            guard let scrollView, let textView,
                  let container = textView.textContainer else { return }
            let inset = textView.textContainerInset.width * 2
            let available = max(0, scrollView.contentSize.width - inset)
            let advance = ("0" as NSString).size(withAttributes: [.font: font]).width
            container.size = NSSize(width: min(available, advance * Self.columns),
                                    height: .greatestFiniteMagnitude)
            textView.frame.size.width = scrollView.contentSize.width
        }

        /// A mode or scale change is the one thing that invalidates the whole
        /// buffer: the styles are baked into the storage, so the honest answer
        /// is to render it again from the top rather than leave the scrollback
        /// half in one voice and half in another. Everything else — a delta, a
        /// cost update, a tool landing — goes nowhere near this.
        func reconfigure(session: Session, mode: TranscriptMode, scale: CGFloat) {
            guard self.session !== session || self.mode != mode || self.scale != scale
            else { return }
            self.mode = mode
            self.scale = scale
            bind(to: session)
        }

        private func bind(to session: Session) {
            self.session = session
            self.scrollback = Scrollback(.pane(mode))
            self.itemCount = 0
            self.styledUpTo = 0
            self.inFence = false
            textView?.textStorage?.setAttributedString(NSAttributedString())

            // Straight off `objectWillChange` rather than through Combine's
            // `throttle`, which drops the trailing value often enough that the
            // last words of a reply can sit unwritten until the next one.
            // Coalescing by hand is a booked pump and a flag.
            feed = session.objectWillChange.sink { [weak self] in
                self?.schedule()
            }

            // The existing conversation, in one pass. `Scrollback` has no
            // history to catch up on, so the first drain is the whole thing.
            pump()
        }

        private func schedule() {
            guard !scheduled else { return }
            scheduled = true
            // One frame later, which is also what makes reading the session
            // safe: `objectWillChange` fires *before* the mutation lands.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0) { [weak self] in
                self?.scheduled = false
                self?.pump()
            }
        }

        private func pump() {
            guard let session, let scrollback, let textView,
                  let storage = textView.textStorage else { return }

            if session.items.count < itemCount {
                bind(to: session)
                return
            }
            itemCount = session.items.count

            let runs = scrollback.drain(items: session.items, todos: session.todos)
            guard !runs.isEmpty else { return }

            // Asked before the append, because afterwards the document is
            // taller and the answer is always "no". This is what stops a
            // streamed line yanking you back down while you're reading up.
            let following = isAtEnd

            let batch = NSMutableAttributedString()
            for run in runs {
                batch.append(NSAttributedString(string: run.text,
                                                attributes: attributes(for: run.style)))
            }

            // Where the redraw has to start. The append alone would only ever
            // dirty the tail, but `styleCompletedLines` reaches backwards and
            // rewrites lines that are already on screen — see `redraw`.
            var dirty = storage.length

            storage.beginEditing()
            storage.append(batch)
            if let restyled = styleCompletedLines(in: storage) {
                dirty = min(dirty, restyled)
            }
            dirty -= trim(storage)
            storage.endEditing()

            redraw(from: max(0, dirty), in: storage)

            if following { scrollToEnd() }
        }

        private var isAtEnd: Bool {
            guard let scrollView, let documentView = scrollView.documentView else { return true }
            let visible = scrollView.documentVisibleRect
            // A line of slack: "at the end" has to survive the line that just
            // arrived, or following switches itself off on the first delta.
            return visible.maxY >= documentView.bounds.maxY - (font.pointSize * 2)
        }

        private func scrollToEnd() {
            guard let textView, let storage = textView.textStorage else { return }
            textView.scrollRangeToVisible(NSRange(location: storage.length, length: 0))
        }

        /// Drop the head, on a line boundary.
        ///
        /// Cutting mid-line would leave a fragment at the top that reads as
        /// something the agent said, and cutting mid-attribute-run is how you
        /// get a stray red paragraph.
        /// Returns how many characters came off the front, since every offset
        /// held above this call is measured from the old start.
        @discardableResult
        private func trim(_ storage: NSTextStorage) -> Int {
            guard storage.length > Self.cap else { return 0 }
            let cut = storage.length - Self.trimTo
            let text = storage.string as NSString
            let searchable = NSRange(location: cut, length: min(4096, storage.length - cut))
            var boundary = cut
            let newline = text.range(of: "\n", options: [], range: searchable)
            if newline.location != NSNotFound { boundary = newline.location + 1 }
            storage.deleteCharacters(in: NSRange(location: 0, length: boundary))
            styledUpTo = max(0, styledUpTo - boundary)
            return boundary
        }

        /// Force the paragraph containing `location`, and everything after it,
        /// to be drawn again.
        ///
        /// Needed because of `allowsNonContiguousLayout`, and only because of
        /// it. That setting is what makes this renderer affordable — glyphs are
        /// laid out for the viewport and never for the megabyte above it — but
        /// it also means the layout manager is entitled to leave what it has
        /// already drawn exactly where it is. An append is fine: nothing above
        /// the insertion point moves. `styleCompletedLines` is not, because
        /// spending a `**` pair makes the line four characters shorter and the
        /// whole paragraph rewraps around it.
        ///
        /// What that looked like was two wrappings of one paragraph on screen
        /// at once, a few characters out of step — "but wout wortrth insth
        /// instrumenting" for "but worth instrumenting". The text was never
        /// wrong; the previous frame's glyphs simply stayed.
        ///
        /// From the paragraph start rather than the edit: a rewrap moves glyphs
        /// anywhere in the paragraph, including before the characters that
        /// changed. One paragraph per frame is not a cost worth optimising.
        private func redraw(from location: Int, in storage: NSTextStorage) {
            guard let layout = textView?.layoutManager,
                  location < storage.length else { return }
            let text = storage.string as NSString
            let paragraph = text.paragraphRange(
                for: NSRange(location: min(location, text.length - 1), length: 0))
            layout.invalidateDisplay(forCharacterRange:
                NSRange(location: paragraph.location,
                        length: storage.length - paragraph.location))
        }

        // MARK: Inline markdown

        /// Style whole lines, once, as they complete.
        ///
        /// The agent writes markdown and a terminal has no renderer, so the
        /// choice is between showing `**like this**` and doing what every
        /// terminal agent does: leave the line raw while it's being typed and
        /// resolve it the moment it ends. Per line rather than per delta is
        /// what makes it affordable — and what makes it correct, since you
        /// cannot know a `**` is emphasis until its partner arrives.
        /// Returns the earliest character it rewrote, or nil if it rewrote
        /// nothing — which is what tells `pump` how far back the redraw has to
        /// reach.
        @discardableResult
        private func styleCompletedLines(in storage: NSTextStorage) -> Int? {
            let text = storage.string as NSString
            guard styledUpTo < text.length else { return nil }

            // Whatever is still being typed waits for its newline.
            let region = NSRange(location: styledUpTo, length: text.length - styledUpTo)
            let lastBreak = text.range(of: "\n", options: .backwards, range: region)
            guard lastBreak.location != NSNotFound else { return nil }
            let end = lastBreak.location + 1

            var lines: [NSRange] = []
            var index = styledUpTo
            while index < end {
                let line = text.lineRange(for: NSRange(location: index, length: 0))
                lines.append(line)
                index = NSMaxRange(line)
            }

            // Fences are read forwards — they're state — and the styling is
            // applied backwards, so an earlier line's offsets survive a later
            // line getting shorter.
            var fenced: [Bool] = []
            for line in lines {
                let opensOrCloses = text.substring(with: line)
                    .trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```")
                fenced.append(inFence || opensOrCloses)
                if opensOrCloses { inFence.toggle() }
            }

            var shift = 0
            var earliest: Int?
            for (offset, line) in zip(lines.indices, lines).reversed() {
                guard !fenced[offset], line.length > 0,
                      storage.attribute(.honeycodeProse, at: line.location,
                                        effectiveRange: nil) != nil,
                      let styled = inlineStyled(storage.attributedSubstring(from: line))
                else { continue }
                shift += styled.length - line.length
                storage.replaceCharacters(in: line, with: styled)
                earliest = line.location
            }
            styledUpTo = end + shift
            return earliest
        }

        private static let bold = try? NSRegularExpression(pattern: "\\*\\*(.+?)\\*\\*")
        private static let code = try? NSRegularExpression(pattern: "`([^`]+)`")

        /// One line, with its markers spent rather than shown. Nil when there
        /// was nothing to spend.
        private func inlineStyled(_ line: NSAttributedString) -> NSAttributedString? {
            let raw = line.string
            let heading = raw.hasPrefix("#")
            guard heading || raw.contains("**") || raw.contains("`") else { return nil }

            let result = NSMutableAttributedString(attributedString: line)
            var changed = false

            // A heading's marker is the whole line's business, so it goes
            // first and takes the line's weight with it.
            if heading {
                let text = result.string as NSString
                var hashes = 0
                while hashes < text.length, text.character(at: hashes) == 35 { hashes += 1 }
                if hashes <= 6, hashes < text.length, text.character(at: hashes) == 32 {
                    result.deleteCharacters(in: NSRange(location: 0, length: hashes + 1))
                    result.addAttribute(.font, value: weighted(.semibold),
                                        range: NSRange(location: 0, length: result.length))
                    changed = true
                }
            }

            if let bold = Self.bold {
                changed = apply(bold, to: result) { piece, range in
                    piece.addAttribute(.font, value: self.weighted(.bold), range: range)
                } || changed
            }
            if let code = Self.code {
                changed = apply(code, to: result) { piece, range in
                    // The chip a code span gets everywhere else in the app,
                    // minus the font change — the whole pane is already mono.
                    piece.addAttribute(.backgroundColor,
                                       value: NSColor.quaternarySystemFill, range: range)
                } || changed
            }
            return changed ? result : nil
        }

        /// Replace each match with its own capture, styled. Backwards, so the
        /// ranges of the matches still ahead stay valid.
        private func apply(_ regex: NSRegularExpression, to string: NSMutableAttributedString,
                           style: (NSMutableAttributedString, NSRange) -> Void) -> Bool {
            let matches = regex.matches(in: string.string,
                                        range: NSRange(location: 0, length: string.length))
            guard !matches.isEmpty else { return false }
            for match in matches.reversed() where match.numberOfRanges > 1 {
                let piece = NSMutableAttributedString(
                    attributedString: string.attributedSubstring(from: match.range(at: 1)))
                style(piece, NSRange(location: 0, length: piece.length))
                string.replaceCharacters(in: match.range, with: piece)
            }
            return true
        }

        private func weighted(_ weight: NSFont.Weight) -> NSFont {
            .monospacedSystemFont(ofSize: 12 * scale, weight: weight)
        }

        // MARK: Palette

        /// Where a semantic style becomes something you can see.
        ///
        /// Four colours and two greys, which is all a terminal ever needed:
        /// who is talking, what was added, what was removed or broke, and
        /// everything that is machinery rather than content.
        private func attributes(for style: ScrollbackStyle) -> [NSAttributedString.Key: Any] {
            let paragraph = NSMutableParagraphStyle()
            // Wrapped continuations sit under the text, not under the marker,
            // so a wrapped tool line still reads as one line.
            paragraph.lineSpacing = 1.5 * scale
            paragraph.headIndent = font.pointSize * 1.2
            paragraph.lineBreakMode = .byWordWrapping

            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .paragraphStyle: paragraph,
                .foregroundColor: NSColor.labelColor,
            ]

            switch style {
            case .prose:
                // Marks the agent's own words for the inline pass. Everything
                // else on screen is the app's own furniture and is not
                // markdown, however many asterisks a tool name contains.
                attributes[.honeycodeProse] = true
            case .prompt:
                attributes[.foregroundColor] = accent
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: 12 * scale,
                                                                weight: .medium)
            case .speaker:
                attributes[.foregroundColor] = accent
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: 12 * scale,
                                                                weight: .semibold)
            case .activity:
                attributes[.foregroundColor] = NSColor.secondaryLabelColor
            case .detail, .notice:
                attributes[.foregroundColor] = NSColor.tertiaryLabelColor
            case .added:
                attributes[.foregroundColor] = NSColor.honeycodeDiffAdd
            case .removed:
                attributes[.foregroundColor] = NSColor.honeycodeDiffDel
            case .failure:
                attributes[.foregroundColor] = NSColor.systemRed
            }
            return attributes
        }

        private var accent: NSColor {
            switch session?.account {
            case .personal: return .systemOrange
            case .work:     return .systemBlue
            case .kimi:     return .systemPurple
            case .copilot:  return .systemGreen
            case .custom:   return session?.account.custom?.tint.nsColour ?? .labelColor
            case nil:       return .labelColor
            }
        }
    }
}

/// The one line of chrome coding mode keeps.
///
/// Everything the composer's rail used to say — which account, which model,
/// what it has cost — said once, at the top, in the type the rest of the pane
/// is set in. A terminal puts this in its title bar and has done for forty
/// years; the reason it works is that it is *one* line and it doesn't move.
struct TerminalHeader: View {
    @ObservedObject var session: Session

    var body: some View {
        HStack(spacing: 0) {
            Text(session.account.shortTitle.lowercased())
                .foregroundStyle(session.account.accent)
            Text("  ·  " + session.directory.lastPathComponent)
            Text("  ·  " + session.model.title)
            if session.costUSD > 0 {
                Text(String(format: "  ·  $%.2f", session.costUSD))
            }
            if let context = session.context, context.percent > 0 {
                Text("  ·  \(context.percent)% ctx")
            }
            Spacer(minLength: Theme.s6)
        }
        .font(Theme.monoSmall)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .padding(.horizontal, Theme.s6)
        .padding(.top, Theme.s5)
        .padding(.bottom, Theme.s3)
    }
}

extension NSAttributedString.Key {
    /// Marks a run as the agent's own prose, so the inline markdown pass can
    /// tell a reply from the app's furniture without re-deriving it from the
    /// colour it happens to be drawn in.
    static let honeycodeProse = NSAttributedString.Key("honeycodeProse")
}
