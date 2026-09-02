import SwiftUI
import AppKit

// MARK: - The sidebar's other half

/// The Agents list, sectioned by *when* rather than by account.
///
/// The Code list groups by credentials because that's the question you ask of a
/// conversation — which account is this under. The question you ask of an agent
/// is what runs without me, so scheduled ones come first and the ones you have
/// to press are at the bottom.
struct AgentList: View {
    @ObservedObject var store: AgentStore

    var body: some View {
        List(selection: Binding(get: { store.selection },
                                set: { if let id = $0 { store.selection = id; store.openRun = nil } })) {
            if store.setup != nil {
                Section {
                    SetupRow(store: store)
                } header: {
                    header("Setting up")
                }
            }

            ForEach(store.sections, id: \.0) { section, agents in
                Section {
                    ForEach(agents) { agent in
                        AgentRow(agent: agent, store: store)
                            .tag(agent.id)
                    }
                } header: {
                    header(section, count: agents.count)
                }
            }

            if store.agents.isEmpty && store.setup == nil {
                Text("No agents yet.\nThe + above opens a conversation that makes one.")
                    .font(Theme.row)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, Theme.s3)
                    .padding(.top, Theme.s4)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 26)
    }

    private func header(_ text: String, count: Int? = nil) -> some View {
        HStack(spacing: Theme.s3) {
            Text(text)
                .font(Theme.label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let count, count > 1 {
                Text("\(count)")
                    .font(Theme.note)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.trailing, Theme.s1)
    }
}

/// The agent being made. Hollow dot, like a throwaway session — it isn't real
/// until you press Create.
private struct SetupRow: View {
    @ObservedObject var store: AgentStore

    var body: some View {
        HStack(spacing: Theme.s3) {
            AccountDot(colour: .secondary, hollow: true, gutter: 12)
            Text(store.draft?.name ?? "New agent…")
                .font(Theme.sidebarRow)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button { store.endSetup() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Cancel")
        }
        .contentShape(Rectangle())
        .onTapGesture { store.selection = nil }
    }
}

private struct AgentRow: View {
    let agent: AgentDefinition
    @ObservedObject var store: AgentStore
    @State private var hovering = false

    private var isRunning: Bool { store.running[agent.id] != nil }

    var body: some View {
        HStack(spacing: Theme.s3) {
            // The same accent dot a session carries. A separate glyph was tried
            // and read as a second taxonomy on top of the account colours —
            // and which credentials this runs under is precisely the thing you
            // want to see before letting it run unattended. Hollow for manual,
            // as it already means "doesn't happen on its own".
            AccountDot(agent.account,
                       hollow: agent.schedule.isManual,
                       dimmed: agent.isEnabled ? 1 : 0.4,
                       gutter: 12)

            Text(agent.name)
                .font(Theme.sidebarRow)
                .foregroundStyle(agent.isEnabled ? AnyShapeStyle(.primary)
                                                 : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: Theme.s2)

            // One slot, three occupants, cross-faded — the same shape and the
            // same reason as `SessionRow`: a schedule label that vanished on
            // hover would shift the name under the pointer.
            ZStack(alignment: .trailing) {
                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.55)
                        .opacity(hovering ? 0 : 1)
                } else if !agent.schedule.shortTitle.isEmpty {
                    Text(agent.schedule.shortTitle)
                        .font(Theme.note)
                        .foregroundStyle(.secondary)
                        .opacity(hovering ? 0 : 1)
                }
                moreButton
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(hovering)
            }
            .frame(width: 34, height: 16)
            .animation(Motion.reveal, value: hovering)
            .animation(Motion.reveal, value: isRunning)
        }
        .contentShape(Rectangle())
        .help("\(agent.account.title)\n\(agent.schedule.title)\n\(agent.subtitle)")
        .onHover { hovering = $0 }
        .contextMenu { menuItems }
    }

    @ViewBuilder
    private var menuItems: some View {
        if isRunning {
            Button("Stop") { store.stop(agent.id) }
        } else {
            Button("Run Now") { store.run(agent, trigger: .hand) }
        }
        Toggle("Enabled", isOn: Binding(
            get: { agent.isEnabled },
            set: { var copy = agent; copy.isEnabled = $0; store.update(copy) }))
        Divider()
        Button("Duplicate") { store.duplicate(agent.id) }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([agent.directory])
        }
        Divider()
        Button("Delete Agent", role: .destructive) { store.remove(agent.id) }
    }

