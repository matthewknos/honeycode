import Foundation

/// What a session needs from whichever agent is behind it.
///
/// The two CLIs share almost nothing at the wire level — Claude speaks a bespoke
/// NDJSON stream, Copilot speaks JSON-RPC — so the seam is drawn here, at the
/// three verbs a session actually performs, rather than at some shared notion
/// of an "event" that would only ever be the union of both.
protocol AgentAdapter: AnyObject {
    func send(_ text: String)
    func interrupt()
    /// Called when model or effort changes.
    func restart()
    /// Throw the agent-side conversation away.
    ///
    /// Distinct from `restart`, which keeps the conversation and only wants a
    /// process launched with different flags. This is `/clear`: the session
    /// keeps its identity and its directory, and everything said in it — here
    /// and in the agent — is gone. Both implementations tear the process down
    /// rather than trying to unwind it in place, because the next `send`
    /// relaunches against a conversation id the session has already replaced.
    func reset()
    /// Connect ahead of the first message, if there's anything to be gained by
    /// it. Called when the session comes on screen.
    func prepare()
}

extension AgentAdapter {
    /// Most adapters have nothing to do here — Claude reads its model list from
    /// a file on disk, so spawning a process early would buy nothing and cost a
    /// child process per session at launch.
    func prepare() {}
}

/// Drives one long-lived `copilot --acp` process over the Agent Client Protocol.
///
/// ACP is a much friendlier surface than Claude's stream-json, and the
/// difference shows up in three places:
///
/// - **Framing is newline-delimited JSON-RPC 2.0**, not LSP `Content-Length`.
///   Worth stating because every ACP client library assumes the latter.
/// - **Permission is a real request.** `session/request_permission` arrives with
///   an `id`, so the agent genuinely blocks on the answer. Claude has no
///   equivalent, which is why it needs `--dangerously-skip-permissions` and this
///   doesn't.
/// - **Tool calls carry a structured diff** — `content: [{type: "diff", oldText,
///   newText}]` — so the review surface gets real before/after text instead of
///   this adapter having to parse the git-format string that sits alongside it.
///
/// One gotcha: Copilot's default model can be `kimi-k2.7-code`, which rejects
/// the reasoning effort the CLI sends and fails the very first turn with a bare
/// error string. Setting the model explicitly is not optional.
///
/// Two agents share this: GitHub Copilot and Kimi Code. They differ in what to
/// launch and where the model list sits, and nothing else — see `ACPAgent`,
/// which holds those differences so this file doesn't have to know either name.
final class ACPAdapter: AgentAdapter {

    private unowned let session: Session
    /// Which CLI this instance drives.
    private let agent: ACPAgent
    private var process = Process()
    private var inPipe = Pipe()
    private var outPipe = Pipe()
    private var errPipe = Pipe()
    private var started = false

    private var buffer = Data()
    private let lock = NSLock()

    /// JSON-RPC request id, ours. The agent numbers its own requests
    /// independently and they can collide, which is fine — direction
    /// disambiguates.
    private var nextID = 1
    private var sessionID: String?
    /// Which handshake request is outstanding. `session/load` replies with a
    /// model list and *no* `sessionId`, so it can't be recognised by shape the
    /// way `session/new` can — the id has to be tracked.
    private var loadID: Int?
    private var newID: Int?
    /// True from the moment `session/load` is sent until the next prompt.
    ///
    /// Loading replays the entire prior conversation back as `session/update`
    /// notifications — verified: `user_message_chunk` then `agent_message_chunk`
    /// for every earlier turn. Since the transcript has already been restored
    /// from disk, complete with the tool cards the replay doesn't carry, those
    /// updates would append a second copy of everything. Dropping until the
    /// user's next message is airtight, because nothing else can produce
    /// updates in that window.
    private var replaying = false
    /// Whether this process has already been handed the shared skills index.
    /// Reset with the process, not with the turn — see `preface`.
    private var sentSkills = false
    /// Prompts typed before the handshake finished, replayed once it has.
    /// At most one, now that `send` holds anything arriving mid-turn.
    private var queued: [String] = []
    /// Whether a `session/prompt` is outstanding, and anything waiting for it.
    ///
    /// The Claude adapter has had this since a message could be written into a
    /// window where writes go nowhere; this one never did, and the cost was
    /// worse than a lost message. **Two `session/prompt` requests in flight on
    /// one ACP session make the agent emit its answer twice.** Measured against
    /// Kimi Code: two prompts sent back to back, the first asking for ten
    /// characters, produced twenty — one reply, streamed once per outstanding
    /// prompt, both requests answered `end_turn`. Both copies land in the same
    /// `.assistant` item with independent chunk boundaries, so what reaches the
    /// transcript is the reply shuffled into itself:
    ///
    ///     AnsAnswweringering @ @kimikimi#3 from#3 from what what I've I've
    ///
    /// `Session.deliver` is supposed to prevent this and cannot: it guards on
    /// `isRunning`, which is set a hop later on the main queue, so two delivers
    /// in one runloop turn both see an idle session. The adapter is the only
    /// thing that knows for certain whether a turn is open.
    private var turnInFlight = false
    private var held: [String] = []
    /// The id of the in-flight `session/prompt`, so its result ends the turn.
    private var promptID: Int?
    /// Where the transcript stood when this turn's prompt went out, so the turn
    /// can be asked whether it produced anything. See `reportSilentTurn`.
    private var promptMark = 0
    /// A bookkeeping prompt we sent ourselves. Both are answered by the CLI
    /// itself rather than by a model — verified over ACP: they return instantly
    /// and register as 0 AI Units — so asking after every turn costs nothing.
    /// Their replies are captured rather than appended to the transcript.
    private enum Probe { case usage, context }
    private var probe: (id: Int, kind: Probe)?
    private var probeText = ""
    /// What the session had already spent before this process existed.
    ///
    /// `/usage` counts from process start, not from the beginning of the
    /// conversation: `session/load` on a session with 66 turns in it still
    /// reports `0 AI Units`. Resuming would otherwise reset the tally to zero
    /// and count the same conversation twice over its life.
    private var unitsBase: Double?

