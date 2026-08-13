import SwiftUI

/// The transcript.
///
/// Deliberately **not** chat bubbles. Bubbles are a messaging idiom: they imply
/// two peers exchanging short utterances. A coding agent produces long-form
/// prose, code and tool activity, and reads far better as a document — one
/// column, ragged right, with turns separated by rhythm instead of containers.
///
/// The hierarchy is inverted from a chat app on purpose: the assistant's output
/// is the content and gets full weight, while your own prompt is set as a quiet
/// annotation. You already know what you asked.
struct TranscriptView: View {
    @ObservedObject var session: Session
    /// Set when a message is put back for editing, so the composer picks it up.
    var onEdit: (String) -> Void = { _ in }
    var mode: TranscriptMode = .normal
    var scale: CGFloat = 1
    var width: CGFloat = Theme.readingWidth
    /// Off inside the mini chat, which supplies its own card — a glass panel
    /// floating on a glass panel is one surface too many, and the top inset
    /// exists to clear a View menu that isn't there.
    var panelled = true
    /// Words only: no diffs, no tool rows, no previews, no second opinions.
    ///
    /// For the floating chat, where all of those are answers to questions the
    /// full-width preview behind it is already answering. What's left is the
    /// one thing the preview can't show you — what the agent says it did.
    var plain = false

    @EnvironmentObject private var background: BackgroundStore

    /// Whether the view is parked at the end of the transcript.
    ///
    /// This is what makes following *conditional*. Scrolling to the bottom on
    /// every change is how a transcript yanks you back down mid-read the moment
    /// a reply lands — so new content only pulls the view along when you were
    /// already at the end and clearly watching it arrive.
    /// Whether the transcript is following the end of the conversation.
    ///
    /// Tracked explicitly rather than inferred. `isPositionedByUser` turns out
    /// to be true for our *own* scrolls as well as yours, so the guard that
    /// depended on it was passing only via the "near the bottom" slack — which
    /// a streamed line fits inside and a sent message does not. That asymmetry
    /// is the whole bug: 20pt of new text stayed within tolerance, an 80pt
    /// message band and its turn gap did not.
    @State private var following = true
    /// SwiftUI's own scroll position, which knows the one thing geometry can't:
    /// whether *you* put it there.
    ///
    /// The sole driver. It was previously bound *and* the view was scrolled
    /// through a `ScrollViewReader` proxy — two mechanisms moving the same
    /// scroll view. The binding sees the proxy's scroll as an external change
    /// and flags it as user-positioned, which permanently switched following
    /// off after the very first scroll. Every subsequent fix was landing on a
    /// guard that could no longer pass.
    @State private var position = ScrollPosition(edge: .bottom)
    /// A file the prose named, opened for a look. See `FilePreview.link`.
    @State private var preview: PreviewTarget?

    /// The items this mode actually renders. Filtered once here rather than
    /// returning `EmptyView` per row, so the per-pair spacing below still sees
    /// true neighbours — otherwise hiding a run of tool calls would leave the
    /// gap they occupied behind.
    private var visible: [TranscriptItem] {
        session.items.filter { item in
            // The floating chat keeps the conversation and drops the machinery.
            if plain {
                switch item {
                case .user, .assistant, .notice, .compaction: return true
                default: return false
                }
            }
            switch item {
            // Compaction shows in every mode, Summary included: losing
            // history is not a detail.
            case .user, .assistant, .notice, .compaction, .opinion: return true
            case .thinking:                  return mode.showsReasoning
            // A rendered artifact is the answer, not the machinery that made
            // it. An agent that puts a page in a fenced block shows it in
            // Summary — it's part of the reply — so one that writes the same
            // page to a file should too. Hiding it made the same request look
            // like it had produced nothing on one account and a floor plan on
            // another, which is a difference in plumbing masquerading as a
            // difference in answer.
            //
            // Tested on the extension alone, never by reading the file: this
            // runs for every item on every redraw, and touching the disk in a
            // filter that hot is how a transcript starts stuttering while it
            // streams. A card whose file has since gone simply shows its diff.
            case .diff(_, _, let file, _, let state):
                return mode.showsActivity
                    || (state.isApplied
                        && CodeBlock.isRenderable((file as NSString).pathExtension))
            default:                         return mode.showsActivity
            }
        }
    }