    private var moreButton: some View {
        PopoverMenu(width: 210, choices: [
            isRunning
                ? PopoverChoice(title: "Stop") { store.stop(agent.id) }
                : PopoverChoice(title: "Run Now") { store.run(agent, trigger: .hand) },
            PopoverChoice(title: agent.isEnabled ? "Pause" : "Enable") {
                var copy = agent
                copy.isEnabled.toggle()
                store.update(copy)
            },
            PopoverChoice(title: "Duplicate") { store.duplicate(agent.id) },
            PopoverChoice(title: "Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([agent.directory])
            },
            PopoverChoice(title: "Delete Agent", destructive: true) { store.remove(agent.id) },
        ]) {
            Image(systemName: "ellipsis")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .help("Agent options")
    }
}

// MARK: - The pane

/// What the window shows in Agents mode.
///
/// Deliberately *not* the session pane. A run opens in a pane of its own rather
/// than taking a column, so flipping between Code and Agents leaves the
/// arrangement you made on the other side exactly as it was.
struct AgentsPane: View {
    @ObservedObject var store: AgentStore
    @ObservedObject var workspace: Workspace

    var body: some View {
        Group {
            if let setup = store.setup, store.selection == nil {
                AgentSetup(store: store, session: setup, workspace: workspace)
            } else if let run = openRun {
                // The way back is at the head of the run's own tab strip,
                // beside everything else that acts on the pane. It used to be a
                // button floated over the top-left corner of the transcript,
                // because there was no bar to put it in and a pane you can only
                // leave through a sidebar is a dead end when the sidebar is
                // collapsed.
                SessionView(session: run, workspace: workspace,
                            onBack: { store.openRun = nil })
                    .id(run.id)
            } else if let agent = store.agent(store.selection) {
                AgentDetail(agent: agent, store: store, workspace: workspace)
                    .id(agent.id)
            } else {
                empty
            }
        }
        // An opaque ground, like Settings and unlike this pane until now.
        //
        // `PaneBackground` spans the whole window, and every other pane paints
        // over it: a transcript is on `Theme.canvas`, so is Settings, and the
        // photo is meant to show in the title bar and behind the start pane.
        // This one painted nothing, so an agent's prompt, its folder, its
        // schedule and the switch that decides whether it runs unattended were
        // all set directly on somebody's wallpaper.
        //
        // Not applied to the run, which is a transcript and brings its own.
        .background(showsRun ? AnyShapeStyle(.clear) : AnyShapeStyle(Theme.canvas))
        // The measure, centred, the same way Settings does it — see
        // `SettingsColumn`. Harmless on the two branches that aren't a page.
        .settingsColumn()
    }

    /// Whether a run's transcript is in the pane rather than an agent.
    private var showsRun: Bool {
        store.setup != nil && store.selection == nil || openRun != nil
    }

    private var openRun: Session? {
        guard let id = store.openRun else { return nil }
        return workspace.sessions.first { $0.id == id }
    }