    /// What each tool card has already been told, per call.
    ///
    /// Kimi streams a tool's arguments as *text* — the raw JSON grows a token at
    /// a time across `tool_call_update`s — and never sends `rawInput` at all.
    /// So the path and the file content only exist once that text is complete,
    /// which is why the card starts as a bare row and is upgraded in place.
    ///
    /// These record what was last derived from that text rather than the text
    /// itself. The previous version kept every call's full argument string —
    /// which for a write is the whole file — for the life of the process,
    /// never read it, and didn't clear it in `teardown`.
    private var toolContent: [String: String] = [:]
    private var toolTarget: [String: String] = [:]

    private let deltas = DeltaCoalescer()

    init(session: Session, agent: ACPAgent) {
        self.session = session
        self.agent = agent
        deltas.onFlush = { [weak self] batch in
            guard let session = self?.session else { return }
            for run in batch {
                if run.thinking { session.appendThinking(run.text) }
                else { session.appendAssistant(run.text) }
            }
        }
    }

    // MARK: Lifecycle

    private func startIfNeeded() -> Bool {
        if started { return true }
        guard let binary = locateBinary() else {
            emit(.notice(id: UUID(), text:
                "Couldn't find the `\(agent.displayName)` binary."))
            return false
        }

        process.executableURL = binary
        process.currentDirectoryURL = session.directory
        process.arguments = agent.arguments
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in agent.environment(binary: binary) { environment[key] = value }
        process.environment = environment
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let self else { return }
            self.consume(chunk)
        }

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            let err = self.errPipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(decoding: err, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                // Reset before anything else: leaving `started` true meant the
                // next `send` believed it had a live process, wrote into a
                // closed pipe — swallowed — and left a spinner that nothing
                // could ever stop. And a `Process` can't be relaunched once
                // it has run, so reusing this one would raise an Objective-C
                // exception that Swift can't catch. Same gap as the Claude
                // adapter had, with the same two consequences.
                self.teardown()
                if proc.terminationStatus != 0 {
                    // Always the sentence first, and the diagnostic after it if
                    // there is one worth having. Emitting bare stderr meant a
                    // Node object dump stood in the transcript as the agent's
                    // own words — see `Diagnostic`.
                    let detail = Diagnostic.summarise(text)
                    self.session.items.append(.notice(id: UUID(), text:
                        "\(self.agent.displayName) exited unexpectedly."
                        + (detail.isEmpty ? "" : " " + detail)))
                }
            }
        }

        do {
            try process.run()
            started = true
        } catch {
            emit(.notice(id: UUID(), text:
                "Couldn't start \(agent.displayName): \(error.localizedDescription)"))
            return false
        }

        request("initialize", params: [
            "protocolVersion": 1,
            // No filesystem delegation: the agent reads and writes directly
            // rather than round-tripping every byte through this process.
            "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false]],
        ])
        return true
    }

    /// A turn that ended having produced nothing at all, said out loud.
    ///
    /// This is the failure this file's own troubleshooting note describes and
    /// never detected. Over ACP a CLI that has failed does not say so: the
    /// turn comes back `{"stopReason":"end_turn"}` with no content, no error
    /// object and nothing on stderr, and it is indistinguishable from an agent
    /// that genuinely had nothing to add. Measured against Kimi Code with a
    /// spent quota — `kimi -p` prints `403 You've reached your usage limit for
    /// this billing cycle`, and the same CLI over ACP returns a bare
    /// `end_turn`. The expired-login and TLS-failure cases look identical.
    ///
    /// So the *symptom* is what gets reported, because it is the only thing
    /// visible from here, and it is reported as a suspicion rather than a
    /// diagnosis: this code cannot know which of the three it is, and the one
    /// command that can is the one worth printing.
    ///
    /// Emitting it as a notice rather than swallowing it is what lets `Crew`
    /// act on it — see `Crew.trouble`. Without this the crew sees an empty
    /// reply, calls the delegate empty-handed, and buys the same refusal again
    /// on a fresh seat of the same exhausted subscription.
    private func reportSilentTurn() {
        let produced = session.items.dropFirst(max(0, promptMark)).contains { item in
            switch item {
            case .assistant(_, let text):
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .thinking(_, let text, _, _):
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .tool, .diff, .search:
                return true
            default:
                return false
            }
        }
        guard !produced else { return }
        session.items.append(.notice(id: UUID(), text:
            "\(agent.displayName) ended the turn without producing anything — no text, "
            + "no tools, no files. Over ACP that is what a failure inside the CLI looks "
            + "like: the turn ends normally with no content and no error, so the reason "
            + "can't be seen from here. Run `\(agent.command) -p \"hi\"` in a terminal to "
            + "get it — a spent quota, an expired login and a TLS failure all look "
            + "exactly like this."))
    }

    private func locateBinary() -> URL? {
        agent.binaryCandidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map(URL.init(fileURLWithPath:))
    }

    private func teardown() {
        outPipe.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        try? inPipe.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        process = Process()
        inPipe = Pipe(); outPipe = Pipe(); errPipe = Pipe()
        lock.lock(); buffer = Data(); lock.unlock()
        sessionID = nil
        promptID = nil
        loadID = nil
        newID = nil
        probe = nil
        probeText = ""
        // Re-read from the session next time: the new process starts its own
        // credit count from zero, and whatever it reports has to be added to
        // what the conversation had already spent.
        unitsBase = nil
        replaying = false
        // A new process is a new context, so the index goes again — and a
        // restart is exactly how a skill you just switched on takes effect.
        sentSkills = false
        queued = []
        // A `turnInFlight` left set would hold every later message for a turn
        // that can no longer end, so the session would go mute permanently
        // rather than once. Held messages go with it — they were waiting on the
        // turn this just killed.
        turnInFlight = false
        held.removeAll()
        // Tool ids belong to the process that issued them, and a write's
        // content is a whole file — holding either past the process that named
        // them is a leak with nothing to spend it on.
        toolContent = [:]
        toolTarget = [:]
        started = false
        // Killing the process ends the turn, and saying so here rather than at
        // each call site is what stops a `reset()` mid-turn from leaving a
        // spinner nothing can clear — the termination handler is unhooked
        // before the kill, so it isn't coming to do it. Same fix, same reason,
        // as the Claude adapter.
        DispatchQueue.main.async { self.session.isRunning = false }
    }

    // MARK: Sending

    /// Handshake now rather than on the first message.
    ///
    /// The model list is the reason. It only exists in the `session/new` reply,
    /// so deferring the connection meant the picker showed a hardcoded guess at
    /// exactly the moment you'd use it — before typing anything. `initialize` +
    /// `session/new` costs nothing until a prompt is sent, and the session this
    /// creates is the one the first message will use, so nothing is wasted.
    func prepare() { _ = startIfNeeded() }

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
        guard startIfNeeded() else {
            turnInFlight = false
            return
        }
        DispatchQueue.main.async { self.session.isRunning = true }

        // Still shaking hands. `queued` can only ever hold this one, because
        // `send` won't write another until this turn ends.
        guard let sessionID else { queued.append(text); return }
        prompt(text, in: sessionID)
    }

    private func prompt(_ text: String, in sessionID: String) {
        replaying = false
        promptMark = session.items.count
        promptID = request("session/prompt", params: [
            "sessionId": sessionID,
            "prompt": [["type": "text", "text": preface() + text]],
        ])
    }

    /// The shared skills index, once per session.
    ///
    /// ACP has no system prompt — `session/new` takes a cwd and a set of
    /// capabilities and nothing else — so the only way in is the first message.
    /// Once, not on every turn: it's context the agent keeps, and repeating it
    /// each time would spend the window on a list it has already read.
    ///
    /// This is why the skills index is descriptions and paths rather than the
    /// instructions themselves. On Claude a bloated preamble costs a launch
    /// flag; here it would cost the top of the conversation.
    private func preface() -> String {
        guard !sentSkills else { return "" }
        sentSkills = true
        let preamble = Skills.preamble()
        return preamble.isEmpty ? "" : preamble + "\n\n"
    }

    /// Model changes go over the wire — unlike Claude, where they're launch
    /// flags and cost a process restart. Effort has no ACP equivalent and is
    /// simply not sent.
    func restart() {
        guard started, let sessionID else { return }
        setModel(in: sessionID)
    }

    /// Drop the process, and with it `sessionID`, the tool bookkeeping and the
    /// credit baseline. The next prompt handshakes from scratch, and because
    /// the session has cleared `hasStarted` it creates rather than loads.
    func reset() {
        guard started else { return }
        if let sessionID { notify("session/cancel", params: ["sessionId": sessionID]) }
        teardown()
    }

    private func setModel(in sessionID: String) {
        let call = agent.setModelRequest(sessionID: sessionID, modelID: session.model.id)
        request(call.method, params: call.params)
    }

    func interrupt() {
        // The cancel needs a live process to go to; clearing the spinner does
        // not, and must happen either way. Guarding the whole method on
        // `started` meant a stop after the process was already gone did
        // nothing at all, which is the one case where the user is pressing it
        // because the session looks stuck.
        if started, let sessionID {
            notify("session/cancel", params: ["sessionId": sessionID])
        }
        promptID = nil
        turnInFlight = false
        // Held messages go with the turn they were queued behind. Sending them
        // now would answer, on a cancelled run, questions nobody is waiting for.
        held.removeAll()
        DispatchQueue.main.async { self.session.isRunning = false }
    }

    // MARK: JSON-RPC plumbing

    @discardableResult
    private func request(_ method: String, params: [String: Any]) -> Int {
        let id = nextID
        nextID += 1
        write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        return id
    }

    private func notify(_ method: String, params: [String: Any]) {
        write(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func respond(to id: Any, result: [String: Any]) {
        write(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func write(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        lock.lock()
        try? inPipe.fileHandleForWriting.write(contentsOf: data)
        lock.unlock()
    }

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

    // MARK: Routing

    private func route(_ line: Data) {
        guard let json = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        else { return }

        // A message with a `method` is inbound; one without is a reply to us.
        if let method = json["method"] as? String {
            handle(method: method, json: json)
        } else if let id = json["id"] as? Int {
            handle(replyID: id, json: json)
        }
    }

    private func handle(method: String, json: [String: Any]) {
        let params = json["params"] as? [String: Any] ?? [:]

        switch method {
        case "session/update":
            guard let update = params["update"] as? [String: Any] else { return }
            // The command list arrives during the load replay and isn't
            // conversation, so it has to pass the suppression gate.
            let kind = update["sessionUpdate"] as? String
            guard !replaying || kind == "available_commands_update" else { return }
            handle(update: update)

        case "session/request_permission":
            guard let id = json["id"] else { return }
            let options = params["options"] as? [[String: Any]] ?? []
            handlePermission(id: id, params: params, options: options)

        default:
            // `available_commands_update`, `config_option_update` and the
            // filesystem methods we opted out of all land here. Ignored on
            // purpose — replying to a notification is a protocol error.
            break
        }
    }

    private func handle(replyID id: Int, json: [String: Any]) {
        if let error = json["error"] as? [String: Any] {
            // A load that fails means the agent no longer has this
            // conversation. Starting a new one keeps the session usable; the
            // notice is there so it never looks like the agent remembers a
            // transcript it can't see.
            if id == loadID {
                loadID = nil
                replaying = false
                session.hasStarted = false
                // Only worth saying when there was something to lose. On an
                // empty transcript it's noise about a conversation you never had.
                if !session.items.isEmpty {
                    emit(.notice(id: UUID(), text:
                        "Couldn't rejoin the previous conversation, so this one starts "
                        + "fresh. The transcript above is still here, but the agent "
                        + "can't see it."))
                }
                newID = request("session/new", params: [
                    "cwd": session.directory.path,
                    "mcpServers": [],
                ])
                return
            }
            let message = error["message"] as? String
                ?? "\(agent.displayName) returned an error."
            // An error ends the turn as firmly as a result does. Without this,
            // one refused prompt leaves `turnInFlight` set and every later
            // message is held for a turn that can never end — the session goes
            // mute permanently rather than once, which is strictly worse than
            // the overlap the flag exists to prevent.
            let wasOurs = id == promptID
            if wasOurs { promptID = nil }
            DispatchQueue.main.async {
                self.session.isRunning = false
                if wasOurs {
                    self.turnInFlight = false
                    self.flushHeld()
                }
            }
            emit(.notice(id: UUID(), text: message))
            return
        }
        let result = json["result"] as? [String: Any] ?? [:]

        // The handshake is a chain: initialize → load-or-new → set_model → the
        // queued prompt. Each step is driven by the previous one's reply rather
        // than by a timer, so a slow machine can't race it.
        if result["protocolVersion"] != nil {
            if session.hasStarted {
                replaying = true
                loadID = request("session/load", params: [
                    "sessionId": session.conversationID,
                    "cwd": session.directory.path,
                    "mcpServers": [],
                ])
            } else {
                newID = request("session/new", params: [
                    "cwd": session.directory.path,
                    "mcpServers": [],
                ])
            }
            return
        }

        if id == loadID {
            loadID = nil
            adoptModels(from: result)
            ready(session.conversationID)
            return
        }

        if id == newID, let created = result["sessionId"] as? String {
            newID = nil
            adoptModels(from: result)
            session.conversationID = created
            // Deliberately *not* `hasStarted = true` here.
            //
            // Copilot doesn't persist a session until it has actually been
            // used: `session/load` on a created-but-never-prompted id returns
            // "Session not found". Marking it started on creation meant every
            // launch tried to rejoin a session that had never existed on disk,
            // failed, posted a notice, created another orphan, and repeated —
            // which is the stack of "couldn't rejoin" lines. It becomes
            // started when a turn completes, below.
            ready(created)
            return
        }

        if let probe, probe.id == id {
            finish(probe.kind)
            return
        }

        if id == promptID {
            promptID = nil
            // A completed turn is what makes the session loadable.
            if !session.hasStarted {
                session.hasStarted = true
                session.persist()
            }
            // ACP reports no cost — there is no `total_cost_usd` equivalent —
            // so a Copilot session's tally stays at zero rather than being
            // filled with a guess. What the agent will tell us instead is
            // credits and context, which the probes below go and ask for.
            DispatchQueue.main.async { self.deltas.flush() }
            DispatchQueue.main.async {
                // On the main queue, so every touch of `turnInFlight` and
                // `held` happens there and neither needs a lock — the same
                // arrangement the Claude adapter uses, for the same reason.
                self.turnInFlight = false
                // Before `endTurn`, so whatever is waiting on the turn — the
                // crew, above all — sees the notice as part of this turn rather
                // than after it has already judged the turn empty.
                self.reportSilentTurn()
                self.session.endTurn()
                // After `endTurn`, so anything held goes out against a session
                // already marked idle.
                self.flushHeld()
            }
            ask(.usage)
        }
    }

    // MARK: Bookkeeping probes

    /// Ask the agent about itself, while the session is idle.
    private func ask(_ kind: Probe) {
        guard let sessionID else { return }
        // An agent that doesn't know the command must not be sent it. A slash
        // command a CLI doesn't recognise is not an error, it's a prompt — it
        // reaches the model as literal text, costs a request, and comes back as
        // a puzzled paragraph. See `ACPAgent.UsageKind.none`.
        guard agent.usageReports != .none else { return }
        probeText = ""
        let command = kind == .usage ? "/usage" : "/context"
        probe = (request("session/prompt", params: [
            "sessionId": sessionID,
            "prompt": [["type": "text", "text": command]],
        ]), kind)
    }

    /// One probe's reply, in full.
    private func finish(_ kind: Probe) {
        let text = probeText
        probeText = ""
        probe = nil

        switch kind {
        case .usage:
            switch agent.usageReports {
            case .credits:
                if let units = Self.aiUnits(in: text) {
                    let base = unitsBase ?? session.aiUnits ?? 0
                    unitsBase = base
                    DispatchQueue.main.async { self.session.aiUnits = base + units }
                }
                // And the rest of the reply, which was being read and dropped.
                //
                // `aiUnits` is what this *conversation* has spent; the same
                // answer also carries what the *subscription* has left, which
                // is the figure a crew needs before it decides who gets the
                // biggest piece and the only one Copilot publishes at all. It
                // has been arriving after every turn since this adapter was
                // written and going nowhere.
                //
                // Only here, and deliberately not under `.context`. Kimi
                // answers `/usage` with its context window — a percentage, in
                // the same shape, meaning something completely different — and
                // ingesting that would put a ring on the rail claiming a
                // subscription was two-thirds spent when what was two-thirds
                // full was one conversation's prompt.
                let account = session.account
                Task { @MainActor in UsageStore.shared.ingest(text, for: account) }
            case .context:
                adopt(Self.context(in: text))
            case .none:
                break
            }
            // Chained rather than sent together: two prompts in flight at once
            // on one ACP session would interleave their chunks, and there'd be
            // no way to tell whose text was whose.
            if agent.hasContextCommand { ask(.context) }

        case .context:
            adopt(Self.context(in: text))
        }
    }

    /// Empty until the agent has built its context — the reply on a fresh
    /// session is "not yet available", or a flat zero, neither of which is worth
    /// writing over a real figure.
    private func adopt(_ usage: ContextUsage?) {
        guard let usage, usage.window > 0 else { return }
        DispatchQueue.main.async {
            self.session.context = usage
            // Every turn re-sends the whole window, so summing what was in it at
            // each turn's end is the closest thing to cumulative input an ACP
            // agent will tell us. It's a floor, not a meter: a turn that runs
            // six tools sends the context six times, and the CLI rounds before
            // we ever see it.
            self.session.tokensSent += usage.used
            self.session.persist()
        }
    }

    /// "Requests: 1.33 AI Units (12s)" — the only per-session credit figure
    /// either agent exposes. Deriving it from model multipliers would be a
    /// guess; this is the agent's own count.
    ///
    /// Note this is *not* the `AI Credits 2.01` line the CLI prints in a
    /// terminal. That footer is drawn by the interactive front end and never
    /// crosses the ACP wire; over the protocol the wording is still "AI Units".
    private static func aiUnits(in text: String) -> Double? {
        guard let regex = try? NSRegularExpression(
                pattern: #"Requests:\s*([\d.]+)\s*AI Units"#),
              let match = regex.firstMatch(
                in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Double(text[range])
    }

    /// `/context` draws a bar chart; the line that carries the numbers reads
    /// `kimi-k2.7-code · 28k/256k tokens (11%)`. Matched loosely on purpose —
    /// the chart around it is decoration and liable to be restyled.
    private static func context(in text: String) -> ContextUsage? {
        guard let regex = try? NSRegularExpression(
                pattern: #"([\d.,]+[kKmM]?)\s*/\s*([\d.,]+[kKmM]?)(?:\s*tokens)?"#),
              let match = regex.firstMatch(
                in: text, range: NSRange(text.startIndex..., in: text)),
              let usedRange = Range(match.range(at: 1), in: text),
              let windowRange = Range(match.range(at: 2), in: text),
              let used = Self.count(String(text[usedRange])),
              let window = Self.count(String(text[windowRange])) else { return nil }
        return ContextUsage(used: used, window: window)
    }

    /// `28k` → 28,000. The CLI has already rounded for display, so nothing
    /// downstream is more precise than this is.
    private static func count(_ text: String) -> Int? {
        // Kimi prints grouped thousands — `262,144` — where Copilot prints `256k`.
        var digits = text.replacingOccurrences(of: ",", with: "")
        var scale = 1.0
        switch digits.last {
        case "k", "K": scale = 1_000;     digits.removeLast()
        case "m", "M": scale = 1_000_000; digits.removeLast()
        default: break
        }
        guard let value = Double(digits) else { return nil }
        return Int((value * scale).rounded())
    }

    /// Both `session/new` and `session/load` reply with the account's real
    /// model list, complete with usage multipliers. It's the only honest source
    /// for what a Copilot seat can run, so the picker takes it over whatever
    /// was assumed beforehand.
    private func adoptModels(from result: [String: Any]) {
        let parsed = agent.models(fromSessionReply: result, for: session.account)
        guard !parsed.isEmpty else { return }
        DispatchQueue.main.async { self.session.adoptAvailableModels(parsed) }
    }

    /// Session established, whichever way we got here.
    private func ready(_ id: String) {
        sessionID = id
        setModel(in: id)
        // One, and the rest wait for its turn to end. `send` already keeps this
        // to a single entry; sending a whole queue at once is what this used to
        // do, and it is the same overlap `turnInFlight` exists to prevent —
        // two prompts in flight, one answer, emitted twice.
        guard !queued.isEmpty else { return }
        let next = queued.removeFirst()
        held.insert(contentsOf: queued, at: 0)
        queued = []
        turnInFlight = true
        prompt(next, in: id)
    }

    // MARK: session/update

    private func handle(update: [String: Any]) {
        switch update["sessionUpdate"] as? String {
        case "agent_message_chunk":
            guard let text = Self.chunkText(update) else { return }
            // A probe's reply is ours, not yours.
            if probe != nil { probeText += text; return }
            deltas.append(text, thinking: false)

        case "agent_thought_chunk":
            if let text = Self.chunkText(update) { deltas.append(text, thinking: true) }

        case "tool_call":
            handleToolCall(update)

        case "tool_call_update":
            guard let callID = update["toolCallId"] as? String else { return }
            refine(callID, from: update)
            let status = update["status"] as? String
            // `pending` and `in_progress` are progress, not outcomes — leaving
            // the card alone keeps it in its proposed state until it resolves.
            guard status == "completed" || status == "failed" else { return }
            // `rawOutput` is a dictionary on Copilot and a bare string on
            // Kimi. Reading only the first shape left every Kimi failure with
            // an empty message, and hid any dev-server URL it printed.
            let message = (update["rawOutput"] as? String)
                ?? ((update["rawOutput"] as? [String: Any])?["content"] as? String)
                ?? Self.text(in: update) ?? ""
            // ACP is unambiguous here: a `failed` status is execution, not
            // permission — a refusal comes back through `request_permission`
            // instead, and is resolved there.
            let state: ToolState = status == "failed" ? .failed(message) : .applied
            // Matched here, on the reader queue, rather than inside the block
            // below: a tool result can be megabytes, and running the pattern
            // over it on the main queue put that scan inside a streaming frame.
            let server = DevServer.find(in: message)
            DispatchQueue.main.async {
                self.session.resolve(toolUseID: callID, state: state, text: message)
                if let server { self.session.noticeDevServer(server) }
            }

        case "plan":
            let entries = update["entries"] as? [[String: Any]] ?? []
            let todos = entries.enumerated().map { index, entry in
                Todo(id: String(index + 1),
                     subject: entry["content"] as? String ?? "",
                     activeForm: nil,
                     status: Todo.Status(rawValue: entry["status"] as? String ?? "")
                        ?? .pending)
            }
            // Through `onMain` because the first plan inserts a card, which
            // splits a sentence exactly the way a tool card does.
            onMain { self.session.setPlan(todos) }

        case "available_commands_update":
            let entries = update["availableCommands"] as? [[String: Any]] ?? []
            let commands = entries.compactMap { entry -> AgentCommand? in
                guard let name = entry["name"] as? String else { return nil }
                return AgentCommand(name: name,
                                    detail: entry["description"] as? String ?? "")
            }
            DispatchQueue.main.async { self.session.commands = commands }

        default:
            break
        }
    }

    /// Both chunk kinds wrap their text in a content block.
    private static func chunkText(_ update: [String: Any]) -> String? {
        guard let content = update["content"] as? [String: Any] else { return nil }
        return content["text"] as? String
    }

    private func handleToolCall(_ update: [String: Any]) {
        let callID = update["toolCallId"] as? String ?? ""
        let title = (update["title"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let kind = update["kind"] as? String ?? "other"
        let input = update["rawInput"] as? [String: Any] ?? [:]

        // The structured diff block is the whole reason edits get the review
        // surface rather than a one-line row. `rawInput.diff` carries the same
        // change as git-format text; this is the same thing already parsed.
        if let content = update["content"] as? [[String: Any]],
           let block = content.first(where: { $0["type"] as? String == "diff" }) {
            let old = block["oldText"] as? String ?? ""
            let new = block["newText"] as? String ?? ""
            let path = block["path"] as? String ?? title
            let rows = Diff.rows(from: old, to: new)
            if !rows.isEmpty {
                emit(.diff(id: UUID(), toolUseID: callID,
                           file: Self.shorten(path), rows: rows, state: .pending))
                return
            }
        }

        if kind == "search", let query = (input["query"] ?? input["pattern"]) as? String {
            emit(.search(id: UUID(), toolUseID: callID, query: query,
                         results: [], state: .pending))
            return
        }

        // ACP's `title` is already written for a human ("Create file"), so it
        // stands in for the tool name and the raw input supplies the target.
        let target = (input["command"] ?? input["path"] ?? input["fileName"]
                      ?? input["url"] ?? input["query"]) as? String
        emit(.tool(id: UUID(), toolUseID: callID,
                   name: Self.name(kind: kind, title: title),
                   target: target.map(Self.shorten) ?? title,
                   detail: "", state: .pending))
    }

    /// Turn a half-finished tool card into a real one, once its arguments have
    /// finished streaming.
    ///
    /// Only ever *adds* information: a card that already knows its file — every
    /// Copilot edit, which arrives with a structured diff — is left alone.
    private func refine(_ callID: String, from update: [String: Any]) {
        guard let text = Self.text(in: update), !text.isEmpty else { return }

        // The text is the arguments *so far*, so most updates carry something
        // that isn't a complete JSON object yet. Checking the last character
        // costs nothing and skips the copy into `Data` plus the parse attempt
        // that was otherwise run — and thrown away — on every token.
        guard text.hasSuffix("}") else { return }

        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = (json["path"] ?? json["file_path"] ?? json["filePath"]) as? String,
              !path.isEmpty
        else { return }

        let file = Self.shorten(path)
        // A write carries the whole new file, so it gets the review surface
        // rather than a one-line row — the same treatment the other two agents'
        // edits get, from the same data in a different envelope.
        if let content = (json["content"] ?? json["new_string"]) as? String {
            // Only when the content is genuinely new. Rebuilding the diff means
            // a `DiffRow` — and a fresh `UUID` — for every line of the file, so
            // doing it for an update that says the same thing as the last one
            // is a whole-file rebuild, and a whole-transcript redraw, for no
            // change on screen.
            guard toolContent[callID] != content else { return }
            toolContent[callID] = content
            let rows = Diff.rows(from: "", to: content)
            DispatchQueue.main.async {
                self.session.upgradeToDiff(toolUseID: callID, file: file, rows: rows)
            }
        } else {
            guard toolTarget[callID] != file else { return }
            toolTarget[callID] = file
            DispatchQueue.main.async {
                self.session.retarget(toolUseID: callID, to: file)
            }
        }
    }

    /// The text payload of a tool call's `content`, whatever it's wrapped in.
    static func text(in update: [String: Any]) -> String? {
        guard let content = update["content"] as? [[String: Any]] else { return nil }
        for entry in content {
            if let inner = entry["content"] as? [String: Any],
               let text = inner["text"] as? String, !text.isEmpty {
                return text
            }
            if let text = entry["text"] as? String, !text.isEmpty { return text }
        }
        return nil
    }

    private static func name(kind: String, title: String) -> String {
        switch kind {
        case "edit":    return "Edit"
        case "read":    return "Read"
        case "execute": return "Run"
        case "search":  return "Search"
        case "fetch":   return "Fetch"
        case "think":   return "Think"
        default:        return title.isEmpty ? "Tool" : title
        }
    }

    private static func shorten(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + String(path.dropFirst(home.count)) : path
    }

    // MARK: Permission

    /// ACP blocks the agent on this reply, so it must always be answered —
    /// dropping it hangs the turn with no visible cause.
    ///
    /// With permissions skipped this picks `allow_always`, which stops the agent
    /// asking again for the same class of action for the rest of the session.
    /// With them on it declines, matching what Claude does under the same
    /// setting; a real approval sheet replaces this branch, not the other one.
    private func handlePermission(id: Any, params: [String: Any],
                                  options: [[String: Any]]) {
        func option(_ kinds: [String]) -> String? {
            for kind in kinds {
                if let match = options.first(where: { $0["kind"] as? String == kind }) {
                    return match["optionId"] as? String
                }
            }
            return nil
        }

        // Isolation is decided before the permissions setting, because it's the
        // stricter claim: "skip permissions" says you don't want to be asked
        // about this session's work, not that its work may be anywhere.
        //
        // This is the enforcement point ACP gives us. Kimi and Copilot have no
        // settings file to hand deny rules to — the agent asks, and this is
        // where the app answers, so it's also the only place the app can say no
        // on a path it doesn't like.
        if session.isolated, let escape = escaping(params) {
            respond(to: id, result: ["outcome": ["outcome": "selected",
                                                 "optionId": option(["reject_once",
                                                                     "reject_always"]) ?? ""]])
            DispatchQueue.main.async {
                self.session.append(.notice(id: UUID(), text:
                    "Blocked a read of \(Self.shorten(escape)) — this session is "
                    + "isolated to \(self.session.subtitle)."))
                if let call = params["toolCall"] as? [String: Any],
                   let callID = call["toolCallId"] as? String {
                    self.session.resolve(toolUseID: callID,
                                         state: .declined("Outside this session's directory."))
                }
            }
            return
        }

        let allow = ClaudeAdapter.skipPermissions
        guard let choice = allow
                ? option(["allow_always", "allow_once"])
                : option(["reject_once", "reject_always"])
        else {
            // No option we recognise. Cancelling is the only safe reply — it
            // ends the turn cleanly instead of leaving the agent waiting.
            respond(to: id, result: ["outcome": ["outcome": "cancelled"]])
            return
        }

        respond(to: id, result: ["outcome": ["outcome": "selected", "optionId": choice]])

        if !allow, let call = params["toolCall"] as? [String: Any],
           let callID = call["toolCallId"] as? String {
            DispatchQueue.main.async {
                self.session.resolve(toolUseID: callID, state: .declined(
                    "Declined — permissions are enabled in Settings."))
            }
        }
    }

    /// The first path in this request that falls outside the session's root,
    /// or nil if none does.
    ///
    /// Reported rather than merely counted, because "blocked something" is a
    /// message you learn to ignore and "blocked a read of ~/Clients/other" is
    /// one you act on.
    private func escaping(_ params: [String: Any]) -> String? {
        Isolation.paths(in: params["toolCall"] ?? params)
            .first { !Isolation.permits($0, root: session.directory) }
    }

    /// Hop to the main queue, having first landed every delta that came before
    /// this event on the wire.
    ///
    /// Text is paced by `DeltaCoalescer` and released a frame at a time;
    /// everything else went straight to the main queue. So a tool call arriving
    /// mid-sentence *overtook* the tail of that sentence: the card landed,
    /// `beginAssistant` saw a non-assistant item last, and the remaining
    /// characters opened a second block — one sentence rendered as two, split
    /// at whatever character the pacer happened to have reached.
    ///
    /// Flushing first restores wire order at the only points where it can be
    /// observed. Between tool calls the pacing runs exactly as before.
    private func onMain(_ work: @escaping () -> Void) {
        DispatchQueue.main.async {
            self.deltas.flush()
            work()
        }
    }

    private func emit(_ item: TranscriptItem) {
        onMain { self.session.append(item) }
    }
}