    var body: some View {
        // Filtered exactly once per evaluation.
        //
        // `visible` used to be read from inside `gap(before:)` and from the
        // caret test — both called per row — so a 40-item transcript
        // filtered and allocated the array 40-odd times for every redraw, and
        // during streaming that ran thirty times a second. Quadratic work in
        // the hot path, and the single largest cause of the lag.
        let items = visible
        let stale = superseded(in: items)

        return ScrollView {
                // Eager, and it has to stay that way.
                //
                // A `LazyVStack` reports a height it has *estimated* from the
                // handful of rows it has built, and the transcript's opening
                // rows are its tallest — so the estimate runs long. Measured on
                // the foresight session: the stack claimed 14622pt against a
                // true 9215, and the scroll to the bottom therefore landed
                // 4500pt past the last row. Nothing is drawn out there, and
                // because no row exists at that offset none gets built, so the
                // estimate never corrects. That is the blank transcript, and it
                // is a deadlock rather than a race — it sat unchanged for the
                // full eight seconds the probe watched it. Scrolling up is the
                // only way out, which is exactly the workaround that was being
                // reported.
                //
                // Naming the last row instead of the edge doesn't help: an
                // id-based scroll resolves against the same estimate. Nor does
                // retrying — every retry asks for a bottom that is already
                // where the view thinks it is.
                //
                // Building every row costs real time. On the worst session here
                // — 278 items in Verbose, every tool body expanded — eager is
                // 3.8s of CPU and 530MB against lazy's 1.3s and 184MB. In
                // Summary, which is what these sessions are usually read in,
                // the difference doesn't register. A transcript that sometimes
                // shows nothing isn't worth the 2.5 seconds.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        // `.equatable()` is what makes an eager stack of a few
                        // hundred rows affordable. Without it every redraw —
                        // a streamed delta, a hover, a scroll frame — rebuilt
                        // and re-measured all of them; with it, all but the
                        // one that actually changed stop at a handful of
                        // integer and pointer comparisons. See `Row`.
                        Row(item: item,
                            todos: item.isTodos ? session.todos : [],
                            topGap: gap(before: index, in: items),
                            caret: session.isRunning && item.id == items.last?.id,
                            stale: stale.contains(item.id),
                            scale: scale,
                            mode: mode,
                            plain: plain,
                            accent: session.account.accent,
                            session: session,
                            onEdit: onEdit)
                            .equatable()
                            .id(item.id)
                    }
                    // Anchor so the last line clears the composer.
                    Color.clear.frame(height: 1)
                }
                .environment(\.proseScale, scale)
                .environment(\.plainProse, plain)
                .padding(.horizontal, rowInset)
                // Clears the View menu floating in the corner. It used to
                // overlap the first line of the transcript, which only showed
                // up once the browser panel made the column narrow enough for
                // the text to reach that far right.
                .padding(.top, panelled ? Chrome.trafficLightClearance + Theme.s6 : Theme.s5)
                // Clears the panel's own bottom inset as well as its padding,
                // or the last line sits right on the masked edge.
                .padding(.bottom, panelled ? Theme.s7 + ReadingPanel.inset : Theme.s5)
                // Cap the measure, then centre the capped column in the pane.
                // The composer caps to the same width and centres in the same
                // pane, so the two share an axis without being welded into a
                // single frame. Nothing is reserved on either side now that the
                // scroller is gone.
                .frame(maxWidth: width, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, paneInset)
                .padding(.vertical, panelled ? Theme.pane + 4 : Theme.s4)
            }
            // The panel sits behind the scroll view, not around its content —
            // see `ReadingPanel` for why that matters.
            .background { ReadingPanel(glass: panelled && background.isGlassy, width: width) }
            // Scrolling content stops where the panel does.
            //
            // The panel is inset from the scroll view, but the content wasn't —
            // so a line arriving at the top or leaving at the bottom was drawn
            // outside the glass, floating on the photograph. Masked vertically
            // only — a horizontal mask would clip the row hover buttons, which
            // sit in gutters outside the reading column.
            .mask {
                if panelled && background.isGlassy {
                    Rectangle().padding(.vertical, ReadingPanel.inset)
                } else {
                    Rectangle()
                }
            }
            .environment(\.onGlass, panelled && background.isGlassy)
            // A file path in the prose opens a preview rather than the file.
            //
            // Everything else — an http link the agent cited, a mailto — goes
            // to the system as before. Only our own scheme is claimed, so this
            // can't quietly swallow a link it doesn't understand.
            .environment(\.openURL, OpenURLAction { url in
                guard let file = FilePreview.target(of: url) else { return .systemAction }
                preview = PreviewTarget(url: file)
                return .handled
            })
            .sheet(item: $preview) { target in
                VStack(alignment: .trailing, spacing: Theme.s3) {
                    FilePreview(url: target.url)
                    Button("Done") { preview = nil }
                        .keyboardShortcut(.defaultAction)
                        .padding([.horizontal, .bottom], Theme.s5)
                }
            }
            // No scroller. The transcript is a reading surface and the bar was
            // the only hard edge on it — and with the reading column centred,
            // it sat out at the window edge with an inch of nothing between it
            // and the prose it was supposedly measuring.
            //
            // `.never`, not `.hidden`: hidden keeps the scroller in the layout
            // on a machine set to "Show scroll bars: Always", which is the
            // whole reason the composer used to reserve width to match.
            .scrollIndicators(.never)
            .scrollPosition($position)
            // Opens at the newest message rather than the top.
            //
            // With the stack built eagerly there is no estimate to be wrong
            // about, so one scroll would do. The repeats are for the things
            // that arrive *after* the first layout — a code block finishing its
            // highlight, an image decoding — each of which makes the document
            // taller under a view already parked at what used to be the end.
            .task(id: session.id) {
                if !following { following = true }
                for delay in [0, 40, 120, 300, 600] {
                    if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
                    guard !Task.isCancelled else { return }
                    position.scrollTo(edge: .bottom)
                }
            }
            // Whether to follow, decided from the offset's *direction* rather
            // than from how recently the content changed.
            //
            // The previous test asked whether anything had arrived in the last
            // 300ms and treated movement inside that window as content rather
            // than as you. That holds while prose streams in bursts and fails
            // completely while an HTML artifact streams: the block is re-laid
            // out on every delta, so the window never closes, so the branch that
            // turns following *off* was unreachable — and the view stayed welded
            // to the bottom however hard you dragged away from it. Clicking
            // Source mid-stream is the reliable way to see it, because toggling
            // a tall block re-measures the document on every frame.
            //
            // Direction doesn't have that problem, because the three things that
            // move a scroll view move it differently. Following only ever pushes
            // the offset *forwards*. Content arriving below the fold doesn't
            // move the offset at all — it moves the bottom away from it. Only
            // you ever move it backwards. So an offset that decreases is you,
            // whatever else is happening at the same moment.
            .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
                ScrollMetrics(
                    offset: geometry.contentOffset.y,
                    height: geometry.contentSize.height,
                    fromBottom: geometry.contentSize.height
                        - (geometry.contentOffset.y + geometry.containerSize.height))
            } action: { old, new in
                // Both writes are guarded on the value actually changing.
                //
                // This closure runs on every frame of every scroll, and a
                // `@State` write is an invalidation whether or not it changed
                // anything — so parking at the bottom and dragging one pixel
                // used to re-evaluate the whole transcript sixty times a
                // second, all of it to set `following` to the value it already
                // held. That cost is linear in the length of the conversation,
                // which is exactly the shape of the reported lag.
                if new.fromBottom <= Self.bottomSlack {
                    // Arriving at the end always resumes following, however you
                    // got there. Checked first so that a block *shrinking* —
                    // Preview back to Source — can't be read as a drag: the
                    // scroll view clamps the offset down to the new maximum,
                    // which is backwards movement nobody asked for.
                    if !following { following = true }
                } else if new.offset < old.offset - Self.dragSlack {
                    if following { following = false }
                }
                if new.height != old.height, following {
                    // Grew or shrank: a tool card filling in, a diff arriving, a
                    // chart laying out, an image decoding, a code block finishing
                    // its highlight. None of them change an item's text and all
                    // of them move the bottom.
                    position.scrollTo(edge: .bottom)
                }
            }
            // Keyed on the tail, not the item count: a streaming reply grows
            // the *last* item's text without adding one, so a count-only
            // trigger sat still for the whole of the longest replies.
            .onChange(of: tail) { _, _ in
                // Two attempts at this failed the same way. Geometry alone
                // can't tell the difference between "the view moved because you
                // scrolled" and "the view is relatively further from the end
                // because the agent just added a paragraph" — and new content
                // always arrives first, so the check answered "not at the
                // bottom" for the very change that should have followed.
                //
                guard following else { return }
                // No animation while text is arriving: a new 0.18s scroll
                // animation starting thirty times a second fights the previous
                // one, and the result reads as stutter rather than motion. A
                // finished turn — a new card, a tool row — still eases.
                // Never animated. An eased scroll started as a block is being
                // laid out finishes at wherever the bottom was when it began,
                // and anything arriving during it is left below the fold.
                // Streaming hid that because the next delta corrected it.
                position.scrollTo(edge: .bottom)
            }
            // A *new block* needs a second attempt.
            //
            // The change fires the moment the item is appended, which is before
            // layout has measured it — so the scroll lands on where the bottom
            // used to be and the new message sits half under the edge. Streamed
            // text hides this because another delta arrives immediately and
            // corrects it; a single sent message has nothing following it.
            //
            // Only on count, not on every delta: this would otherwise spawn a
            // task per token.
            // Sending always goes to the end. No guard, no geometry — you
            // pressed send, the message is the point, and anything that says
            // otherwise is measuring a layout that doesn't exist yet.
            .onChange(of: session.sendTick) { _, _ in
                if !following { following = true }
                Task { @MainActor in
                    for delay in [0, 30, 90, 220] {
                        if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
                        guard !Task.isCancelled else { return }
                        position.scrollTo(edge: .bottom)
                    }
                }
            }
            .onChange(of: session.items.count) { _, _ in
                guard following else { return }
                // Repeated across a few frames, because sending moves two
                // things at once: the new block has to be measured, *and* the
                // composer shrinks back to one line as the draft clears — which
                // makes the transcript taller and leaves a scroll that was
                // correct a moment ago short by the difference. A streamed
                // reply never hits this, since the composer doesn't move and
                // the next delta corrects any shortfall anyway.
                Task { @MainActor in
                    for delay in [0, 40, 140] {
                        if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
                        guard !Task.isCancelled else { return }
                        position.scrollTo(edge: .bottom)
                    }
                }
            }
    }

    private static let bottomSlack: CGFloat = 40
    /// Enough to ignore sub-pixel jitter and the settle at the end of a
    /// momentum scroll, and far below anything a hand produces on purpose.
    private static let dragSlack: CGFloat = 2


    /// What the scroll view is doing, in the two numbers that matter.
    private struct ScrollMetrics: Equatable {
        var offset: CGFloat
        var height: CGFloat
        var fromBottom: CGFloat
    }

    /// Changes whenever anything is appended *or* the final block grows.
    ///
    /// The last item's identity is folded in as well as its length: a short
    /// block replacing a longer one could otherwise land on the same number and
    /// the follow would sit out that change.
    /// Derived from the unfiltered items on purpose.
    ///
    /// `visible` is an O(n) filter that allocates, and reading it here — plus
    /// once more in the count observer below — meant three full passes per body
    /// evaluation rather than the one the body already does. The filter can only
    /// ever *remove* items, so anything that changes what's visible changes this
    /// signature too; the extra work bought nothing.
    private var tail: Int {
        let items = session.items
        var signature = items.count
        if let last = items.last {
            signature = signature &* 31 &+ last.id.hashValue
            switch last {
            case .assistant(_, let text), .notice(_, let text), .user(_, let text):
                signature = signature &* 31 &+ text.count
            case .thinking(_, let text, _, _):
                signature = signature &* 31 &+ text.count
            case .opinion(_, _, let text, _):
                signature = signature &* 31 &+ text.count
            default:
                // Everything else — tool cards, diffs, charts, web results —
                // moves the bottom by changing height rather than text, and is
                // handled by the growth watcher instead. This blind spot is
                // why following worked in Summary and not in the other modes:
                // Summary hides precisely the items that land here, so its
                // last row was always one of the cases above.
                break
            }
        }
        return signature
    }

    /// Machine chatter — tool calls, thinking, notices. Consecutive runs of
    /// these belong together as one visual cluster.
    private func isChatter(_ item: TranscriptItem) -> Bool {
        switch item {
        case .tool, .thinking, .notice, .search: return true
        default: return false
        }
    }

    private func gap(before index: Int, in items: [TranscriptItem]) -> CGFloat {
        guard index > 0 else { return 0 }
        let current = items[index]
        let previous = items[index - 1]

        // A new prompt starts a new turn — the biggest break in the document.
        if case .user = current { return (Theme.gapTurn + Theme.s3) * scale }
        // The reply to a prompt sits close under it: the band already separates
        // them, so extra air here would detach an answer from its question.
        if case .user = previous { return Theme.gapBlock * scale }
        // Runs of tool calls cluster tightly.
        if isChatter(current) && isChatter(previous) { return Theme.gapTight * scale }
        return Theme.gapBlock * scale
    }

    /// A fixed strip down each side of every row. The right one holds the
    /// handoff and edit buttons; the left is empty and exists only so the
    /// column sits centred in its panel.
    ///
    /// Overlaying the buttons on the block instead put them straight on top of
    /// the prose — on a one-line reply the button covered the last three words.
    private static let gutter: CGFloat = 26

    /// Margins either side of the reading column.
    ///
    /// A pane 700pt wide can spend 40pt a side on air and read better for it.
    /// A floating card is 400 wide, and the same margins take a fifth of the
    /// measure — which is what turned a paragraph into four words a line.
    private var paneInset: CGFloat { panelled ? Theme.pane : Theme.s4 }
    private var rowInset: CGFloat { panelled ? Theme.s6 : Theme.s3 }

    /// Every diff except the newest one for its file.
    ///
    /// Continuous editing of one document — which is now the normal way to work
    /// on an artifact — produced a column of full-height preview cards, one per
    /// edit, each showing the *same* thing: these cards render the file as it is
    /// now, not as it was, so the fifth card down was a pixel-identical copy of
    /// the first. Ten edits, ten copies of one page, and the sentence explaining
    /// each change squeezed between them.
    ///
    /// Only the latest keeps its preview. The rest keep their header — the path,
    /// the tally, and the diff on a click — because what changed *then* is still
    /// worth reading even when what it looks like now is on screen once already.
    private func superseded(in items: [TranscriptItem]) -> Set<UUID> {
        var newest: [String: UUID] = [:]
        var everything: [UUID] = []
        for item in items {
            guard case .diff(let id, _, let file, _, _) = item else { continue }
            newest[file] = id
            everything.append(id)
        }
        return Set(everything).subtracting(newest.values)
    }

}

