import Foundation

/// Drives one long-lived `claude` process over its newline-delimited JSON
/// protocol.
///
/// The process is spawned once and kept alive across turns — it exits on stdin
/// EOF, so holding the pipe open is the whole trick. Each turn is a JSON object
/// written to stdin; typed events stream back on stdout.
///
/// Two flags are load-bearing and easy to get wrong:
///
/// - `--verbose` is **required** alongside `-p --output-format stream-json`.
///   Without it the CLI exits immediately with an error, and the error names
///   neither flag clearly.
/// - `--dangerously-skip-permissions` is what makes edits actually land. The
///   headless default refuses every write, returning a synthetic tool result
///   marked as an error — there is no interactive approval round-trip over
///   stream-json to fall back on, so it's this flag or a read-only app. It's
///   behind a setting, on by default, because that's the deliberate choice
///   this app is built around rather than an accident.
/// Paces token deltas so text appears at a steady rate rather than in bursts.
///
/// Two problems, one mechanism. Deltas arrive from the network in clumps — a
/// pause, then forty characters at once — and each one used to hop straight
/// onto the main queue and rebuild the transcript. Batching alone fixed the
/// redraw count but not the look: even, frequent redraws of *uneven* chunks
/// still read as jumping, because the eye tracks the rate text appears, not the
/// rate the view refreshes.
///
/// So this holds a backlog and drains it proportionally, once per frame:
/// a long backlog empties fast, a short one trickles. Text arrives smoothly
/// whatever the network did, and the display never stalls waiting for it.
///
/// Runs are kept in order and merged only when adjacent and of the same kind,
/// so reasoning and prose can't be reordered by the pacing.
final class DeltaCoalescer {
    /// One drain per frame.
    private static let tick = 1.0 / 60.0
    /// How much of the backlog to release each frame. An eighth catches up
    /// quickly after a burst without dumping it all in one layout pass.
    private static let share = 8

    private var runs: [(thinking: Bool, text: String)] = []
    /// Characters still waiting, tracked rather than recounted.
    ///
    /// `runs.reduce(0) { $0 + $1.text.count }` walked every grapheme of the
    /// whole backlog to size each drain — sixty times a second, over a backlog
    /// that gets *longer* the further behind the pacer falls.
    private var backlog = 0
    private var draining = false
    /// Bumped by `flush`, so a tick already in flight can tell that the backlog
    /// it was pacing is gone.
    ///
    /// Without it a flush left `draining` false with a timer still scheduled,
    /// so the next delta started a *second* chain and both survived — each
    /// rescheduling itself, each taking an eighth of the same backlog. One
    /// flush per tool call meant a turn that used twenty tools ended up with
    /// twenty timers draining at twenty times the intended rate, which is the
    /// bursty arrival this class exists to prevent.
    private var generation = 0
    private let lock = NSLock()

    /// Called on the main queue with the released runs, in arrival order.
    var onFlush: (([(thinking: Bool, text: String)]) -> Void)?

    func append(_ text: String, thinking: Bool) {
        lock.lock()
        backlog += text.count
        if let last = runs.last, last.thinking == thinking {
            runs[runs.count - 1].text += text
        } else {
            runs.append((thinking, text))
        }
        let start = !draining
        draining = true
        let generation = self.generation
        lock.unlock()

        if start { schedule(generation) }
    }

    private func schedule(_ generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.tick) { [weak self] in
            self?.step(generation)
        }
    }

    private func step(_ generation: Int) {
        lock.lock()
        // Orphaned by a flush. Whatever is draining now belongs to a later
        // chain, so this one leaves the state alone and stops.
        guard generation == self.generation else {
            lock.unlock()
            return
        }
        guard backlog > 0 else {
            draining = false
            lock.unlock()
            return
        }

        var budget = max(2, backlog / Self.share)
        var batch: [(thinking: Bool, text: String)] = []
        while budget > 0, !runs.isEmpty {
            // Sliced by Character, never by byte — cutting a grapheme in half
            // would put a broken glyph on screen for a frame.
            let take = min(budget, runs[0].text.count)
            batch.append((runs[0].thinking, String(runs[0].text.prefix(take))))
            runs[0].text.removeFirst(take)
            budget -= take
            backlog -= take
            if runs[0].text.isEmpty { runs.removeFirst() }
        }
        lock.unlock()

        if !batch.isEmpty { onFlush?(batch) }
        schedule(generation)
    }

    /// Release everything now — the turn is over, so the text has to be
    /// complete whether or not the pacing has caught up.
    func flush() {
        lock.lock()
        let batch = runs
        runs = []
        backlog = 0
        draining = false
        generation &+= 1
        lock.unlock()
        guard !batch.isEmpty else { return }
        onFlush?(batch)
    }
}

