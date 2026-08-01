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
    /// Needed only to hand a block to another session; the transcript itself
    /// doesn't otherwise care about the roster.
    @ObservedObject var workspace: Workspace
    var mode: TranscriptMode = .normal
    var scale: CGFloat = 1
    var width: CGFloat = Theme.readingWidth
    /// Off inside the mini chat, which supplies its own card — a glass panel
    /// floating on a glass panel is one surface too many, and the top inset
    /// exists to clear a View menu that isn't there.
    var panelled = true

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
    /// When content last changed, so a growth-driven geometry event can't be
    /// mistaken for you scrolling away. Time, not ordering — the two events
    /// arrive in whichever order they like.
    @State private var contentChangedAt = Date.distantPast
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
    /// Which row the pointer is over, so only that row shows its button.
    @State private var hovered: UUID?

    /// The items this mode actually renders. Filtered once here rather than
    /// returning `EmptyView` per row, so the per-pair spacing below still sees
    /// true neighbours — otherwise hiding a run of tool calls would leave the
    /// gap they occupied behind.
    private var visible: [TranscriptItem] {
        session.items.filter { item in
            switch item {
            // Compaction shows in every mode, Summary included: losing
            // history is not a detail.
            case .user, .assistant, .notice, .compaction, .opinion: return true
            case .thinking:                  return mode.showsReasoning
            default:                         return mode.showsActivity
            }
        }
    }

    var body: some View {
        // Filtered exactly once per evaluation.
        //
        // `visible` used to be read from inside `gap(before:)` *and*
        // `isStreamingTail` — both called per row — so a 40-item transcript
        // filtered and allocated the array 40-odd times for every redraw, and
        // during streaming that ran thirty times a second. Quadratic work in
        // the hot path, and the single largest cause of the lag.
        let items = visible

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
                        row(for: item, isTail: item.id == items.last?.id)
                            .padding(.top, gap(before: index, in: items))
                            .id(item.id)
                    }
                    // Anchor so the last line clears the composer.
                    Color.clear.frame(height: 1).id(Self.bottom)
                }
                // The panel hugs the content and scrolls with it, like a page
                // rather than a fixed pane — a full-height sheet behind a
                // two-line reply is a lot of frosted glass for nothing.
                .environment(\.proseScale, scale)
                .padding(.horizontal, Theme.s6)
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
                .padding(.horizontal, Theme.pane)
                .padding(.vertical, Theme.pane + 4)
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
                following = true
                contentChangedAt = Date()
                for delay in [0, 40, 120, 300, 600] {
                    if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
                    guard !Task.isCancelled else { return }
                    position.scrollTo(edge: .bottom)
                }
            }
            // Height *and* distance, read together — because the difference
            // between them is the whole question.
            //
            // Distance alone can't tell "you scrolled up" from "the content got
            // taller underneath you", and those need opposite responses. A
            // change in content height means it was the content; anything else
            // means it was you.
            .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
                ScrollMetrics(
                    height: geometry.contentSize.height,
                    fromBottom: geometry.contentSize.height
                        - (geometry.contentOffset.y + geometry.containerSize.height))
            } action: { old, new in
                guard new.height == old.height else {
                    // Grew or shrank. This is the general case that `tail`
                    // below only ever caught part of: a tool card filling in, a
                    // diff arriving, a chart laying out, an image decoding, a
                    // code block finishing its highlight — none of which change
                    // any item's text, and all of which move the bottom.
                    contentChangedAt = Date()
                    if following { position.scrollTo(edge: .bottom) }
                    return
                }
                if new.fromBottom <= Self.bottomSlack {
                    // Arriving at the end always resumes following, however
                    // you got there.
                    following = true
                } else if Date().timeIntervalSince(contentChangedAt) > 0.3 {
                    // Away from the end with the content still: you scrolled.
                    following = false
                }
            }
            // Keyed on the tail, not the item count: a streaming reply grows
            // the *last* item's text without adding one, so a count-only
            // trigger sat still for the whole of the longest replies.
            .onChange(of: tail) { _, _ in
                contentChangedAt = Date()
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
                following = true
                contentChangedAt = Date()
                Task { @MainActor in
                    for delay in [0, 30, 90, 220] {
                        if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
                        guard !Task.isCancelled else { return }
                        position.scrollTo(edge: .bottom)
                    }
                }
            }
            .onChange(of: visible.count) { _, _ in
                contentChangedAt = Date()
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


    /// What the scroll view is doing, in the two numbers that matter.
    private struct ScrollMetrics: Equatable {
        var height: CGFloat
        var fromBottom: CGFloat
    }

    /// Changes whenever anything is appended *or* the final block grows.
    ///
    /// The last item's identity is folded in as well as its length: a short
    /// block replacing a longer one could otherwise land on the same number and
    /// the follow would sit out that change.
    private var tail: Int {
        var signature = visible.count
        if let last = visible.last {
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

    private static let bottom = "bottom-anchor"

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

    private func row(for item: TranscriptItem, isTail: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            // An empty gutter mirroring the one on the right.
            //
            // Reserving space only on the trailing side put the text 16pt from
            // the panel's left edge and 42pt from its right — the column read
            // as shoved left inside its own glass. Costing the measure twice
            // and keeping it centred is the better trade; the width slider is
            // there if you want it back.
            Color.clear.frame(width: Self.gutter, height: 0)
            content(for: item, isTail: isTail)
                .frame(maxWidth: .infinity, alignment: .leading)
            handoff(for: item)
                .frame(width: Self.gutter, alignment: .top)
        }
        .contentShape(Rectangle())
        .onHover { inside in hovered = inside ? item.id : (hovered == item.id ? nil : hovered) }
    }

    /// Only replies and edits are worth another agent's opinion. Your own
    /// messages, tool rows and rules aren't.
    @ViewBuilder
    private func handoff(for item: TranscriptItem) -> some View {
        switch item {
        // Your own messages get an edit affordance instead of a handoff —
        // there's no point asking another agent to review your prompt.
        case .user(let id, let text) where hovered == id:
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

        // Built only for the row under the pointer. Every assistant block and
        // diff carried its own `.popover` before this, dozens of presentation
        // hosts standing by for a button nobody could see.
        case .assistant(let id, let text) where hovered == id:
            HandoffMenu(source: session) {
                Handoff.review(reply: text,
                               question: precedingPrompt(before: id),
                               from: session)
            }
            .transition(.opacity)
        case .diff(let id, _, let file, let rows, _) where hovered == id:
            HandoffMenu(source: session) {
                Handoff.review(diff: rows, file: file, from: session)
            }
            .transition(.opacity)
        default:
            Color.clear.frame(width: 0, height: 0)
        }
    }

    @ViewBuilder
    private func content(for item: TranscriptItem, isTail: Bool) -> some View {
        switch item {
        case .user(_, let text):
            UserTurn(text: text, accent: session.account.accent, scale: scale)
        case .assistant(let id, let text):
            // Agents emit markdown. Drawing it raw leaves literal asterisks and
            // backticks all over the transcript.
            MarkdownText(raw: text, caret: session.isRunning && isTail)
        case .thinking(_, let text, let started, let finished):
            ThinkingView(text: text,
                         elapsed: finished.map { $0.timeIntervalSince(started) })
        case .tool(_, _, let name, let target, let detail, let state):
            ToolRow(name: name, target: target, detail: detail, state: state,
                    startExpanded: mode.expandsDetail)
        case .diff(_, _, let file, let rows, let state):
            FileDiffView(file: file, rows: rows, state: state)
        case .search(_, _, let query, let results, let state):
            WebSearchView(query: query, results: results, state: state)
        case .todos:
            TodoListView(todos: session.todos)
        case .notice(_, let text):
            Notice(text: text)
        case .compaction(_, let trigger, let dropped):
            CompactionMark(trigger: trigger, dropped: dropped)
        case .opinion(_, let agent, let text, let done):
            OpinionCard(agent: agent, text: text, done: done)
        }
    }

    /// The prompt this reply was answering — the nearest user turn above it.
    /// A review of an answer without its question critiques the wrong target.
    private func precedingPrompt(before id: UUID) -> String? {
        guard let index = session.items.firstIndex(where: { $0.id == id }) else { return nil }
        for item in session.items[..<index].reversed() {
            if case .user(_, let text) = item { return text }
        }
        return nil
    }

    /// The caret belongs on the last block only, and only while text is still
    /// arriving — a caret parked at the end of a finished reply reads as a
    /// stalled stream.
    private func isStreamingTail(_ id: UUID) -> Bool {
        session.isRunning && visible.last?.id == id
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

    /// What went wrong, if anything — shown in the disclosure ahead of the
    /// tool's own input, because when a command fails the error is the thing
    /// you opened the row to read.
    private var body_: String {
        guard let message = state.message else { return detail }
        return detail.isEmpty ? message : message + "\n\n" + detail
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
                .foregroundStyle(state.isRefused ? AnyShapeStyle(.tertiary)
                                                 : AnyShapeStyle(.secondary))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if (expanded || startExpanded) && !body_.isEmpty {
                Text(body_)
                    .font(Theme.mono)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
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
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let count = formatter.string(from: NSNumber(value: dropped)) ?? "\(dropped)"
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

