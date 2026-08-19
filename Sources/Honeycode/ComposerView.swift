import SwiftUI
import AppKit

/// The composer.
///
/// A container rather than a field. Text at the top, and along the bottom rail
/// the controls that qualify the message — what's attached, who you're
/// addressing, which model answers. All three are properties of the message, so
/// they belong with it rather than in a toolbar at the far end of the window.
struct ComposerView: View {
    @Binding var draft: String
    @ObservedObject var session: Session
    /// Taller and more present when it's the only thing on screen.
    var prominent: Bool = false
    /// Matches the transcript's measure, so the two don't disagree.
    var width: CGFloat = Theme.readingWidth
    /// Narrow enough that the rail has to shed something. Usage goes first:
    /// it's the only part you can still read elsewhere.
    var compact = false
    /// Tints the focus ring, and names the session under the card.
    ///
    /// Both are nil unless this composer is one of several on screen. Beside
    /// two other conversations you need to know which one you're typing into;
    /// alone, the ring is already unambiguous and the name is already in the
    /// sidebar, so neither earns its pixels.
    var accent: Color?
    var subtitle: String?
    /// Coding mode. Sheds the card, the rail and the proportional type, and
    /// keeps everything that makes the field worth having — mentions, slash
    /// commands, attachments, dictation.
    ///
    /// A flag rather than a second composer, because the alternative is
    /// reimplementing `@` completion for the sake of a font. What a terminal
    /// prompt is *made of* is a caret, one line and no chrome; none of that is
    /// a reason to lose the parts you'd have to build again.
    var terminal = false
    /// Clicking into a composer is what focuses its column.
    var onFocused: (() -> Void)?
    let onSend: (String) -> Void

    @FocusState private var focused: Bool
    @StateObject private var dictation = Dictation()
    @StateObject private var files = FileIndex()
    @ObservedObject private var usage = UsageStore.shared
    @EnvironmentObject private var background: BackgroundStore

    /// Where the live `@` mention is, derived from the draft every time.
    ///
    /// This used to be `@State`, written in `.onChange(of: draft)` — and a
    /// `Range<String.Index>` held across a change to the string it indexes is a
    /// crash waiting for the right text. SwiftUI is free to evaluate the body
    /// with the new draft before the change handler has run, and an index from
    /// one string is not valid in another: `String.subscript` traps in
    /// `validateScalarRange`.
    ///
    /// Appending a relayed document is what made it certain rather than
    /// occasional. Even an append can invalidate every existing index — a
    /// string of pure ASCII is stored one way and re-encoded the moment a
    /// curly quote or an em dash arrives, which any real document has.
    ///
    /// Recomputing costs one backwards scan to the last `@` on a field holding
    /// a sentence. There is no version of storing it that's worth that.
    private var mention: Range<String.Index>? { Mention.range(in: draft) }
    @State private var highlighted = 0
    @State private var keyMonitor: Any?
    @State private var dropTargeted = false
    /// Which attachment's preview is open.
    @State private var previewing: URL?
    /// Esc closed the list. Cleared by the next keystroke, so dismissing is a
    /// pause rather than a decision — carry on typing and it comes back.
    ///
    /// Without this, dismissal was cosmetic for mentions (the list is derived
    /// from the draft, so it reappeared on the next character) and destructive
    /// for commands (the only way to make one go was to clear what you'd typed).
    @State private var dismissed = false

    private var mentionMatches: [MentionCandidate] {
        guard !dismissed, let mention else { return [] }
        return Mention.candidates(Mention.query(in: draft, range: mention), files: files)
    }