final class ClaudeAdapter: AgentAdapter {

    /// Whether to launch with permissions skipped. Read at process start, so
    /// toggling it restarts live sessions via the notification below.
    static var skipPermissions: Bool {
        Policy.value(.skipPermissions, default: true)
    }

    /// Posted by Settings when the permission toggle changes.
    static let permissionsChanged = Notification.Name("honeycode.permissionsChanged")

    private unowned let session: Session
    private var process = Process()
    private var inPipe = Pipe()
    private var outPipe = Pipe()
    private var errPipe = Pipe()
    private var started = false
    /// Whether *this launch* used `--resume`, and whether it produced any
    /// actual conversation. Together they detect a stale conversation id.
    private var launchedResuming = false
    private var sawContent = false
    private var resumeFallbackUsed = false
    /// The largest prompt any single API call in the current turn sent.
    ///
    /// Reset per turn rather than kept for the session, because occupancy
    /// falls as well as rises: a compaction is precisely the moment the number
    /// should drop, and a session-wide maximum would hold the pre-compaction
    /// figure for the rest of the conversation.
    private var lastPromptTokens = 0
    /// Whether a turn is open on the wire — set when one is written, cleared by
    /// the `result` frame that ends it. See `send`.
    private var turnInFlight = false
    /// Messages typed while a turn was open, in order, waiting for it to end.
    private var held: [String] = []
    /// The turn in flight, kept so it can be replayed if the resume was stale.
    private var pendingTurn: String?
    private var buffer = Data()
    private let lock = NSLock()

    private var permissionObserver: NSObjectProtocol?
    private let deltas = DeltaCoalescer()

    init(session: Session) {
        self.session = session
        deltas.onFlush = { [weak self] batch in
            guard let session = self?.session else { return }
            for run in batch {
                if run.thinking { session.appendThinking(run.text) }
                else { session.appendAssistant(run.text) }
            }
        }
        // The flag is fixed at launch, so a live session has to be torn down
        // for the toggle to mean anything. Same restart path as a model change.
        permissionObserver = NotificationCenter.default.addObserver(
            forName: Self.permissionsChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.restart() }
    }

    deinit {
        if let permissionObserver {
            NotificationCenter.default.removeObserver(permissionObserver)
        }
    }

    /// Tear down so the next turn relaunches with current flags.
    ///
    /// Model and effort are launch flags — there's no way to change them on a
    /// live process — so this is what makes the picker actually do something.
    /// Deliberately does *not* start a new process: it waits for the next send,
    /// so flipping the model twice costs one restart rather than two.
    func restart() {
        guard started else { return }
        teardown()
    }

    /// Same teardown, different reason — and one extra thing to forget.
    ///
    /// `resumeFallbackUsed` is per-conversation, not per-process: leaving it
    /// set would mean the *next* conversation's first stale resume went
    /// unrecovered, since the recovery only ever runs once.
    func reset() {
        pendingTurn = nil
        resumeFallbackUsed = false
        guard started else { return }
        teardown()
    }

    /// Killing the process ends the turn, whatever the reason for killing it.
    ///
    /// Clearing the turn used to be each caller's job, and two callers didn't
    /// do it: `restart()` and `reset()`. Change the model, the effort or the
    /// isolation lock mid-turn — or toggle permissions, which restarts every
    /// adapter in the app at once — and the process died with `isRunning` still
    /// true. Nothing was left that could put it back: the termination handler is
    /// unhooked two lines above, before the kill, so the crash path never ran,
    /// and `endTurn` can't arrive from a process that no longer exists. The
    /// session sat on "Working…" indefinitely, and `Session.send` queued every
    /// later message behind a turn that had already died.
    private func teardown() {
        outPipe.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        try? inPipe.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        process = Process()
        inPipe = Pipe(); outPipe = Pipe(); errPipe = Pipe()
        lock.lock(); buffer = Data(); lock.unlock()
        started = false
        // A `turnInFlight` left set is worse than the bug it guards against:
        // every later message would be held for a turn that can no longer end,
        // and the session would go mute permanently rather than once. Held
        // messages go with it — they were waiting on the turn this just killed.
        turnInFlight = false
        held.removeAll()
        DispatchQueue.main.async { self.session.isRunning = false }
    }