// MARK: - One row

extension TranscriptView {

    /// One element of the transcript, and everything needed to draw it.
    ///
    /// Split out of `TranscriptView` for one reason: **cost**. The stack is
    /// eager — it has to be, see the note in `body` — so every redraw of the
    /// transcript used to rebuild all of its rows, and there are two things
    /// that redraw it constantly:
    ///
    /// - *Streaming.* One delta grows the last block, and all several hundred
    ///   rows were reconstructed for it, sixty times a second.
    /// - *Scrolling.* Rows pass under the pointer, so `onHover` fires again
    ///   and again — and hover lived in `TranscriptView`'s own state, so each
    ///   one invalidated the whole transcript. That is why the drop in frame
    ///   rate scaled with how much output had accumulated: the work per hover
    ///   was linear in the length of the conversation.
    ///
    /// Both are fixed by the same move. Hover and the handoff popover are the
    /// row's own `@State` now, so they invalidate one row instead of the
    /// document, and everything the row draws from is passed in *by value* so
    /// the whole thing can be `Equatable`. `.equatable()` then turns a redraw
    /// of an unchanged row into a handful of comparisons rather than a rebuild
    /// and a re-measure.
    ///
    /// `session` is held as a plain reference rather than an `@ObservedObject`
    /// on purpose. Observing it here would subscribe every row to every change
    /// the session makes and undo the whole point; it's here to be *handed* to
    /// a handoff, not read from during layout. Everything the row actually
    /// renders arrives as a value beside it.
    struct Row: View, Equatable {
        let item: TranscriptItem
        /// Only populated for the plan card, which is the one item that draws
        /// from session state rather than from its own payload.
        let todos: [Todo]
        let topGap: CGFloat
        /// Whether to draw the streaming caret — `isRunning` and the tail,
        /// resolved to a value so the row doesn't have to watch the session.
        let caret: Bool
        let stale: Bool
        let scale: CGFloat
        let mode: TranscriptMode
        let plain: Bool
        let accent: Color

