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
/// Deliberately *not* `SessionColumns`. A run opens in a pane of its own rather
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
                // The way back is in the run's own header bar now, beside
                // everything else that acts on the pane. It used to be a button
                // floated over the top-left corner of the transcript, because
                // there was no bar to put it in and a pane you can only leave
                // through a sidebar is a dead end when the sidebar is collapsed.
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                head
                Spacer().frame(height: Theme.s7)
                promptField
                Spacer().frame(height: Theme.s7)
                settings
                Spacer().frame(height: Theme.s7)
                history
            }
            .padding(.horizontal, Theme.s8)
            .padding(.top, Chrome.trafficLightClearance)
            .padding(.bottom, Theme.s8)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: editing) { _, _ in scheduleFlush() }
        .onDisappear { flushing?.perform(); flushing = nil }
    }

    /// Coalesced. A prompt is prose, and prose arrives one character at a time.
    private func scheduleFlush() {
        flushing?.cancel()
        let work = DispatchWorkItem { store.update(editing) }
        flushing = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    // MARK: Head

    private var head: some View {
        HStack(alignment: .top, spacing: Theme.s5) {
            VStack(alignment: .leading, spacing: Theme.s3) {
                TextField("Name", text: $editing.name)
                    .textFieldStyle(.plain)
                    .font(Theme.display(22))

                HStack(spacing: Theme.s3) {
                    AccountDot(editing.account)
                    Text(editing.account.title)
                    Text("·").foregroundStyle(.quaternary)
                    Text(editing.subtitle)
                    Text("·").foregroundStyle(.quaternary)
                    Text(editing.schedule.title)
                    if isRunning {
                        Text("·").foregroundStyle(.quaternary)
                        Text("running now").foregroundStyle(editing.account.accent)
                    } else if let last = editing.lastRunAt {
                        Text("·").foregroundStyle(.quaternary)
                        Text("last ran \(Self.relative(last))")
                    }
                }
                .font(Theme.row)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: Theme.s5)

            HStack(spacing: Theme.s5) {
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
                Toggle("", isOn: $editing.isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help(editing.isEnabled ? "Enabled" : "Paused")
            }
            .padding(.top, Theme.s2)
        }
    }

    // MARK: Prompt

    private var promptField: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            label("Prompt")
            TextEditor(text: $editing.prompt)
                .font(Theme.body)
                .scrollContentBackground(.hidden)
                .padding(Theme.s4)
                .frame(minHeight: 96)
                .background(Theme.surface,
                            in: RoundedRectangle(cornerRadius: Theme.cornerField))
                .overlay(RoundedRectangle(cornerRadius: Theme.cornerField)
                    .strokeBorder(Theme.rule, lineWidth: 1))
        }
    }

    // MARK: Settings

    private var settings: some View {
        VStack(alignment: .leading, spacing: Theme.s6) {
            field("Runs as") { accountChips }
            field("Folder") { folderRow }
            field("Schedule") { scheduleRow }
            field("Autonomy") { autonomyRows }
            field("Isolation") { isolationRow }
            field("Model") { modelRow }
        }
    }

    /// All four, in full, rather than behind a popover.
    ///
    /// Which credentials an unattended agent runs under is the highest-stakes
    /// setting on this pane, and it should be readable without a click.
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
                    HStack(spacing: Theme.s3) {
                        AccountDot(account, dimmed: on ? 1 : 0.45)
                        Text(account.title)
                            .font(.system(size: Theme.t3, weight: on ? .medium : .regular))
                    }
                    .foregroundStyle(on ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .padding(.horizontal, Theme.s5)
                    .padding(.vertical, Theme.s3)
                    .background(on ? Theme.surface : .clear,
                                in: RoundedRectangle(cornerRadius: Theme.cornerChip))
                    .overlay(RoundedRectangle(cornerRadius: Theme.cornerChip)
                        .strokeBorder(on ? account.accent.opacity(0.75) : Theme.rule,
                                      lineWidth: on ? 1.5 : 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(account.agentName)
            }
        }
    }

    private var folderRow: some View {
        HStack(spacing: Theme.s4) {
            Text(editing.subtitle)
                .font(Theme.monoSmall)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Theme.s4)
                .padding(.vertical, Theme.s2)
                .background(Theme.codeGround,
                            in: RoundedRectangle(cornerRadius: Theme.cornerChip))
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

    private var scheduleRow: some View {
        VStack(alignment: .leading, spacing: Theme.s4) {
            HStack(spacing: Theme.s6) {
                choice("Manual", on: editing.schedule.isManual) { editing.schedule = .manual }

                HStack(spacing: Theme.s3) {
                    choice("Every", on: isEvery) {
                        editing.schedule = .every(minutes: everyMinutes)
                    }
                    Picker("", selection: Binding(
                        get: { everyMinutes },
                        set: { editing.schedule = .every(minutes: $0) })) {
                        ForEach([5, 15, 30, 60, 120, 240, 480], id: \.self) { minutes in
                            Text(minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h").tag(minutes)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 84)
                    .disabled(!isEvery)
                }

                HStack(spacing: Theme.s3) {
                    choice("Daily at", on: isDaily) {
                        editing.schedule = .daily(hour: 9, minute: 0)
                    }
                    DatePicker("", selection: Binding(
                        get: { dailyDate },
                        set: { date in
                            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                            editing.schedule = .daily(hour: parts.hour ?? 9,
                                                      minute: parts.minute ?? 0)
                        }), displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .disabled(!isDaily)
                }
            }

            HStack(spacing: Theme.s3) {
                choice("When a file changes", on: isWatching) {
                    editing.schedule = .watching(path: watchPath.isEmpty
                                                 ? editing.path : watchPath)
                }
                if case .watching(let path) = editing.schedule {
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
    }

    private var autonomyRows: some View {
        VStack(alignment: .leading, spacing: Theme.s4) {
            ForEach(Autonomy.allCases) { option in
                HStack(spacing: Theme.s3) {
                    choice(option.title, on: editing.autonomy == option) {
                        editing.autonomy = option
                    }
                    Text(option.blurb)
                        .font(Theme.row)
                        .foregroundStyle(.tertiary)
                }
            }
            if editing.autonomy == .act {
                // Said once, where the decision is made, and not dressed up as
                // a warning triangle. `Propose` is a paragraph in a prompt;
                // this is the real thing.
                Text("Runs unattended with full tool access in \(editing.subtitle). "
                     + "Isolation is the only limit that holds.")
                    .font(Theme.note)
                    .foregroundStyle(.secondary)
                    .padding(.leading, Theme.s6)
            }
        }
    }

    private var isolationRow: some View {
        Toggle(isOn: $editing.isolated) {
            Text("Confine to \(editing.subtitle)")
                .font(Theme.row)
        }
        .toggleStyle(.checkbox)
        .help("Nothing above or beside this folder is readable.")
    }

    private var modelRow: some View {
        HStack(spacing: Theme.s5) {
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

    // MARK: History

    private var history: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.s3) {
                label("Runs")
                Spacer(minLength: 0)
                if !runs.isEmpty {
                    Text("keeping the last \(AgentStore.runsKept)")
                        .font(Theme.note)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, Theme.s3)

            if runs.isEmpty {
                Text("Nothing yet.")
                    .font(Theme.row)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, Theme.s4)
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

    private func label(_ text: String) -> some View {
        Text(text).font(Theme.label).foregroundStyle(.tertiary)
    }

    private func field<Content: View>(_ name: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.s6) {
            label(name)
                .frame(width: 74, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func chip(_ text: String) -> some View {
        HStack(spacing: Theme.s2) {
            Text(text).font(Theme.row)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Theme.s4)
        .padding(.vertical, Theme.s2)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerChip))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerChip)
            .strokeBorder(Theme.rule, lineWidth: 1))
        .contentShape(Rectangle())
    }

    private func choice(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.s3) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(on ? AnyShapeStyle(Color.accentColor)
                                        : AnyShapeStyle(.tertiary))
                Text(title).font(Theme.row).foregroundStyle(.primary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                    .foregroundStyle(run.items.isEmpty ? AnyShapeStyle(.tertiary)
                                                       : AnyShapeStyle(.primary))
                    .lineLimit(1)
                Spacer(minLength: Theme.s4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Theme.s3)
            .padding(.vertical, Theme.s4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(hovering ? Theme.well : .clear)
        .overlay(alignment: .top) { Divider().overlay(Theme.rule) }
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
                         accent: nil, subtitle: "New agent",
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