    // MARK: Lifecycle

    private func startIfNeeded() -> Bool {
        if started { return true }

        // Only Claude accounts reach this adapter — Copilot has its own — so a
        // missing config dir means the account table is wrong, not that the
        // feature is unbuilt.
        guard let configDir = session.account.configDir else {
            emit(.notice(id: UUID(), text:
                "\(session.account.title) has no Claude config directory."))
            return false
        }
        guard let binary = Self.locateClaude() else {
            emit(.notice(id: UUID(), text: "Couldn't find the `claude` binary on PATH."))
            return false
        }

        process.executableURL = binary
        process.currentDirectoryURL = session.directory
        var arguments = [
            "-p",
            "--verbose",                      // required with stream-json output
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--include-partial-messages",     // token-level deltas
            "--model", session.model.id,
            "--effort", session.effort.rawValue,
        ]
        if Self.skipPermissions {
            arguments.append("--dangerously-skip-permissions")
        }
        // Confinement, if this session is isolated.
        //
        // `--settings` rather than the config directory, because the deny
        // rules are per-session and the config directory is per-account —
        // writing them there would confine every session on the account to one
        // session's root.
        //
        // These rules beat `--dangerously-skip-permissions`, which is the
        // whole reason this works: measured directly, a denied path answers
        // BLOCKED with permissions skipped and reads the file without the
        // rules. See `Isolation` for why they're shaped the way they are.
        if session.isolated,
           let settings = Isolation.settings(root: session.directory, for: session.id) {
            arguments += ["--settings", settings.path]
        }
        // Host capabilities plus the shared skills index. Built per launch
        // rather than held in a static: skills are files, and the most likely
        // place to change one is a text editor outside this app.
        arguments += ["--append-system-prompt", Self.hostCapabilities + Skills.preamble()]
        // Pinned so a model change — or a relaunch of the whole app — can
        // rejoin this conversation rather than starting a fresh one.
        launchedResuming = session.hasStarted
        sawContent = false
        arguments += [launchedResuming ? "--resume" : "--session-id",
                      session.conversationID]
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        env["CLAUDE_CONFIG_DIR"] = configDir
        // The agent runs shell commands on your behalf, and inherits this app's
        // PATH — which, launched from Finder, is launchd's four directories and
        // nothing else. Without this an agent asked "is the Azure CLI
        // installed?" answers no about a machine that has it, because `which
        // az` genuinely fails inside the process it's running in.
        env["PATH"] = Shell.toolPath
        process.environment = env

        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let self else { return }
            self.consume(chunk)
        }

        // A dead process is a dead session here, not a finished turn.
        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            let err = self.errPipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(decoding: err, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Backstop for a resume that dies before emitting anything at all.
            // The usual failure is louder than this and is caught in `result`.
            let staleResume = proc.terminationStatus != 0
                && self.launchedResuming && !self.sawContent && !self.resumeFallbackUsed
            DispatchQueue.main.async {
                // Tear down before anything else. Leaving `started` true meant
                // the next `send` wrote into a closed pipe — swallowed by
                // `try?` — so the message appeared in the transcript, the
                // spinner started, and nothing ever ended the turn. Worse, a
                // spent `Process` can't be relaunched: `run()` on one raises
                // an Objective-C exception that Swift's `catch` can't see, so
                // reusing this instance is a crash rather than an error.
                //
                // Done on the main queue, in one block, so a `send` racing the
                // process's death sees either the live process or a clean slate
                // and never the wreckage in between.
                self.teardown()
                if staleResume {
                    self.recoverFromStaleResume()
                    return
                }
                if proc.terminationStatus != 0 {
                    // See `Diagnostic`, and the ACP adapter's twin of this: the
                    // sentence is the message, stderr is at most a clause on
                    // the end of it.
                    let detail = Diagnostic.summarise(text)
                    self.session.items.append(.notice(id: UUID(), text:
                        "claude exited unexpectedly."
                        + (detail.isEmpty ? "" : " " + detail)))
                }
            }
        }