        let session: Session
        let onEdit: (String) -> Void

        /// Whether the pointer is over this row, so only this row shows its
        /// button.
        @State private var hovered = false
        /// Whether this row's handoff popover is open. Beside `hovered`
        /// because the two together decide whether the button exists — and
        /// kept here rather than in the row's *content*, or the popover would
        /// die the instant you moved the pointer towards it.
        @State private var asking = false

        /// Values only. The closure and the session reference are excluded:
        /// one can't be compared, and the other is an identity that never
        /// changes for a given transcript.
        static func == (a: Row, b: Row) -> Bool {
            a.item.rendersSameAs(b.item)
                && a.todos == b.todos
                && a.topGap == b.topGap
                && a.caret == b.caret
                && a.stale == b.stale
                && a.scale == b.scale
                && a.mode == b.mode
                && a.plain == b.plain
                && a.accent == b.accent
        }

        var body: some View {
            HStack(alignment: .top, spacing: 0) {
                // An empty gutter mirroring the one on the right.
                //
                // Reserving space only on the trailing side put the text 16pt
                // from the panel's left edge and 42pt from its right — the
                // column read as shoved left inside its own glass. Costing the
                // measure twice and keeping it centred is the better trade;
                // the width slider is there if you want it back.
                //
                // Both go together in plain mode, where there's no handoff
                // button to reserve for — mirroring a gutter that isn't drawn
                // put the text 26pt from the card's leading edge and flush
                // against its trailing one, which is the same fault the other
                // way round.
                if !plain {
                    Color.clear.frame(width: TranscriptView.gutter, height: 0)
                }
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !plain {
                    handoff
                        .frame(width: TranscriptView.gutter, alignment: .top)
                }
            }
            .padding(.top, topGap)
            .contentShape(Rectangle())
            .onHover { inside in
                // Guarded, because `onHover` fires repeatedly as a scroll drags
                // rows past the pointer and an unchanged write is still an
                // invalidation.
                if hovered != inside { hovered = inside }
            }
        }

