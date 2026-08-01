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
    let onSend: (String) -> Void

    @FocusState private var focused: Bool
    @StateObject private var dictation = Dictation()
    @StateObject private var files = FileIndex()
    @ObservedObject private var usage = UsageStore.shared
    @EnvironmentObject private var background: BackgroundStore

    /// Live `@` mention state. `nil` when the caret isn't in one.
    @State private var mention: Range<String.Index>?
    @State private var highlighted = 0
    @State private var keyMonitor: Any?
    @State private var dropTargeted = false

    private var mentionMatches: [String] {
        guard let mention else { return [] }
        return files.matches(Mention.query(in: draft, range: mention))
    }

    /// `/` completions. Mutually exclusive with mentions by construction — a
    /// slash command has to start the message, a mention can't.
    private var commandMatches: [AgentCommand] {
        guard SlashCommand.range(in: draft) != nil else { return [] }
        return SlashCommand.matches(SlashCommand.query(in: draft), in: session.commands)
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
            hintLine
        }
        .frame(maxWidth: width)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Theme.pane)
        .padding(.top, Theme.s5)
        .padding(.bottom, Theme.s6 - Theme.s1)
        .animation(Motion.hover, value: canSend)
        .animation(Motion.reveal, value: completionCount)
        .onChange(of: draft) { _, new in
            mention = Mention.range(in: new)
            highlighted = 0
            if mention != nil { files.load(root: session.directory) }
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
        .onAppear {
            focused = true
            // Every revision replaces the dictated span, so speaking and
            // typing in the same message don't fight each other.
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

    /// Arrow keys and Tab, taken before the text field sees them.
    ///
    /// `.onMoveCommand` never fires here: a focused `TextField` handles arrow
    /// keys itself to move the caret, and SwiftUI only forwards what the focused
    /// control declines. A local monitor is the way to get first refusal, and it
    /// passes every other key straight through. Return isn't intercepted —
    /// `onSubmit` already runs before send and can branch there.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // ⌘V first: a screenshot or a dragged-in file on the clipboard
            // should become an attachment rather than a wall of pasted bytes.
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers == "v",
               pasteAttachments() {
                return nil
            }

            let count = completionCount
            guard count > 0 else { return event }
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
                mention = nil
                draft = commandMatches.isEmpty ? draft : ""
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

    /// Swap the typed fragment for the real path. The trailing space both reads
    /// naturally and closes the mention, since a mention can't contain one.
    private func accept(_ path: String) {
        guard let mention else { return }
        draft.replaceSubrange(mention, with: "@\(path) ")
        self.mention = nil
        highlighted = 0
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: Theme.s4) {
            if !session.attachments.isEmpty { attachmentRow }

            TextField("Message \(session.account.shortTitle)…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.body)
                .lineSpacing(2)
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

            rail
        }
        .padding(.horizontal, Theme.s5)
        .padding(.vertical, Theme.s5 - Theme.s1)
        .modifier(RaisedSurface(glass: background.isGlassy,
                                radius: Theme.cornerCard * 2,
                                focused: focused))
        .animation(Motion.hover, value: focused)
    }

    // MARK: Attachments

    private var attachmentRow: some View {
        // Wraps, because four long paths on one line would push the send
        // button off the card.
        FlowRow(spacing: Theme.s3) {
            ForEach(session.attachments, id: \.self) { url in
                HStack(spacing: Theme.s3 - Theme.s1) {
                    Image(systemName: "doc")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                    Text(url.lastPathComponent)
                        .font(.system(size: 11.5))
                        .lineLimit(1)
                    Button {
                        session.attachments.removeAll { $0 == url }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, Theme.s4)
                .padding(.vertical, Theme.s2)
                .background(Theme.well, in: Capsule())
            }
        }
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

            ModelPicker(session: session, compact: compact)
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
                readout(limit.resetsAt.map { "resets \(Self.clock.string(from: $0))" }
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
        if session.account == .copilot {
            // Tokens rather than money because Copilot reports no cost, and a
            // seat bills in units rather than dollars anyway. Shown as "≈"
            // because it genuinely is: see `tokensSent`.
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

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private var micButton: some View {
        Button { dictation.toggle() } label: {
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