        do {
            try process.run()
            started = true
            return true
        } catch {
            emit(.notice(id: UUID(), text: "Couldn't start claude: \(error.localizedDescription)"))
            return false
        }
    }

    /// What this host can render that a terminal can't.
    ///
    /// Without this the agent has no way to know a native chart surface exists,
    /// so it does the sensible terminal thing: writes an HTML file and opens
    /// your browser. Stating the contract is the whole difference between a
    /// chart appearing in the transcript and a tab appearing in Safari.
    ///
    /// Kept short deliberately — it rides on every turn, and a long preamble is
    /// a permanent tax on a cached prefix for something used occasionally.
    private static let hostCapabilities = """
    You are running inside Honeycode, a native macOS GUI, not a terminal.
    It renders your markdown, including tables, and it draws charts natively.

    For any chart, graph or plot, emit a fenced block tagged `chart` containing
    JSON — do not write an HTML file or open a browser unless explicitly asked:

    ```chart
    {"type":"bar","title":"Fruit per person","x":"Country","y":"kg/year",
     "data":[{"x":"Italy","y":91},{"x":"Spain","y":84}]}
    ```

    `type` is bar, line, area, scatter or pie. For several series, replace
    `data` with `series`: [{"name":"2025","data":[...]},...]. Values are numbers.

    Optional: "horizontal": true when category names are long; "stacked": false
    for side-by-side bars rather than stacked; "format": "compact" for large
    numbers (1.2M) or "percent".

    For a page, dashboard or mockup, put the markup in an `html` fence — it gets
    a Preview toggle and renders in place, so there's no need to write a file
    and open a browser. `svg` fences render as images. The preview is sandboxed:
    JavaScript runs, but external network requests are blocked, so inline your
    styles and scripts rather than linking a CDN.

    Honeycode has a built-in browser panel for local dev servers. Never run
    `open`, `xdg-open` or similar on a URL — just print it. The panel picks it
    up automatically and previews it beside the conversation.

    The panel is sandboxed the same way, and this catches people out: a page
    previewed there reaches this machine and nothing else. It applies to files
    served by a dev server exactly as it does to an `html` fence, so everything
    a page needs — libraries, fonts, workers, decoders — must be in the project
    beside it and referenced by a relative path. A CDN link renders as a blank
    page with no error in the console, because the request never leaves.
    """

    private static func locateClaude() -> URL? {
        let candidates = [
            NSHomeDirectory() + "/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map(URL.init(fileURLWithPath:))
    }

    // MARK: Sending

    /// Write a turn, or hold it until the one in flight finishes.
    ///
    /// **The CLI silently discards input written mid-turn.** Verified against
    /// 2.1.220: a turn written to stdin eight seconds into a long turn was
    /// never acknowledged — the first turn completed normally and the second
    /// produced no `result`, no error, nothing, for as long as the process was
    /// left running. It is not queued and it is not rejected; it is dropped.
    ///
    /// `Session.send` already holds messages while `isRunning`, and that is the
    /// guard that should normally do this job. This one exists because that
    /// guard is only as good as `isRunning`, which lives on the other side of a
    /// hop to the main queue and is set from several places — and the cost of
    /// it being wrong once is a message the user watched land in the transcript
    /// and never get answered, with nothing on screen to say so. The adapter
    /// knows for itself whether a turn is open, so it can refuse to write into
    /// the window where writes go nowhere.
    func send(_ text: String) {
        guard !turnInFlight else {
            held.append(text)
            return
        }
        turnInFlight = true
        write(text)
    }

    /// The next held message, if the turn that just ended left one waiting.
    private func flushHeld() {
        guard !held.isEmpty else { return }
        let next = held.removeFirst()
        turnInFlight = true
        write(next)
    }

    private func write(_ text: String) {
        pendingTurn = text
        lastPromptTokens = 0
        guard startIfNeeded() else { return }
        DispatchQueue.main.async { self.session.isRunning = true }

        let turn: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": [["type": "text", "text": text]]],
        ]
        // Nothing below is allowed to fail silently. A swallowed encode or a
        // broken pipe leaves the message on screen, the spinner running, and
        // no event coming that could ever end the turn — the session looks
        // busy forever over an error nobody was told about.
        guard var data = try? JSONSerialization.data(withJSONObject: turn) else {
            fail("Couldn't encode the message to send.")
            return
        }
        data.append(0x0A)                              // NDJSON: one object per line
        do {
            try inPipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            fail("Couldn't send the message: \(error.localizedDescription)")
        }
    }

    /// Abandon the turn and say why.
    private func fail(_ reason: String) {
        pendingTurn = nil
        teardown()
        DispatchQueue.main.async {
            self.session.append(.notice(id: UUID(), text: reason))
        }
    }

    func interrupt() {
        // Deliberately not guarded on `started`. Stop has to work when the
        // process is *already* gone, which is exactly the case a restart
        // mid-turn leaves behind: returning early there meant neither Esc nor
        // the stop button could clear the spinner, and the session was wedged
        // until the app was relaunched.
        //
        // Land whatever the pacer is still holding: it's text the model
        // actually produced, and dropping it would make a stop look like it
        // rewound the reply.
        deltas.flush()
        // A full teardown, not a bare `terminate()`. Two things depended on it:
        // the `Process` is spent once it has run, so keeping it meant the next
        // turn tried to relaunch a dead instance; and `teardown` clears the
        // termination handler *before* terminating, which is what stops a
        // deliberate stop from reporting itself as a crash — SIGTERM leaves a
        // non-zero status, so the handler used to append "claude exited
        // unexpectedly." to the transcript every single time you pressed Esc.
        //
        // A finer-grained mid-turn interrupt needs the control protocol, which
        // isn't wired up here.
        pendingTurn = nil
        // `teardown` clears the turn, the held messages and the spinner.
        // Dropping what was queued is the right reading of a stop, and matches
        // `Session.stop`: you interrupted the thing those messages were waiting
        // on, so sending them anyway is the opposite of stopping.
        teardown()
    }

    // MARK: Reading

    private func consume(_ chunk: Data) {
        lock.lock()
        buffer.append(chunk)
        // Scan for every newline first, then drop the consumed prefix once.
        // Removing each line as it was found re-packed the remaining buffer
        // per line, so a chunk carrying twenty lines shifted the tail twenty
        // times — quadratic in the size of the batch, on the reader thread of
        // the thing streaming at us.
        var lines: [Data] = []
        var start = buffer.startIndex
        while let nl = buffer[start...].firstIndex(of: 0x0A) {
            lines.append(buffer[start..<nl])
            start = buffer.index(after: nl)
        }
        if start > buffer.startIndex { buffer.removeSubrange(buffer.startIndex..<start) }
        lock.unlock()

        for line in lines where !line.isEmpty { route(line) }
    }

    private func route(_ line: Data) {
        guard let json = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = json["type"] as? String else { return }

        // Anything carrying actual conversation counts as the resume having
        // worked. A bare `result` does not — see below.
        if type == "stream_event" || type == "assistant" || type == "user" {
            sawContent = true
        }

        switch type {
        case "system" where json["subtype"] as? String == "init":
            // The init frame advertises the whole surface — commands, skills,
            // sub-agents, MCP servers — and every bit of it was being dropped
            // on the floor by the `default` below.
            let slash = json["slash_commands"] as? [String] ?? []
            let skills = Set(json["skills"] as? [String] ?? [])
            let commands = slash.map {
                AgentCommand(name: $0, isSkill: skills.contains($0))
            }
            DispatchQueue.main.async {
                self.session.commands = commands
                // The conversation exists from the moment `init` lands, which
                // is a truer signal than the process having launched — a launch
                // that dies before init leaves nothing to resume.
                if !self.session.hasStarted {
                    self.session.hasStarted = true
                    self.session.persist()
                }
            }

        case "system" where json["subtype"] as? String == "compact_boundary":
            let meta = json["compactMetadata"] as? [String: Any] ?? [:]
            let dropped = meta["cumulativeDroppedTokens"] as? Int
                ?? meta["preTokens"] as? Int ?? 0
            let trigger = meta["trigger"] as? String ?? "auto"
            emit(.compaction(id: UUID(), trigger: trigger, dropped: dropped))
            // The window is empty again — leaving the old figure would show
            // 95% against a context that now holds a summary and nothing else.
            DispatchQueue.main.async { self.session.context = nil }

        case "stream_event":
            guard let event = json["event"] as? [String: Any],
                  event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any] else { return }
            switch delta["type"] as? String {
            case "text_delta":
                if let t = delta["text"] as? String { deltas.append(t, thinking: false) }
            case "thinking_delta":
                if let t = delta["thinking"] as? String { deltas.append(t, thinking: true) }
            default: break
            }

        case "assistant":
            guard let message = json["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return }

            // Occupancy is read here, per API call — not from the `result`
            // frame, which totals them. See `promptTokens`.
            if let used = Self.promptTokens(message["usage"]) {
                lastPromptTokens = max(lastPromptTokens, used)
            }
            for block in content where block["type"] as? String == "tool_use" {
                let name = block["name"] as? String ?? "Tool"
                let input = block["input"] as? [String: Any] ?? [:]
                let useID = block["id"] as? String ?? ""

                // Plan bookkeeping folds into one live card rather than
                // appending a near-identical list on every update.
                switch name {
                case "TaskCreate":
                    let subject = input["subject"] as? String ?? "Task"
                    let active = input["activeForm"] as? String
                    // Through `onMain` like every other append: the plan card
                    // is inserted the first time a task is created, and it
                    // splits a sentence exactly the way a tool card does.
                    onMain {
                        self.session.createTodo(subject: subject, activeForm: active)
                    }
                    continue
                case "TaskUpdate":
                    guard let taskID = input["taskId"] as? String else { continue }
                    let status = input["status"] as? String
                    let subject = input["subject"] as? String
                    let active = input["activeForm"] as? String
                    DispatchQueue.main.async {
                        self.session.updateTodo(id: taskID, status: status,
                                                subject: subject, activeForm: active)
                    }
                    continue
                case "TaskList", "TaskGet":
                    continue        // pure reads of state the card already shows
                case "WebSearch":
                    emit(.search(id: UUID(), toolUseID: useID,
                                 query: input["query"] as? String ?? "",
                                 results: [], state: .pending))
                    continue
                default:
                    break
                }

                // Edits get the review surface instead of a one-line row —
                // seeing the change is the whole reason to be in a GUI.
                if let (file, rows) = Self.diff(tool: name, input: input), !rows.isEmpty {
                    emit(.diff(id: UUID(), toolUseID: useID, file: file,
                               rows: rows, state: .pending))
                    continue
                }
                let (target, detail) = Self.describe(tool: name, input: input)
                emit(.tool(id: UUID(), toolUseID: useID, name: name, target: target,
                           detail: detail, state: .pending))
            }

        case "user":
            // Tool results come back as a user turn. This is what turns a
            // proposed card into an applied or declined one.
            guard let message = json["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return }
            for block in content where block["type"] as? String == "tool_result" {
                let useID = block["tool_use_id"] as? String ?? ""
                let isError = block["is_error"] as? Bool ?? false
                let text = Self.resultText(block["content"])
                let state: ToolState = isError ? Self.errorState(text) : .applied
                // Matched here, on the reader queue. A `Read` of a large file
                // comes back as a couple of megabytes, and scanning it for a
                // loopback URL inside the main-queue block that resolves the
                // card ran that regular expression in the middle of a frame.
                let server = DevServer.find(in: text)
                DispatchQueue.main.async {
                    self.session.resolve(toolUseID: useID, state: state, text: text)
                    if let server { self.session.noticeDevServer(server) }
                }
            }

        case "rate_limit_event":
            guard let info = json["rate_limit_info"] as? [String: Any] else { return }
            let limit = RateLimit(
                status: info["status"] as? String ?? "allowed",
                resetsAt: (info["resetsAt"] as? Double).map(Date.init(timeIntervalSince1970:)),
                kind: info["rateLimitType"] as? String,
                usingOverage: info["isUsingOverage"] as? Bool ?? false,
                // `overageStatus` is "rejected" when overage isn't available —
                // typically with `overageDisabledReason: out_of_credits`.
                overageAvailable: (info["overageStatus"] as? String) != "rejected")
            DispatchQueue.main.async { self.session.rateLimit = limit }

        case "result":
            let cost = json["total_cost_usd"] as? Double ?? 0
            let failed = json["is_error"] as? Bool ?? false
            let errors = (json["errors"] as? [String])?.joined(separator: "\n") ?? ""

            // A stale `--resume` does *not* die quietly. It prints
            // "No conversation found with session ID: …" and then emits a
            // perfectly normal-looking `result` with `is_error` set and no
            // content before it. An earlier version of this checked only
            // whether the process had written anything, which this defeats:
            // the turn would have ended silently with nothing on screen.
            if failed, launchedResuming, !sawContent, !resumeFallbackUsed {
                DispatchQueue.main.async { self.recoverFromStaleResume() }
                return
            }

            // How full the window is: the largest prompt any single call in
            // this turn sent, against the window the result frame names.
            let used = lastPromptTokens
            let context = Self.window(json).flatMap { window in
                used > 0 ? ContextUsage(used: min(used, window), window: window) : nil
            }

            pendingTurn = nil
            // Land the tail of the reply before the turn is marked done,
            // otherwise the last batch arrives after the caret is removed.
            DispatchQueue.main.async { self.deltas.flush() }
            DispatchQueue.main.async {
                // Cleared here rather than on the reader thread: `send` runs on
                // the main queue, so keeping every access to `turnInFlight` and
                // `held` on that one queue is what makes them safe to touch
                // without a lock. A send arriving in the gap is held, and the
                // flush two lines down picks it straight back up.
                self.turnInFlight = false
                if failed, !errors.isEmpty {
                    self.session.append(.notice(id: UUID(), text: errors))
                }
                if let context { self.session.context = context }
                self.session.endTurn(cost: cost)
                // After `endTurn`, so anything held goes out against a session
                // that has already been marked idle — and so the transcript
                // shows the finished reply before the next question opens.
                self.flushHeld()
            }

        default:
            break
        }
    }

    /// Rejoining failed, so create the conversation instead — same id, so the
    /// restored transcript keeps its identity — and replay the turn that was
    /// in flight. The notice matters: without it the reply would look like a
    /// normal continuation of a transcript the agent can no longer see.
    private func recoverFromStaleResume() {
        resumeFallbackUsed = true
        session.hasStarted = false
        // The `result` that brought us here returned before the turn was marked
        // closed. `teardown` clears it, which is what lets the replay below go
        // through `send` — otherwise it would hold the very turn it is retrying,
        // waiting on one that has already failed.
        teardown()
        if !session.items.isEmpty {
            session.append(.notice(id: UUID(), text:
                "Couldn't rejoin the previous conversation, so this one starts fresh. "
                + "The transcript above is still here, but the agent can't see it."))
        }
        if let turn = pendingTurn { send(turn) }
    }

    /// Hop to the main queue, having first landed every delta that came before
    /// this event on the wire.
    ///
    /// Text is paced by `DeltaCoalescer` and released a frame at a time;
    /// everything else went straight to the main queue. So a tool call arriving
    /// mid-sentence *overtook* the tail of that sentence: the card landed,
    /// `beginAssistant` saw a non-assistant item last, and the remaining
    /// characters opened a second block. That is the reply that reads
    /// "…the selection strategy in th" — card — "e wiki.", split at whatever
    /// character the pacer happened to have reached.
    ///
    /// Flushing first restores wire order at the only points where it can be
    /// observed. Nothing else changes: between tool calls the pacing runs
    /// exactly as before, and that's where all of it is visible anyway.
    private func onMain(_ work: @escaping () -> Void) {
        DispatchQueue.main.async {
            self.deltas.flush()
            work()
        }
    }

    private func emit(_ item: TranscriptItem) {
        onMain { self.session.append(item) }
    }

    /// The prompt size of a single API call.
    ///
    /// The three input figures together *are* the prompt — fresh tokens, tokens
    /// written to cache, and tokens read back from it — so their sum is what
    /// the model was holding for that one call.
    private static func promptTokens(_ raw: Any?) -> Int? {
        guard let usage = raw as? [String: Any] else { return nil }
        let used = (usage["input_tokens"] as? Int ?? 0)
            + (usage["cache_creation_input_tokens"] as? Int ?? 0)
            + (usage["cache_read_input_tokens"] as? Int ?? 0)
        return used > 0 ? used : nil
    }

    /// Context occupancy for the turn that just ended.
    ///
    /// The `used` figure comes from the assistant frames, not from here, and
    /// that distinction is the whole point of this comment.
    ///
    /// A `result` frame's `usage` is the turn's *total* across every API call
    /// it took — and an agentic turn is one call per tool round-trip, each of
    /// which re-reads the entire cached prefix. So `cache_read_input_tokens`
    /// gets counted again for every tool the agent ran. Measured on a
    /// six-tool turn: each assistant frame reported ~24,000 tokens of prompt,
    /// the seven of them summing to the 168,429 the `result` frame declared.
    /// Reading occupancy from here therefore overstated it by roughly the
    /// round-trip count, which is how a session on a 1,000,000-token window
    /// came to have 14,071,235 recorded against it.
    ///
    /// The largest single call is the right answer: the prompt only grows
    /// within a turn, so the last one holds everything the model still had.
    ///
    /// `modelUsage` is still read from here — the window size per model is
    /// stated nowhere else in the stream.
    private static func window(_ json: [String: Any]) -> Int? {
        let models = json["modelUsage"] as? [String: [String: Any]] ?? [:]
        let window = models.values.compactMap { $0["contextWindow"] as? Int }.max() ?? 0
        return window > 0 ? window : nil
    }

    /// Refusal or failure?
    ///
    /// stream-json gives one `is_error` flag for both, so this leans on the
    /// flag the process was launched with: with permissions skipped, nothing
    /// *can* be refused, so every error is a genuine failure. Only with the
    /// toggle off is the CLI's own refusal wording worth matching — and even
    /// then anything unrecognised is treated as a failure, since claiming a
    /// tool was blocked when it merely broke is the worse mistake.
    private static func errorState(_ text: String) -> ToolState {
        guard !skipPermissions else { return .failed(text) }
        let lowered = text.lowercased()
        let refused = lowered.contains("haven't granted")
            || lowered.contains("requested permissions")
            || lowered.contains("permission to use")
        return refused ? .declined(text) : .failed(text)
    }

    /// `tool_result.content` is either a plain string or an array of blocks.
    private static func resultText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }

    /// Build a unified diff for an edit, against the file as it stands *now*.
    ///
    /// The tool_use event arrives before the write lands, so reading the file
    /// here gives the pre-edit content — exactly the left-hand side we want.
    /// Reconstructing the whole file rather than diffing the fragment keeps the
    /// gutter line numbers absolute and true to the file.
    private static func diff(tool: String, input: [String: Any]) -> (String, [DiffRow])? {
        guard let path = input["file_path"] as? String else { return nil }
        let home = NSHomeDirectory()
        let label = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        let current = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""

        switch tool {
        case "Write":
            guard let content = input["content"] as? String else { return nil }
            return (String(label), Diff.rows(from: current, to: content))

        case "Edit":
            guard let old = input["old_string"] as? String,
                  let new = input["new_string"] as? String else { return nil }
            // If the file isn't readable, fall back to diffing the fragments —
            // line numbers become relative, which beats showing nothing.
            guard !current.isEmpty, let first = current.range(of: old) else {
                return (String(label), Diff.rows(from: old, to: new))
            }
            // First occurrence only, unless the call said otherwise.
            //
            // `replacingOccurrences` replaces *every* match, which is not what
            // the Edit tool does: it rewrites one site unless `replace_all` is
            // set. A string appearing at three places therefore drew three
            // edits and a +/− tally three times too large — for a change that
            // landed once. Those numbers flow on into the Changes sheet and
            // the pull-request description, so the card wasn't the only thing
            // misstating what happened to the file.
            let all = input["replace_all"] as? Bool ?? false
            let edited = all
                ? current.replacingOccurrences(of: old, with: new)
                : current.replacingCharacters(in: first, with: new)
            return (String(label), Diff.rows(from: current, to: edited))

        default:
            return nil
        }
    }

    /// Turn a tool call into a one-line summary plus optional expandable body.
    /// The summary is what appears in the transcript; a wall of raw JSON there
    /// is the fastest way to make the view unreadable.
    private static func describe(tool: String, input: [String: Any]) -> (String, String) {
        let home = NSHomeDirectory()
        func short(_ path: String) -> String {
            path.hasPrefix(home)
                ? "~" + path.dropFirst(home.count)
                : URL(fileURLWithPath: path).lastPathComponent
        }
        if let command = input["command"] as? String {
            // Collapse every home path in the command, not just a leading one —
            // a `cp ~/a ~/b` line has two, and an absolute pair eats the row.
            let collapsed = command.replacingOccurrences(of: home, with: "~")
            // Full text goes to the disclosure; the row gets a readable head.
            return (collapsed, collapsed.count > 96 ? collapsed : "")
        }
        if let path = input["file_path"] as? String {
            let body = (input["content"] as? String)
                ?? (input["new_string"] as? String) ?? ""
            return (short(path), body)
        }
        if let pattern = input["pattern"] as? String { return (pattern, "") }
        if let prompt = input["prompt"] as? String { return (prompt, "") }
        if let url = input["url"] as? String { return (url, "") }
        return ("", "")
    }
}