        /// Only replies and edits are worth another agent's opinion. Your own
        /// messages, tool rows and rules aren't.
        @ViewBuilder
        private var handoff: some View {
            switch item {
            // Your own messages get an edit affordance instead of a handoff —
            // there's no point asking another agent to review your prompt.
            case .user(_, let text) where hovered:
                Button {
                    onEdit(text)
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Theme.surface, in: Circle())
                        .overlay(Circle().strokeBorder(Theme.rule, lineWidth: 1))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Put this back in the composer to edit and send again")
                .transition(.opacity)

            // Built only for the row under the pointer. Every assistant block
            // and diff carried its own `.popover` before this, dozens of
            // presentation hosts standing by for a button nobody could see.
            case .assistant(let id, let text) where hovered || asking:
                HandoffMenu(source: session, showing: $asking) {
                    Handoff.review(reply: text,
                                   question: precedingPrompt(before: id),
                                   from: session)
                } payload: {
                    // Not built here. A reply that *is* an HTML page travels as
                    // a file rather than as four hundred fenced lines in
                    // somebody's composer, and that decision belongs in one
                    // place — `/send` reaches the same reply by another route.
                    .success(Relay.payload(reply: text, from: session))
                }
                .transition(.opacity)
            case .diff(_, _, let file, let rows, _) where hovered || asking:
                HandoffMenu(source: session, showing: $asking) {
                    Handoff.review(diff: rows, file: file, from: session)
                } payload: {
                    // The patch, not the file. Sending the whole file would be
                    // sending something the agent never proposed.
                    .success(Relay.Payload(label: "Proposed edit to \(file)",
                                           text: Handoff.unified(rows)))
                }
                .transition(.opacity)
            default:
                Color.clear.frame(width: 0, height: 0)
            }
        }