    /// `/` completions. Mutually exclusive with mentions by construction — a
    /// slash command has to start the message, a mention can't.
    private var commandMatches: [AgentCommand] {
        guard !dismissed, SlashCommand.range(in: draft) != nil else { return [] }
        // Honeycode's own commands rank alongside the CLI's rather than sitting
        // in a list of their own. From where you're typing they're the same
        // kind of thing; the difference — that these are intercepted here and
        // never reach the agent — is one of implementation.
        //
        // Shared skills are excluded where the agent already advertises a
        // command of the same name: on a Claude account a skill can exist in
        // both places, and two identical rows in the list would be a choice
        // between things that aren't different.
        let shared = Skills.commands(excluding: session.commands)
        // `/clear` is ours on every profile, so the agent's own entry for it is
        // dropped rather than listed beside it. Both rows would do the same
        // thing — `Session.send` intercepts the name, whichever row you picked
        // — and a duplicate is a choice between things that aren't different.
        let advertised = session.commands.filter { $0.name != Session.clearCommand.name }
        return SlashCommand.matches(
            SlashCommand.query(in: draft),
            in: [Relay.command, Session.clearCommand] + shared + advertised)
    }

    private var completionCount: Int { mentionMatches.count + commandMatches.count }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !session.attachments.isEmpty
    }

    private var hint: String {
        if let error = dictation.errorMessage { return error }
        if completionCount > 0 { return "↑↓ to choose · Return to insert · Esc to dismiss" }
        if dropTargeted { return "Drop to attach" }
        if dictation.isRecording { return "Listening — click the mic again to stop." }
        if !session.queued.isEmpty {
            let count = session.queued.count
            return "\(count) message\(count == 1 ? "" : "s") queued — sending when this turn ends"
        }
        if session.isRunning { return "Working… you can keep typing" }
        if session.items.isEmpty {
            return ClaudeAdapter.skipPermissions
                ? "Permissions are skipped — edits and commands run without asking."
                : "Reads and searches run freely. Every edit is refused."
        }
        return "Return to send"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            if !mentionMatches.isEmpty {
                MentionList(matches: mentionMatches,
                            highlighted: highlighted,
                            onSelect: accept)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if !commandMatches.isEmpty {
                CommandList(matches: commandMatches,
                            highlighted: highlighted,
                            onSelect: acceptCommand)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            card
            // A terminal doesn't caption its prompt. What the hint line says —
            // what Return does, which session this is — coding mode says once
            // in the header instead of under every keystroke.
            if !terminal { hintLine }
        }
        // Coding mode spans the pane rather than centring a reading column,
        // and loses the margin with it: a terminal's prompt is flush with its
        // scrollback, and an inset one reads as a widget sitting on top of the
        // output instead of the last line of it.
        .frame(maxWidth: terminal ? .infinity : width)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, terminal ? 0 : Theme.pane)
        .padding(.top, terminal ? 0 : Theme.s5)
        .padding(.bottom, terminal ? 0 : Theme.s6 - Theme.s1)
        .animation(Motion.hover, value: canSend)
        .animation(Motion.reveal, value: completionCount)
        .onChange(of: draft) { _, new in
            highlighted = 0
            dismissed = false
            if Mention.range(in: new) != nil { files.load(root: session.directory) }
        }
        // Files dropped anywhere on the composer become attachments. The `+`
        // button already did this behind a panel; dropping is the gesture
        // people actually reach for.
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            attach(providers)
            return true
        }
        // A finished turn is the most likely moment for new files to exist, so
        // the next `@` should see them without waiting out the staleness window.
        .onChange(of: session.isRunning) { _, running in
            if !running { files.load(root: session.directory, maxAge: 0) }
        }
        // Material relayed here from another session. Appended, never sent —
        // see `Relay`. Consumed on arrival so switching away and back doesn't
        // paste it a second time.
        .onChange(of: session.relayIncoming) { _, arrived in
            guard arrived != nil else { return }
            consumeRelay()
            focused = true
        }
        .onAppear {
            focused = true
            // A relay that landed while this composer didn't exist — the
            // destination wasn't on screen when it arrived, which is the
            // ordinary case rather than the odd one.
            consumeRelay()
            // Every revision replaces the dictated span — not the field — so
            // speaking and typing in the same message don't fight each other.
            dictation.onTranscript = { text in
                draft = text
            }
            installKeyMonitor()
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
    }

    // MARK: Mentions

    /// Arrow keys, Tab, Esc and ⌘V, taken before the text field sees them.
    ///
    /// `.onMoveCommand` never fires here: a focused `TextField` handles arrow
    /// keys itself to move the caret, and SwiftUI only forwards what the focused
    /// control declines. A local monitor is the way to get first refusal, and it
    /// passes every other key straight through. Return isn't intercepted —
    /// `onSubmit` already runs before send and can branch there.
    ///
    /// Everything here is gated on the composer actually holding focus. A local
    /// monitor sees every key in the window, so an ungated one speaks for
    /// controls it has nothing to do with: ⌘V was being swallowed while you
    /// typed in the browser's address field or a rename box, and with the mini
    /// chat open there are two composers and so two monitors bidding for the
    /// same keystroke. Focus is the thing that says which one is being talked
    /// to.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard focused else { return event }

            // ⌘V first: a screenshot or a dragged-in file on the clipboard
            // should become an attachment rather than a wall of pasted bytes.
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers == "v",
               pasteAttachments() {
                return nil
            }

            // ⇧Return: a newline that doesn't send. Written through the field
            // editor rather than by appending to the draft, so it lands at the
            // caret instead of at the end of whatever you'd typed.
            if event.keyCode == 36, event.modifierFlags.contains(.shift),
               let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                editor.insertNewlineIgnoringFieldEditor(nil)
                return nil
            }

            let count = completionCount
            guard count > 0 else {
                // Esc with no list open stops the turn. This used to be a menu
                // key equivalent, which meant it fired anywhere in the window —
                // including while you were dismissing a popover or a palette.
                if event.keyCode == 53, session.isRunning {
                    session.interrupt()
                    return nil
                }
                return event
            }
            switch event.keyCode {
            case 125:                                   // down
                highlighted = min(highlighted + 1, count - 1)
                return nil
            case 126:                                   // up
                highlighted = max(highlighted - 1, 0)
                return nil
            case 48:                                    // tab
                acceptHighlighted()
                return nil
            case 53:                                    // escape
                // Close the list, keep the message. Esc used to empty the draft
                // outright when a slash command was open, which turned a
                // dismissal into losing everything you'd written after it.
                //
                // `dismissed` is the whole of it now. It used to also clear the
                // stored mention range, which was the only thing suppressing
                // the file list — and with the range derived from the draft
                // there's nothing to clear. Both lists have honoured
                // `dismissed` all along.
                dismissed = true
                return nil
            default:
                return event
            }
        }
    }

    private func acceptHighlighted() {
        if !mentionMatches.isEmpty {
            accept(mentionMatches[min(highlighted, mentionMatches.count - 1)])
        } else if !commandMatches.isEmpty {
            acceptCommand(commandMatches[min(highlighted, commandMatches.count - 1)])
        }
    }

    /// A command replaces the whole draft, since it had to start it. The
    /// trailing space both closes the list and leaves the caret where an
    /// argument would go.
    private func acceptCommand(_ command: AgentCommand) {
        draft = "/" + command.name + " "
        highlighted = 0
    }

    /// Swap the typed fragment for the real thing — a path, or an agent's
    /// handle. The trailing space both reads naturally and closes the mention,
    /// since a mention can't contain one.
    private func accept(_ candidate: MentionCandidate) {
        // Recomputed here rather than read from state, and read exactly once —
        // the range has to come from the same value of `draft` that's about to
        // be mutated with it. Nothing clears it afterwards because there's
        // nothing to clear: replacing the fragment with a path and a space
        // ends the mention, and the next read of `mention` sees that.
        guard let range = Mention.range(in: draft) else { return }
        draft.replaceSubrange(range, with: "@\(Mention.insertion(for: candidate)) ")
        highlighted = 0
    }

    private var card: some View {
        contents
            .padding(.horizontal, terminal ? Theme.s5 + Theme.s1 : Theme.s5)
            .padding(.vertical, terminal ? Theme.s4 : Theme.s5 - Theme.s1)
            .modifier(ComposerSurface(terminal: terminal,
                                      glass: background.isGlassy,
                                      focused: focused,
                                      tint: accent))
            .animation(Motion.hover, value: focused)
            .onChange(of: focused) { _, now in
                // Only on gaining focus. Reporting the loss too would fight the
                // gain from the composer you just clicked into, and the last write
                // would win by timing rather than by intent.
                if now { onFocused?() }
            }
    }

    private var contents: some View {
        VStack(alignment: .leading, spacing: Theme.s4) {
            if let pending = session.relayPending { relayNotice(pending) }
            if !session.attachments.isEmpty { attachmentRow }

            HStack(alignment: .firstTextBaseline, spacing: Theme.s3) {
                if terminal {
                    // The caret. It is the only chrome coding mode keeps,
                    // because a prompt with nothing in front of it doesn't
                    // read as a place to type.
                    Text("›")
                        .font(Theme.mono.weight(.semibold))
                        // The caret carries focus, which is where a terminal
                        // has always put it.
                        .foregroundStyle(focused
                                         ? AnyShapeStyle(session.account.accent)
                                         : AnyShapeStyle(.tertiary))
                }
                TextField(terminal ? "" : "Message \(session.account.shortTitle)…",
                          text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(terminal ? Theme.mono : Theme.body)
                    .lineSpacing(terminal ? 1.5 : 2)
                    .lineLimit(prominent ? (2...12) : (1...10))
                    .focused($focused)
                    .onSubmit {
                        // Return completes the suggestion rather than sending a
                        // half-typed path — the same bargain every editor makes.
                        if completionCount > 0 {
                            acceptHighlighted()
                        } else if canSend {
                            send()
                        }
                    }
            }

            // The rail states the model, the spend and the context — all of
            // which coding mode puts in the status line instead, where a
            // terminal has always kept them.
            if !terminal { rail }
        }
    }

    // MARK: Relays

    /// Something is on its way into this composer.
    ///
    /// Shown here rather than in the sending session because here is where it's
    /// going to appear, and a transform takes a full turn — long enough to
    /// switch away, forget, and be surprised by a block of text you didn't
    /// type. It says who it's from, because the answer to "why is this
    /// arriving" is always the other conversation.
    private func relayNotice(_ pending: RelayPending) -> some View {
        HStack(spacing: Theme.s3) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
                .frame(width: 12, height: 12)
            Text("\(pending.from) is \(pending.verb) \(pending.label)…")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, Theme.s4)
        .padding(.vertical, Theme.s2)
        .background(Theme.well, in: Capsule())
        .transition(.opacity)
    }

    // MARK: Attachments

    private var attachmentRow: some View {
        // Wraps, because four long paths on one line would push the send
        // button off the card.
        FlowRow(spacing: Theme.s3) {
            ForEach(session.attachments, id: \.self) { url in
                HStack(spacing: Theme.s3 - Theme.s1) {
                    // The chip's name is the button. Attaching something and
                    // then having no way to check *which* file you attached —
                    // a relayed document, a screenshot pasted three minutes
                    // ago, one of two files with nearly the same name — was a
                    // gap you could only close by sending it and finding out.
                    Button { previewing = url } label: {
                        HStack(spacing: Theme.s3 - Theme.s1) {
                            Image(systemName: "doc")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.tertiary)
                            Text(url.lastPathComponent)
                                .font(.system(size: 11.5))
                                .lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Preview \(url.lastPathComponent)")

                    Button {
                        session.attachments.removeAll { $0 == url }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove")
                }
                .padding(.horizontal, Theme.s4)
                .padding(.vertical, Theme.s2)
                .background(Theme.well, in: Capsule())
                // Anchored on the chip you clicked rather than on the row, so
                // with four attached it's obvious which one you're looking at.
                .popover(isPresented: previewBinding(for: url), arrowEdge: .top) {
                    FilePreview(url: url)
                }
            }
        }
    }

    /// The open preview, or none. Only ever clears itself for the chip it
    /// belongs to — the same rule the transcript's handoff popovers follow, and
    /// for the same reason: a stale dismissal mustn't close a popover somebody
    /// has since opened elsewhere.
    private func previewBinding(for url: URL) -> Binding<Bool> {
        Binding(get: { previewing == url },
                set: { open in previewing = open ? url : (previewing == url ? nil : previewing) })
    }

    // MARK: Bottom rail

    private var rail: some View {
        HStack(spacing: Theme.s4) {
            Button(action: attach) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HoverCapsule())
            .help("Attach files")

            // The account chip and directory used to sit here. Both were
            // restating what the sidebar already shows for the selected
            // session, and a rail that repeats context is just clutter under
            // the thing you're actually typing.

            // Usage sits with the thing that spends it.
            //
            // These were four separate chips in the opposite corner, as far
            // from the send button as the window allows. Cost, quota and
            // context are all consequences of pressing send, so they belong
            // where your eye already is when you press it.
            if !compact { usageStrip }

            Spacer(minLength: Theme.s4)

            ModelPicker(session: session)
            micButton
            // Stop and send are both present while a turn runs: you might want
            // to add to it *or* abandon it, and folding them into one control
            // meant picking one at build time.
            if session.isRunning { stopButton }
            sendButton
        }
    }

    @ViewBuilder
    private var usageStrip: some View {
        HStack(spacing: Theme.s4) {
            // Shown from 60%, when it starts to matter. A permanent "12% ctx"
            // is furniture.
            if let context = session.context, context.percent >= 60 {
                readout("\(context.percent)% ctx",
                        alarming: context.percent >= 90,
                        help: context.summary)
            }

            if let limit = session.rateLimit, limit.isConstrained {
                readout(limit.resetsAt.map { "resets \(RateLimit.clock.string(from: $0))" }
                        ?? limit.windowName,
                        alarming: limit.status == "rejected",
                        help: limit.summary)
            }

            allowance
        }
    }

    /// What this account has left, not what it has spent.
    ///
    /// The three accounts bill in genuinely different ways, so one number
    /// can't serve all of them: a capped subscription wants a percentage, a
    /// usage-based enterprise seat wants spend against a contract figure, and
    /// Copilot bills in AI Units per request.
    @ViewBuilder
    private var allowance: some View {
        if !session.account.reportsCost {
            // Tokens rather than money because ACP reports no cost, and a
            // Copilot seat bills in units rather than dollars anyway. Shown as
            // "≈" because it genuinely is: see `tokensSent`.
            if session.tokensSent > 0 {
                readout("≈\(Self.compact(session.tokensSent)) tok",
                        alarming: false,
                        help: "Roughly \(Self.compact(session.tokensSent)) input tokens "
                            + "sent in this conversation.\nCounted once per turn from the "
                            + "context window, so a turn that ran several tools sent more "
                            + "than this shows.")
            }
            if let units = session.aiUnits, units > 0 {
                readout(units == units.rounded()
                        ? "\(Int(units)) AIC" : String(format: "%.2f AIC", units),
                        alarming: false,
                        help: "AI Units consumed by this conversation")
            }
        } else if let account = usage.usage[session.account], let binding = account.binding {
            readout("\(binding.percent)% \(binding.label)",
                    alarming: binding.percent >= 90,
                    help: account.summary)
        } else if let cap = usage.capUsage(session.account) {
            readout("\(cap.percent)% month",
                    alarming: cap.percent >= 90,
                    help: String(format: "$%.2f of $%.0f this month.", cap.spent, cap.cap)
                        + "\nCounts turns run in Honeycode only.")
        } else if session.costUSD > 0 {
            readout(String(format: "$%.3f", session.costUSD),
                    alarming: false, help: "Session cost so far")
        }
    }

    private func readout(_ text: String, alarming: Bool, help: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(alarming ? AnyShapeStyle(Color.diffDelText)
                                      : AnyShapeStyle(.tertiary))
            .help(help)
    }

    /// 28,400 → "28k", 1,240,000 → "1.2M". A token count is an order of
    /// magnitude, not a figure you'd reconcile, and the strip has room for
    /// about four characters.
    private static func compact(_ count: Int) -> String {
        switch count {
        case 1_000_000...:
            return String(format: "%.1fM", Double(count) / 1_000_000)
        case 1_000...:
            return "\(Int((Double(count) / 1_000).rounded()))k"
        default:
            return "\(count)"
        }
    }

    /// Append relayed material to the draft and clear it, so switching away
    /// and back doesn't paste it a second time.
    private func consumeRelay() {
        guard let arrived = session.relayIncoming else { return }
        draft = draft.isEmpty ? arrived : draft + "\n\n" + arrived
        session.relayIncoming = nil
    }

    private var micButton: some View {
        Button { dictation.toggle(continuing: draft) } label: {
            ZStack {
                // The ring reads as level, not as a spinner — it tracks the
                // mic so you can see it's actually hearing you.
                if dictation.isRecording {
                    Circle()
                        .fill(Color.accentColor.opacity(0.16))
                        .scaleEffect(1 + CGFloat(dictation.level) * 0.5)
                }
                Image(systemName: dictation.isRecording ? "waveform" : "mic")
                    .font(.system(size: 12))
                    .foregroundStyle(dictation.isRecording
                                     ? AnyShapeStyle(Color.accentColor)
                                     : AnyShapeStyle(.secondary))
            }
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverCapsule())
        .disabled(!dictation.isAvailable)
        .help(dictation.isRecording ? "Stop dictation" : "Dictate")
        .animation(Motion.hover, value: dictation.level)
    }

    private var stopButton: some View {
        Button { session.interrupt() } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 23, height: 23)
                .background(Theme.well, in: Circle())
        }
        .buttonStyle(.plain)
        .help("Stop this turn (Esc)")
        .transition(.opacity)
    }

    /// Send, or queue.
    ///
    /// Stays live while a turn runs. Watching an agent head for the wrong file
    /// with no way to say so until it finishes is the single most irritating
    /// thing about driving one, and the fix is just letting the button work.
    private var sendButton: some View {
        Button(action: send) {
            Image(systemName: session.isRunning ? "arrow.up.to.line" : "arrow.up")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(canSend ? Color.white : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 23, height: 23)
                .background(canSend ? AnyShapeStyle(Color.accentColor)
                                    : AnyShapeStyle(Theme.well),
                            in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .help(session.isRunning ? "Queue — sends when this turn ends" : "Send")
        .animation(Motion.reveal, value: session.isRunning)
    }

    private var hintLine: some View {
        HStack(spacing: 0) {
            Text(hint)
                .font(.system(size: 11))
                .foregroundStyle(dictation.errorMessage != nil
                                 ? AnyShapeStyle(Color.diffDelText)
                                 : AnyShapeStyle(.tertiary))
                .lineLimit(1)
            Spacer(minLength: 0)
            // Which conversation this is, opposite the hint.
            //
            // The placeholder already names the *account* ("Message
            // Enterprise…"), which is enough until two columns are on the same
            // account. This is the line that tells those apart, and it sits
            // here rather than in a header bar so the feature costs nothing
            // when you're only running one.
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.quaternary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, Theme.s4)
            }
        }
        .padding(.horizontal, Theme.s1)
        .frame(height: 13)
    }

    // MARK: Actions

    /// Dropped file URLs.
    private func attach(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { add(url) }
            }
        }
    }

    /// Clipboard contents worth attaching. Returns false to let a normal text
    /// paste through untouched.
    private func pasteAttachments() -> Bool {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           !urls.isEmpty {
            urls.forEach(add)
            return true
        }
        // A screenshot has no file behind it, so one has to be made — agents
        // read images from disk, not from a clipboard.
        guard let image = NSImage(pasteboard: pasteboard),
              let url = Self.writeToDisk(image) else { return false }
        add(url)
        return true
    }

    private func add(_ url: URL) {
        guard !session.attachments.contains(url) else { return }
        session.attachments.append(url)
    }

    private static func writeToDisk(_ image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return nil }

        let folder = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Honeycode/Attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("paste-\(UUID().uuidString.prefix(8)).png")
        do { try png.write(to: url) } catch { return nil }
        return url
    }

    private func attach() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(add)
    }

    private func send() {
        if dictation.isRecording { dictation.stop() }
        // Attachments ride along as `@path` references — the CLI resolves those
        // itself and reads whatever's behind them, which beats us guessing at
        // encodings or inlining base64 for file types it already handles.
        let paths = session.attachments.map { "@\($0.path)" }.joined(separator: "\n")
        let body = paths.isEmpty ? draft : draft + "\n" + paths
        session.attachments.removeAll()
        onSend(body)
    }
}

/// Minimal wrapping stack for the attachment chips.
private struct FlowRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