    private var empty: some View {
        VStack(spacing: Theme.s2) {
            Text("No agent")
                .font(Theme.display(Theme.t6))
            Text("Press + to describe one.")
                .font(Theme.body)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - One agent

struct AgentDetail: View {
    let agent: AgentDefinition
    @ObservedObject var store: AgentStore
    @ObservedObject var workspace: Workspace

    /// Edited locally and written back on change.
    ///
    /// Not bound straight through the store: every keystroke in the prompt
    /// would otherwise re-encode and rewrite `Agents.json`, which is the same
    /// mistake `@AppStorage` on a drag makes elsewhere in this app.
    @State private var editing: AgentDefinition
    @State private var flushing: DispatchWorkItem?

    init(agent: AgentDefinition, store: AgentStore, workspace: Workspace) {
        self.agent = agent
        self.store = store
        self.workspace = workspace
        _editing = State(initialValue: agent)
    }

    private var isRunning: Bool { store.running[agent.id] != nil }
    private var runs: [Session] { workspace.runs(of: agent.id) }

    /// A folder or a watched file that isn't there any more.
    ///
    /// Held rather than asked for in `body`: this is a `stat`, and the body
    /// redraws on every keystroke in the prompt. Refreshed when either path
    /// changes and when the pane opens, which is when the answer can move.
    @State private var absent: String?

    var body: some View {
        // The same page as Settings, and the same measure. This pane was a
        // hand-rolled label column at `maxWidth: 820` — a third measure in an
        // app that has one — with its fields laid out by a private `field()`
        // helper that did what `SettingsRow` does. Nothing here needed to be
        // its own kind of screen.
        SettingsPage {
            header
            if store.paused { pausedNotice }
            promptGroup
            whereAndWhen
            allowed
            history
        }
        .onChange(of: editing) { _, _ in scheduleFlush() }
        .onDisappear { flushing?.perform(); flushing = nil }
        .onAppear { checkPaths() }
        .onChange(of: editing.path) { _, _ in checkPaths() }
        .onChange(of: editing.schedule) { _, _ in checkPaths() }
    }

    /// The quiet failure this app had no way to report.
    ///
    /// A folder that has been moved or renamed doesn't stop an agent — it runs
    /// every half hour into a directory that isn't there, and the only sign is
    /// a column of failed runs nobody is watching. A *watched* file that has
    /// gone is worse than that: `FileWatch` has nothing to fire on, so the
    /// agent simply never runs again and there is nothing in the history at
    /// all to notice.
    private func checkPaths() {
        let manager = FileManager.default
        if case .watching(let path) = editing.schedule, !manager.fileExists(atPath: path) {
            absent = "\u{201C}\((path as NSString).lastPathComponent)\u{201D} isn\u{2019}t there any "
                + "more, so nothing will ever start this agent. Choose another file."
            return
        }
        if !manager.fileExists(atPath: editing.path) {
            absent = "\(editing.subtitle) isn\u{2019}t there any more. Runs will start in a "
                + "folder that doesn\u{2019}t exist and fail."
            return
        }
        absent = nil
    }

    /// Coalesced. A prompt is prose, and prose arrives one character at a time.
    private func scheduleFlush() {
        flushing?.cancel()
        let work = DispatchWorkItem { store.update(editing) }
        flushing = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    // MARK: Head

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.s5) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.s5) {
                TextField("Name", text: $editing.name)
                    .textFieldStyle(.plain)
                    .font(Theme.display(22))

                Spacer(minLength: Theme.s5)

                if isRunning {
                    Button("Stop") { store.stop(agent.id) }
                } else {
                    Button {
                        store.run(editing, trigger: .hand)
                    } label: {
                        Label("Run now", systemImage: "play.fill")
                            .labelStyle(.titleAndIcon)
                    }
                    .disabled(editing.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                // Duplicate, Reveal and Delete were only ever on the sidebar
                // row — so acting on the agent you are looking at meant finding
                // it again in a list, and with the sidebar collapsed there was
                // no route to them at all.
                menu
            }

            // What this agent is, in one line, and — the part that was missing
            // — when it next runs. A pane about a thing that runs on a clock
            // said "Every 30 minutes · last ran 4w ago" and left you to work
            // out whether that meant anything.
            HStack(spacing: Theme.s3) {
                AccountDot(editing.account)
                Text(editing.account.title)
                separator
                Text(editing.subtitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                separator
                // Re-read on a slow tick rather than on every redraw: it is a
                // countdown, so it has to move on its own, and nothing else on
                // this pane changes when it does.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(status(at: context.date))
                        .foregroundStyle(statusTint)
                }
                Spacer(minLength: Theme.s5)
                Toggle("Enabled", isOn: $editing.isEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Off, this agent's schedule is ignored. Run now still works.")
            }
            .font(Theme.row)
            .foregroundStyle(.secondary)
        }
    }

    private var separator: some View {
        Text("·").foregroundStyle(.quaternary)
    }

    private var menu: some View {
        PopoverMenu(width: 220, choices: [
            PopoverChoice(title: "Duplicate",
                          blurb: "The same prompt, switched off") {
                store.duplicate(agent.id)
            },
            PopoverChoice(title: "Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([editing.directory])
            },
            PopoverChoice(title: "Delete Agent", destructive: true) {
                store.remove(agent.id)
            },
        ]) {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .help("Agent options")
    }

    /// When this runs next, or why it doesn't.
    ///
    /// Every branch answers the same question — will anything make this happen
    /// — so the switch that is off and the roster that is paused are said here
    /// rather than left to be inferred from a control somewhere else.
    private func status(at now: Date) -> String {
        if isRunning { return "running now" }
        if store.paused { return "all agents paused" }
        if !editing.isEnabled { return "paused" }
        switch editing.schedule {
        case .manual:
            return "only when you ask"
        case .watching(let path):
            return "when \((path as NSString).lastPathComponent) changes"
        case .every, .daily:
            guard let next = store.nextRun(of: editing, from: now) else { return "" }
            if next <= now { return "due now" }
            return "next run \(Self.relative(next))"
        }
    }

    private var statusTint: Color {
        if isRunning { return editing.account.accent }
        if store.paused || !editing.isEnabled { return Theme.stateHeld }
        return .secondary
    }

    /// The global switch, said where it bites.
    ///
    /// `AgentStore.paused` has always existed, has always been honoured by both
    /// the ticker and the file watches, and has always been written to
    /// preferences — and nothing in the app could set it or reported that it
    /// was set. So a roster could be silently switched off with every agent
    /// still showing its own switch as on.
    private var pausedNotice: some View {
        SettingsGroup {
            SettingsRow("Every agent is paused",
                        note: "No schedule fires and no watched file starts "
                            + "anything, whatever each agent's own switch says. "
                            + "Run now still works.") {
                Button("Resume") { store.paused = false }
            }
        }
    }

    // MARK: Prompt

    private var promptGroup: some View {
        SettingsGroup("Prompt", footer:
            "What this agent is asked, every time it runs. It arrives as the "
            + "first message of a fresh conversation — there is no history to "
            + "lean on, so it has to say where to look as well as what to do.") {
            SettingsRow {
                TextEditor(text: $editing.prompt)
                    .font(Theme.body)
                    .scrollContentBackground(.hidden)
                    .padding(Theme.s3)
                    // Taller than it was. This is the whole substance of an
                    // agent and it was in a 96pt box under a pane with six
                    // hundred points of unused height below it.
                    .frame(minHeight: 150)
                    .background(Theme.well,
                                in: RoundedRectangle(cornerRadius: Theme.cornerField))
                    .overlay(RoundedRectangle(cornerRadius: Theme.cornerField)
                        .strokeBorder(Theme.rule, lineWidth: 1))
            }
        }
    }

    // MARK: Where and when

    private var whereAndWhen: some View {
        SettingsGroup("Where and when", caution: absent) {
            SettingsRow("Runs as") { accountChips }
            SettingsRow("Folder") { folderRow }
            SettingsRow("Schedule") { scheduleRow }
            SettingsRow("Model") { modelRow }
        }
    }

    /// All four, in full, rather than behind a popover.
    ///
    /// Which credentials an unattended agent runs under is the highest-stakes
    /// setting on this pane, and it should be readable without a click. The
    /// schedule and the model below it are popovers precisely because they are
    /// not: getting either wrong wastes a run.
    private var accountChips: some View {
        HStack(spacing: Theme.s3) {
            ForEach(Account.enabled) { account in
                let on = editing.account == account
                Button {
                    guard !on else { return }
                    editing.account = account
                    // The model list is per account, and effort is a Claude
                    // launch flag. Carrying either across would send an id one
                    // CLI has never heard of.
                    editing.modelID = nil
                    if !account.hasEffort { editing.effort = .high }
                } label: {
                    HStack(spacing: Theme.s2) {
                        AccountDot(account, dimmed: on ? 1 : 0.45)
                        Text(account.shortTitle)
                            .font(.system(size: Theme.t3, weight: on ? .medium : .regular))
                    }
                    .foregroundStyle(on ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .padding(.horizontal, Theme.s4)
                    .padding(.vertical, Theme.s3)
                    .background(on ? Theme.well : .clear,
                                in: RoundedRectangle(cornerRadius: Theme.cornerChip))
                    .overlay(RoundedRectangle(cornerRadius: Theme.cornerChip)
                        .strokeBorder(on ? account.accent.opacity(0.75) : Theme.rule,
                                      lineWidth: on ? 1.5 : 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(account.title) · \(account.agentName)")
            }
        }
    }

    private var folderRow: some View {
        HStack(spacing: Theme.s4) {
            Text(editing.subtitle)
                .font(Theme.monoSmall)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .padding(.horizontal, Theme.s4)
                .padding(.vertical, Theme.s2)
                .background(Theme.codeGround,
                            in: RoundedRectangle(cornerRadius: Theme.cornerChip))
                .help(editing.path)
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.prompt = "Use Folder"
                panel.message = "Where should this agent work?"
                if panel.runModal() == .OK, let url = panel.url { editing.path = url.path }
            }
            .buttonStyle(.link)
            .font(Theme.row)
        }
    }

    /// The kind of schedule, then whatever that kind needs.
    ///
    /// Four radio buttons before this, laid out across two lines with their own
    /// inline pickers, so the row was a different height and a different shape
    /// in each of its four states and "When a file changes" sat on a second
    /// line under "Manual". A menu names the four in one control the width of
    /// the longest, and the parameter beside it belongs to whichever is chosen.
    private var scheduleRow: some View {
        HStack(spacing: Theme.s4) {
            PopoverMenu(header: "Schedule", width: 260, choices: [
                PopoverChoice(title: "Only when you ask",
                              blurb: "Nothing runs it but Run now",
                              selected: editing.schedule.isManual) {
                    editing.schedule = .manual
                },
                PopoverChoice(title: "Every…",
                              blurb: "On a clock, from the last run",
                              selected: isEvery) {
                    editing.schedule = .every(minutes: everyMinutes)
                },
                PopoverChoice(title: "Daily at…",
                              blurb: "Once a day. A missed day runs once, not twice",
                              selected: isDaily) {
                    editing.schedule = .daily(hour: 9, minute: 0)
                },
                PopoverChoice(title: "When a file changes",
                              blurb: "Runs when something writes to it",
                              selected: isWatching) {
                    editing.schedule = .watching(path: watchPath.isEmpty
                                                 ? editing.path : watchPath)
                },
            ]) {
                chip(scheduleKind)
            }

            switch editing.schedule {
            case .manual:
                EmptyView()

            case .every:
                Picker("", selection: Binding(
                    get: { everyMinutes },
                    set: { editing.schedule = .every(minutes: $0) })) {
                    ForEach([5, 15, 30, 60, 120, 240, 480], id: \.self) { minutes in
                        Text(minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h").tag(minutes)
                    }
                }
                .labelsHidden()
                .frame(width: 88)

            case .daily:
                DatePicker("", selection: Binding(
                    get: { dailyDate },
                    set: { date in
                        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                        editing.schedule = .daily(hour: parts.hour ?? 9,
                                                  minute: parts.minute ?? 0)
                    }), displayedComponents: .hourAndMinute)
                    .labelsHidden()

            case .watching(let path):
                Text((path as NSString).lastPathComponent)
                    .font(Theme.monoSmall)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Theme.s4)
                    .padding(.vertical, Theme.s2)
                    .background(Theme.codeGround,
                                in: RoundedRectangle(cornerRadius: Theme.cornerChip))
                    .help(path)
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    panel.prompt = "Watch File"
                    panel.directoryURL = editing.directory
                    if panel.runModal() == .OK, let url = panel.url {
                        editing.schedule = .watching(path: url.path)
                    }
                }
                .buttonStyle(.link)
                .font(Theme.row)
            }
        }
    }

    private var scheduleKind: String {
        switch editing.schedule {
        case .manual:   return "Only when you ask"
        case .every:    return "Every"
        case .daily:    return "Daily at"
        case .watching: return "When a file changes"
        }
    }

    private var modelRow: some View {
        HStack(spacing: Theme.s4) {
            let models = ModelCatalog.models(for: editing.account)
            PopoverMenu(header: "Model", width: 260,
                        choices: models.map { model in
                            PopoverChoice(title: model.title, blurb: model.blurb,
                                          selected: model.id == currentModel(models).id) {
                                editing.modelID = model.id
                            }
                        }) {
                chip(currentModel(models).title)
            }

            if editing.account.hasEffort {
                PopoverMenu(header: "Reasoning effort", width: 240,
                            choices: EffortChoice.allCases.map { effort in
                                PopoverChoice(title: effort.title,
                                              selected: effort == editing.effort) {
                                    editing.effort = effort
                                }
                            }) {
                    chip(editing.effort.title)
                }
            }
        }
    }

    private func currentModel(_ models: [AgentModel]) -> AgentModel {
        models.first { $0.id == editing.modelID } ?? models.first ?? ModelCatalog.fallback
    }

    // MARK: What it may do

    private var allowed: some View {
        SettingsGroup("What it may do",
                      footer: editing.autonomy == .act
                          ? "Runs with full tool access in \(editing.subtitle). "
                            + "Confinement is the only limit that holds."
                          : nil,
                      // What the schedule takes back, said where the setting is
                      // chosen. A definition that quietly runs as something
                      // other than what it says is worse than one that refuses:
                      // you read "Act", watch nothing get written, and go
                      // looking for a bug in the agent.
                      caution: AgentStore.downgrade(editing)) {
            // A segmented control rather than two radio buttons with their
            // blurbs trailing off to the right of them. Two options, one of
            // which is chosen — and the blurb of whichever is chosen is the
            // row's own note, which is where an explanation of a setting goes
            // everywhere else in this app.
            SettingsRow("Autonomy", note: editing.autonomy.blurb) {
                Picker("", selection: $editing.autonomy) {
                    ForEach(Autonomy.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
            }

            SettingsToggle("Confine to this folder",
                           note: "Nothing above or beside \(editing.subtitle) is "
                               + "readable. This is a launch argument and it holds — "
                               + "Propose above is a paragraph in a prompt and doesn\u{2019}t.",
                           isOn: $editing.isolated)
        }
    }

    // MARK: History

    private var history: some View {
        SettingsGroup("Runs", footer: runs.isEmpty ? nil
                      : "The last \(AgentStore.runsKept) are kept; older ones are "
                        + "deleted with their transcripts.") {
            if runs.isEmpty {
                SettingsRow {
                    Text("Nothing yet.")
                        .font(Theme.row)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ForEach(runs) { run in
                    RunRow(run: run, live: store.running[agent.id] == run.id) {
                        store.openRun = run.id
                    }
                }
            }
        }
    }

    // MARK: Bits

    /// A control that opens a menu: the schedule, the model, the effort.
    ///
    /// `Theme.well` rather than `Theme.surface`, which is what it was: a card
    /// is `surface` now, so a chip drawn in the same colour on top of one was
    /// invisible except for its hairline.
    private func chip(_ text: String) -> some View {
        HStack(spacing: Theme.s2) {
            Text(text).font(Theme.row)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Theme.s4)
        .padding(.vertical, Theme.s2)
        .background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.cornerChip))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerChip)
            .strokeBorder(Theme.rule, lineWidth: 1))
        .contentShape(Rectangle())
    }

    private var isEvery: Bool { if case .every = editing.schedule { return true }; return false }
    private var isDaily: Bool { if case .daily = editing.schedule { return true }; return false }
    private var isWatching: Bool {
        if case .watching = editing.schedule { return true }
        return false
    }

    private var everyMinutes: Int {
        if case .every(let minutes) = editing.schedule { return minutes }
        return 30
    }

    private var watchPath: String {
        if case .watching(let path) = editing.schedule { return path }
        return ""
    }

    private var dailyDate: Date {
        guard case .daily(let hour, let minute) = editing.schedule else { return Date() }
        var parts = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        parts.hour = hour
        parts.minute = minute
        return Calendar.current.date(from: parts) ?? Date()
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// One line of history.
private struct RunRow: View {
    @ObservedObject var run: Session
    let live: Bool
    let open: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: Theme.s5) {
                state
                    .frame(width: 12)
                Text(run.startedAt.map(Self.clock) ?? "—")
                    .font(Theme.row.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)
                Text(summary)
                    .font(Theme.row)
                    .foregroundStyle(run.items.isEmpty ? AnyShapeStyle(.secondary)
                                                       : AnyShapeStyle(.primary))
                    .lineLimit(1)
                Spacer(minLength: Theme.s4)
                // Whether it wrote anything, which for an unattended run is the
                // question. A row said what the agent *replied* and nothing
                // about what it did, so a run that edited nine files and one
                // that read a file and shrugged looked identical.
                //
                // `fileCount` copies nothing — see `ChangedFilesSection`, which
                // uses it for the same reason.
                if changed > 0 {
                    Text("\(changed) file\(changed == 1 ? "" : "s")")
                        .font(Theme.caption)
                        .monospacedDigit()
                        .foregroundStyle(Theme.stateDone)
                        .padding(.horizontal, Theme.s3)
                        .padding(.vertical, 1)
                        .background(Theme.stateDone.opacity(0.14), in: Capsule())
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Theme.s5)
            .padding(.vertical, Theme.s4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(hovering ? Theme.well : .clear)
        // Underneath, not on top: these sit in a `SettingsGroup` card now, and
        // every other row in one draws its own hairline below itself so the
        // card can pull the last one under its clip.
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.rule).frame(height: 1)
        }
        .onHover { hovering = $0 }
        // The roster hydrates in the background; a row for a run that hasn't
        // been read yet would otherwise sit blank until you clicked it.
        .onAppear { run.hydrate() }
    }

    @ViewBuilder
    private var state: some View {
        if live {
            ProgressView().controlSize(.small).scaleEffect(0.5)
        } else if run.items.contains(where: { if case .assistant = $0 { return true }; return false }) {
            AccountDot(run.account)
        } else {
            AccountDot(colour: .secondary.opacity(0.5), hollow: true)
        }
    }

    private var changed: Int { Changes.fileCount(run.items) }

    /// The last thing it said, which is what `lastReply` already computes for
    /// notifications — the same question asked in a different place.
    private var summary: String {
        if live { return "Running…" }
        guard !run.items.isEmpty else { return "No output." }
        return run.lastReply
    }

    private static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "d MMM"
        return formatter.string(from: date)
    }
}

// MARK: - Making one by talking

/// The interview: an ordinary transcript, with the draft pinned above the
/// composer where it stays readable while you correct it.
struct AgentSetup: View {
    @ObservedObject var store: AgentStore
    @ObservedObject var session: Session
    @ObservedObject var workspace: Workspace

    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            if session.items.isEmpty {
                opening
            } else {
                TranscriptView(session: session, onEdit: { draft = $0 },
                               mode: .normal, scale: 1, width: Theme.readingWidth)
            }

            if let agent = store.draft {
                card(agent)
                    .frame(maxWidth: Theme.readingWidth)
                    .padding(.horizontal, Theme.s7)
                    .padding(.bottom, Theme.s5)
                    .transition(.opacity)
            }

            ComposerView(draft: $draft, session: session,
                         prominent: session.items.isEmpty,
                         width: Theme.readingWidth,
                         onFocused: {}) { text in
                session.send(text)
                draft = ""
            }
        }
        .animation(Motion.disclose, value: store.draft)
        .onAppear { session.prepare() }
    }

    private var opening: some View {
        GeometryReader { geometry in
            VStack(spacing: Theme.s4) {
                Spacer().frame(height: max(0, geometry.size.height * 0.24))
                Text("What should it do?")
                    .font(Theme.display(26))
                Text("One sentence is enough — “check my honeycode todos every half "
                     + "hour and do them”. I'll work the rest out and show you.")
                    .font(Theme.body)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .padding(.bottom, Theme.s6)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// The draft, as it stands. Mutated in place across turns rather than
    /// re-emitted as a new block each time, so the conversation above stays
    /// prose and there's one card to read rather than four.
    private func card(_ agent: AgentDefinition) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.s4) {
                AccountDot(agent.account)
                Text(agent.name).font(Theme.display(Theme.t5))
                Spacer(minLength: 0)
                Text(session.isRunning ? "DRAFT" : "READY")
                    .font(.system(size: Theme.t1, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Theme.s5)
            .padding(.top, Theme.s5)
            .padding(.bottom, Theme.s4)

            VStack(alignment: .leading, spacing: Theme.s3) {
                line("Runs as", agent.account.title)
                line("Folder", agent.subtitle)
                line("Schedule", agent.schedule.title)
                line("Autonomy", agent.autonomy == .act
                     ? "Act — full tool access, unattended"
                     : "Propose — reads and reports back")
                if agent.isolated { line("Isolation", "Confined to \(agent.subtitle)") }
            }
            .padding(.horizontal, Theme.s5)

            Divider().overlay(Theme.rule).padding(.top, Theme.s5)

            HStack(spacing: Theme.s4) {
                Text(agent.autonomy == .act
                     ? "Runs unattended with full tool access."
                     : "Won't write anything until you say so.")
                    .font(Theme.note)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: Theme.s4)
                Button("Cancel") { store.endSetup() }
                Button("Create agent") { store.acceptDraft() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(agent.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, Theme.s5)
            .padding(.vertical, Theme.s4)
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerField))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerField)
            .strokeBorder(Theme.rule, lineWidth: 1))
    }

    private func line(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.s5) {
            Text(key)
                .font(Theme.label)
                .foregroundStyle(.tertiary)
                .frame(width: 62, alignment: .leading)
            Text(value)
                .font(Theme.row)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }
}