        @ViewBuilder
        private var content: some View {
            switch item {
            case .user(_, let text):
                UserTurn(text: text, accent: accent, scale: scale)
            case .assistant(_, let text):
                // Agents emit markdown. Drawing it raw leaves literal asterisks
                // and backticks all over the transcript.
                MarkdownText(raw: text, caret: caret)
            case .thinking(_, let text, let started, let finished):
                ThinkingView(text: text,
                             elapsed: finished.map { $0.timeIntervalSince(started) })
            case .tool(_, _, let name, let target, let detail, let state):
                ToolRow(name: name, target: target, detail: detail, state: state,
                        startExpanded: mode.expandsDetail)
            case .diff(_, _, let file, let rows, let state):
                FileDiffView(file: file, rows: rows, state: state, superseded: stale)
            case .search(_, _, let query, let results, let state):
                WebSearchView(query: query, results: results, state: state)
            case .todos:
                TodoListView(todos: todos)
            case .notice(_, let text):
                Notice(text: text)
            case .compaction(_, let trigger, let dropped):
                CompactionMark(trigger: trigger, dropped: dropped)
            case .opinion(_, let agent, let text, let done):
                OpinionCard(agent: agent, text: text, done: done)
            }
        }

        /// The prompt this reply was answering — the nearest user turn above
        /// it. A review of an answer without its question critiques the wrong
        /// target.
        ///
        /// Reads the session, and can: it runs when you open a handoff, not
        /// during layout.
        private func precedingPrompt(before id: UUID) -> String? {
            guard let index = session.items.firstIndex(where: { $0.id == id })
            else { return nil }
            for item in session.items[..<index].reversed() {
                if case .user(_, let text) = item { return text }
            }
            return nil
        }
    }
}

// MARK: - Your turn

private struct UserTurn: View {
    let text: String
    let accent: Color
    var scale: CGFloat = 1

    /// Attachments ride along in the message text as `@/path` lines. They're
    /// pulled back out here so a screenshot is shown rather than spelled.
    private var parts: (prose: String, files: [URL]) { Attached.split(text) }

    var body: some View {
        // A tinted band, not a bubble.
        //
        // The hairline rule this replaces was too quiet: at body size and
        // weight, a prompt read as just another paragraph, and in Summary mode
        // — where nothing sits between turns — you couldn't tell where your
        // question ended and the answer began. A band spans the full measure
        // rather than floating right, so the column is still one document
        // read top to bottom; it just says plainly which parts are yours.
        VStack(alignment: .leading, spacing: Theme.s4) {
            let parts = parts
            if !parts.prose.isEmpty {
                Text(parts.prose)
                    .font(.system(size: 14 * scale, weight: .medium))
                    .lineSpacing(Prose.leading(scale) - 1)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !parts.files.isEmpty {
                AttachmentStrip(files: parts.files, scale: scale)
            }
        }
            .padding(.vertical, (Theme.s5 - 1) * scale)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The band bleeds outward instead of insetting its text.
            //
            // Padding the text was the obvious way to give the band room, and
            // it put every prompt 12pt right of every reply — two left edges in
            // a column that only wants one. Extending the *background* past the
            // measure keeps your words on the same line as the agent's.
            .background(alignment: .center) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(accent.opacity(0.11))
                    .padding(.horizontal, -Theme.s5 * scale)
            }
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(accent.opacity(0.9))
                    .frame(width: 3)
                    .padding(.vertical, Theme.s4)
                    .padding(.leading, -Theme.s5 * scale)
            }
    }
}

// MARK: - Tool activity

private struct ToolRow: View {
    let name: String
    let target: String
    let detail: String
    let state: ToolState
    var startExpanded = false
    @State private var expanded = false
    /// The row's target, once it's known to be a real file.
    ///
    /// Resolved in a `.task` rather than computed in the body: a long
    /// transcript is hundreds of these, the body runs on every redraw, and
    /// hitting the disk from there would put a `stat` per row into every
    /// scroll frame.
    @State private var file: URL?
    @State private var previewing = false
    /// Whether this row is drawing all of its output rather than the head.
    @State private var wholeBody = false

    /// How much of a tool's output a row draws before it stops.
    ///
    /// Verbose opens every row, which means every file the agent read and every
    /// command it ran is laid out in full, eagerly, in one stack. A `Text` is
    /// one view but not one unit of work — SwiftUI measures all of it — so a
    /// `Read` of a three-thousand-line file costs three thousand lines of text
    /// layout to show a paragraph's worth of them, and a session does that
    /// dozens of times. That's why Verbose is the worst of the four modes and
    /// Summary, which draws no tool rows at all, is the only smooth one.
    ///
    /// Two thousand characters is a screenful, which is as far as anyone reads a
    /// tool row before deciding whether they care. The rest is a click away, and
    /// only the row you clicked pays for it.
    private static let detailCap = 2_000

    /// What went wrong, if anything — shown in the disclosure ahead of the
    /// tool's own input, because when a command fails the error is the thing
    /// you opened the row to read.
    private var body_: String {
        guard let message = state.message else { return detail }
        return detail.isEmpty ? message : message + "\n\n" + detail
    }

    /// The row's target as a file, if it is one.
    ///
    /// Off the main thread, because it touches the disk. A `Bash` target is a
    /// command line rather than a path and simply won't resolve, which is the
    /// right answer without having to enumerate which tools take paths — a
    /// list that would go stale the moment an agent gained a new one.
    private static func resolve(_ target: String) async -> URL? {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") else { return nil }
        return await Task.detached(priority: .utility) {
            let path = NSString(string: trimmed).expandingTildeInPath
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { return nil }
            return URL(fileURLWithPath: path)
        }.value
    }

    private var symbol: String {
        if state.isDeclined { return "slash.circle" }
        if state.isFailed { return "exclamationmark.triangle" }
        switch name {
        case "Read", "NotebookEdit":     return "doc.text"
        case "Write", "Edit":            return "square.and.pencil"
        case "Bash", "Run":              return "terminal"
        case "Grep", "Glob", "Search":   return "magnifyingglass"
        case "WebFetch", "WebSearch", "Fetch": return "globe"
        case "Task":                     return "square.stack.3d.up"
        default:                          return "wrench.adjustable"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gapTight) {
            Button {
                guard !body_.isEmpty else { return }
                withAnimation(Motion.disclose) { expanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: symbol)
                        .font(.system(size: 10.5))
                        .frame(width: 13)
                    Text(name)
                        .font(Theme.label)
                    if !target.isEmpty {
                        Text(target)
                            .font(Theme.monoSmall)
                            .lineLimit(1)
                            // Tail, not middle. Middle-truncating a shell
                            // command splices two unrelated path fragments
                            // together and reads as corruption.
                            .truncationMode(.tail)
                            .foregroundStyle(.tertiary)
                    }
                    // "declined" and "failed" are different claims about your
                    // machine. A command that ran and errored did happen; one
                    // that was refused did not.
                    if state.isDeclined {
                        Text("declined")
                            .font(Theme.label)
                            .foregroundStyle(.tertiary)
                    } else if state.isFailed {
                        Text("failed")
                            .font(Theme.label)
                            .foregroundStyle(Color.diffDelText)
                    }
                }
                .foregroundStyle(state.isDeclined ? AnyShapeStyle(.tertiary)
                                                 : AnyShapeStyle(.secondary))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Its own control rather than a second meaning for the row. The
            // row expands to show what the tool was given; this shows what
            // came out, which is a different question.
            .overlay(alignment: .trailing) {
                if file != nil {
                    Button { previewing = true } label: {
                        Image(systemName: "eye")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Preview this file")
                    .popover(isPresented: $previewing, arrowEdge: .trailing) {
                        if let file { FilePreview(url: file) }
                    }
                }
            }
            // Re-run when the target changes, which for a streaming row it
            // does — and again when the tool finishes, since a Write's target
            // doesn't exist until then.
            .task(id: "\(target)|\(state.isApplied)") {
                file = await Self.resolve(target)
            }

            if (expanded || startExpanded) && !body_.isEmpty {
                let detail = body_
                // `utf8.count` rather than `count`: a native string stores its
                // byte count, where counting characters walks the whole thing —
                // and this test runs for every open row on every redraw. It
                // measures the truncation in bytes and takes it in characters,
                // which can only ever cut *less* than the cap.
                let hidden = wholeBody ? 0 : detail.utf8.count - Self.detailCap
                VStack(alignment: .leading, spacing: 7) {
                    Text(hidden > 0 ? String(detail.prefix(Self.detailCap)) : detail)
                        .font(Theme.mono)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if hidden > 0 {
                        Button {
                            wholeBody = true
                        } label: {
                            Text("Show the rest — \(hidden / 1024 + 1)KB")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.tertiary)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(InsetSurface(radius: 7))
            }
        }
    }
}

// MARK: - Second opinion

/// Another agent's answer, inside this conversation.
///
/// Contained and attributed, because the one thing that must never happen is
/// mistaking it for the agent you're actually talking to. It carries the other
/// account's accent down its edge and names who said it — a reply that looks
/// like the surrounding prose but came from a different vendor is worse than
/// not having asked.
private struct OpinionCard: View {
    let agent: String
    let text: String
    let done: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.accentColor.opacity(0.55))
                .frame(width: 2)

            VStack(alignment: .leading, spacing: Theme.s4) {
                HStack(spacing: Theme.s3 - 1) {
                    Image(systemName: "arrow.turn.up.right")
                        .font(.system(size: 9, weight: .semibold))
                    if done {
                        Text(agent)
                            .font(Theme.label)
                    } else {
                        ShimmerLabel(text: "Asking \(agent)…", enabled: !reduceMotion)
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.tertiary)

                if !text.isEmpty {
                    MarkdownText(raw: text)
                }
            }
            .padding(.leading, Theme.s5)
        }
        .padding(.vertical, Theme.s4)
        .padding(.trailing, Theme.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(InsetSurface(radius: 10))
    }
}

// MARK: - Compaction

/// A rule across the column marking where history was summarised away.
private struct CompactionMark: View {
    let trigger: String
    let dropped: Int

    private var label: String {
        let count = ContextUsage.decimal
            .string(from: NSNumber(value: dropped)) ?? "\(dropped)"
        return dropped > 0 ? "History compacted · \(count) tokens dropped"
                           : "History compacted"
    }

    var body: some View {
        HStack(spacing: Theme.s4) {
            line
            HStack(spacing: Theme.s3 - 1) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 9))
                Text(label)
                    .font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(.tertiary)
            line
        }
        .help(trigger == "manual"
              ? "You ran /compact. Everything above was replaced by a summary — "
                + "the agent can no longer see the original turns."
              : "The context window filled, so the agent summarised everything "
                + "above to make room. It can no longer see the original turns.")
    }

    private var line: some View {
        Rectangle()
            .fill(Theme.rule)
            .frame(height: 1)
    }
}

// MARK: - Notices

private struct Notice: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "info.circle")
                .font(.system(size: 10.5))
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 12))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.tertiary)
    }
}

// MARK: - Empty state

