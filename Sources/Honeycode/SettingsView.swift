import SwiftUI
import AppKit

/// Settings (⌘,), in the window rather than beside it.
///
/// This was a SwiftUI `Settings` scene, which is to say a second window. That
/// is the platform default and it was the wrong default here for three
/// reasons, all of which showed up as bugs rather than as taste:
///
/// - **A scene cannot reach the window.** Settings ▸ Features offers a way
///   back into the first-run flow, and the flow is a sheet on `RootView` — so
///   the button had to post a notification and then activate the app, or the
///   flow opened *behind* the window that asked for it. Nothing about that
///   was a preferences problem; it was a two-windows problem.
/// - **AppKit owned the chrome.** `AppearanceSettings` documents an entire
///   design decision — a segmented picker rather than a nested `TabView` —
///   forced by the Settings scene hoisting inner tabs into its own toolbar.
/// - **It was a pane pretending to be a window.** Crew and Agents are panes,
///   reached from the sidebar, drawn in the same place. Settings is reached
///   from the sidebar too, from a row directly below them, and was the only
///   one of the three that flew off somewhere else.
///
/// So: the same six tabs, in the pane, in the tab strip this app already uses
/// for the workbench. The classic preferences shape is kept — a strip of tabs,
/// one pane each — and deliberately still *not* the System Settings sidebar,
/// which is a layout for a hundred panes.
///
/// Every route in is the one flag `Workspace.showingSettings`, and every route
/// out puts you back where the pane was: the pill, a session in the list, the
/// footer row again, or Done.
struct SettingsPane: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var background: BackgroundStore
    @Binding var appearance: HoneycodeApp.Appearance

    /// Not persisted, for the reason `AppearanceSettings.half` gives about its
    /// own: which tab you were last on is a place in a window, not a
    /// preference, and reopening on it is a small surprise for no gain.
    @State private var tab = SettingsTab.accounts

    var body: some View {
        VStack(spacing: 0) {
            strip
            Divider().overlay(Theme.rule)

            // Each pane is a `Form` and does its own scrolling, so this only
            // has to give them the room and the measure.
            Group {
                switch tab {
                case .accounts:  AccountSettings()
                case .features:  FeatureSettings()
                case .crew:      CrewSettings()
                case .appearance: AppearanceSettings(store: background,
                                                     appearance: $appearance)
                case .skills:    SkillSettings()
                case .shortcuts: ShortcutSettings()
                }
            }
            // The width the Settings window used to be. A `Form` run out to the
            // full width of a 1600pt pane puts its controls a foot away from
            // their labels; the measure is what made the window readable and it
            // is not a property of being in a window.
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.canvas)
    }

    /// The tabs, and the way out.
    ///
    /// Same shape as the workbench's strip — icons with labels, a `Theme.well`
    /// fill on the selected one — because it is the same control doing the same
    /// job, and the app having two ideas of what a tab looks like is how the
    /// last review found four ideas of what a shadow looks like.
    ///
    /// All six labels or none, which is the workbench's rule and not a
    /// coincidence: keeping the label on the selected tab and dropping the
    /// other five was tried, and one named place beside five anonymous glyphs
    /// reads as a strip that failed to draw rather than as a strip that
    /// adapted.
    ///
    /// In practice the labels always fit — six of them need about 640pt, the
    /// window's minimum is 900, and the sidebar is 240 at its widest, so the
    /// pane is never narrower than 660. The guard is here for the cases that
    /// arithmetic doesn't cover: a longer translation, or accessibility text
    /// sizes.
    private var strip: some View {
        GeometryReader { geometry in
            let labelled = geometry.size.width >= 640
            HStack(spacing: Theme.s2) {
                ForEach(SettingsTab.allCases) { candidate in
                    button(candidate, labelled: labelled)
                }
                Spacer(minLength: Theme.s3)
                Button {
                    withAnimation(Motion.panel) { workspace.showingSettings = false }
                } label: {
                    Text("Done")
                        .font(Theme.label)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Theme.s4)
                        .frame(height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(HoverCapsule())
                .help("Back to what you were looking at")
            }
            .padding(.horizontal, Theme.s5)
            .frame(height: Theme.headerHeight)
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(height: Theme.headerHeight + Chrome.trafficLightClearance - Theme.s6)
    }

    private func button(_ candidate: SettingsTab, labelled: Bool) -> some View {
        let on = tab == candidate
        return Button {
            withAnimation(Motion.hover) { tab = candidate }
        } label: {
            HStack(spacing: Theme.s2) {
                Image(systemName: candidate.symbol)
                    .font(.system(size: 10.5, weight: .medium))
                if labelled {
                    Text(candidate.title)
                        .font(Theme.label)
                }
            }
            .foregroundStyle(on ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, Theme.s4)
            .frame(height: 24)
            .background(on ? Theme.well : .clear,
                        in: RoundedRectangle(cornerRadius: Theme.cornerChip))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(candidate.blurb)
    }
}

/// The six panes.
///
/// Grouped by the *thing being configured*, not by the kind of control.
///
/// The six tabs before this were General, Reading, Skills, Background,
/// Accounts and Shortcuts, and the split ran along the wrong seam. A Claude
/// account's config directory was under Accounts while the permission flag
/// that decides what that account may do was under General; the tenancy fence
/// and the spend cap — both facts about running a crew — were filed beside an
/// appearance picker; and the reading measure and the wallpaper, which are the
/// same decision about how the window looks, were two tabs apart.
///
/// Each answers one question: who can run, what this app is on this Mac, what
/// a crew is allowed to do, how it looks, what the agents know, and which keys
/// do what.
enum SettingsTab: String, CaseIterable, Identifiable {
    case accounts, features, crew, appearance, skills, shortcuts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accounts:   return "Accounts"
        case .features:   return "Features"
        case .crew:       return "Crew & Safety"
        case .appearance: return "Appearance"
        case .skills:     return "Skills"
        case .shortcuts:  return "Shortcuts"
        }
    }

    var symbol: String {
        switch self {
        case .accounts:   return "person.2"
        case .features:   return "switch.2"
        case .crew:       return "lock.shield"
        case .appearance: return "paintpalette"
        case .skills:     return "wand.and.stars"
        case .shortcuts:  return "keyboard"
        }
    }

    /// The tooltip — and the only thing naming a tab whose label the strip has
    /// dropped for width.
    var blurb: String {
        switch self {
        case .accounts:   return "The subscriptions you have, and where each keeps its login"
        case .features:   return "What this app is on this Mac"
        case .crew:       return "What the agents are allowed to do, and what a run may cost"
        case .appearance: return "The scheme, the measure and the ground"
        case .skills:     return "Instructions every agent can reach"
        case .shortcuts:  return "Which keys do what"
        }
    }
}

// MARK: - Features

/// What this app is, on this Mac.
///
/// Every one of these was written as though everybody had the thing behind it.
/// The identity switcher assumes `gh` and `az`; the Preview tab assumes you
/// want a browser in your editor; the crew assumes several subscriptions. On
/// the machine this was built on all of that holds. Elsewhere most of it is
/// chrome asking about tools that aren't installed.
///
/// A switch each, and switching one off takes its controls with it rather than
/// greying them — see `Feature`. The first run asks these questions in order
/// with their reasons attached; this is where they live afterwards.
private struct FeatureSettings: View {
    /// A local mirror, because `Features` is plain preferences rather than an
    /// observable object — the engine has no Combine in it and shouldn't grow
    /// some for eight booleans. Seeded on appear, written through on change.
    @State private var on: [Feature: Bool] = [:]

    var body: some View {
        Form {
            ForEach(Feature.Group.allCases) { group in
                Section {
                    ForEach(Feature.allCases.filter { $0.group == group }) { feature in
                        row(feature)
                    }
                } header: {
                    Text(group.title)
                }
            }


            Section {
                HStack {
                    Button("Set Up Honeycode…") {
                        Setup.rerun()
                        NotificationCenter.default.post(name: Setup.requested, object: nil)
                    }
                    Spacer()
                }
            } footer: {
                Text("The first-run flow again, from the top: which subscriptions "
                     + "you have, what should be on screen, and what the agents are "
                     + "allowed to do. It sets the same switches as this pane — "
                     + "nothing is reset by opening it.")
                    .font(Theme.note)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(maxHeight: .infinity)
        .onAppear {
            on = Dictionary(uniqueKeysWithValues: Feature.allCases.map { ($0, Features.isOn($0)) })
        }
    }

    private func row(_ feature: Feature) -> some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            Toggle(feature.title, isOn: binding(feature))
            Text(feature.blurb)
                .font(Theme.note)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Only when it is actually missing. A line saying which tool a
            // feature needs, on a Mac that has it, is a fact nobody asked for.
            if let requirement = feature.requirement, !feature.isAvailable {
                Text("`\(requirement.tool)` isn't installed — \(requirement.install)")
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.stateHeld)
            }
        }
        .padding(.vertical, Theme.s1)
    }

    private func binding(_ feature: Feature) -> Binding<Bool> {
        Binding(get: { on[feature] ?? Features.isOn(feature) },
                set: { value in
                    on[feature] = value
                    Features.set(feature, value)
                    // The system prompt, at the moment somebody asked for
                    // notifications. See `AppHost.attach`.
                    if feature == .notifications && value { Notifier.configure() }
                })
    }
}

// MARK: - Appearance

/// How the window looks: the scheme, the measure, the ground.
///
/// Reading and Background were separate tabs, which meant deciding how the
/// transcript should look involved switching between two panes and remembering
/// the other one — and the text-size sample was being judged against a
/// background it was not being shown on.
private struct AppearanceSettings: View {
    @ObservedObject var store: BackgroundStore
    @Binding var appearance: HoneycodeApp.Appearance

    /// Which half of Appearance is showing. Not persisted: it is a place in a
    /// window, not a preference, and reopening Settings on whichever sub-pane
    /// you happened to leave last is a small surprise for no gain.
    @State private var half = Half.text

    private enum Half: String, CaseIterable, Identifiable {
        case text, background
        var id: String { rawValue }
        var title: String { self == .text ? "Text" : "Background" }
    }

    /// A segmented picker, **not** a nested `TabView`.
    ///
    /// This was a `TabView` and it did not survive contact with the Settings
    /// scene. AppKit does not nest preference tab bars: the inner tabs were
    /// hoisted into the *outer* toolbar, so choosing Appearance showed seven
    /// tabs instead of five — Accounts, Crew & Safety, Appearance, Skills,
    /// Shortcuts and then a stray Text and Background — and the window title
    /// changed to "Text", which is the name of a pane nobody had selected.
    ///
    /// A `Picker` in the pane's own content is the shape the platform actually
    /// uses for a preference pane with two faces, and it cannot be promoted
    /// anywhere because it is content rather than chrome.
    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $half) {
                ForEach(Half.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
            .padding(.top, Theme.s5)
            .padding(.bottom, Theme.s3)

            switch half {
            case .text:       ReadingSettings(appearance: $appearance)
            case .background: BackgroundSettings(store: store)
            }
        }
    }
}

// MARK: - Skills

/// Instructions every agent can reach.
///
/// Deliberately a plain list rather than a browser. There will be four of
/// these, not four hundred, and the thing you come here to do is switch one on
/// or fix a line in it.
private struct SkillSettings: View {
    @StateObject private var store = SkillStore.shared
    @State private var editing: Skill?

    var body: some View {
        Form {
            Section {
                if store.skills.isEmpty {
                    empty
                } else {
                    ForEach(store.skills) { skill in
                        row(skill)
                    }
                }
            } header: {
                Text("Shared skills")
            } footer: {
                // Says what a skill *is* here, because the word means several
                // things and the one that matters is the scope: these reach
                // every account, which is the whole point of them living in the
                // app rather than in one agent's config.
                Text("Available to every account — both Claude profiles, Kimi and "
                     + "Copilot. Each session is told the name, the description and "
                     + "where the file is, and reads it when the work calls for it. "
                     + "An enabled skill is also a slash command: /branding.")
                .font(Theme.note)
                .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("New Skill…") { editing = store.add() }
                    Button("Add from File…") { importSkill() }
                    Spacer()
                    Button("Reveal in Finder") {
                        try? FileManager.default.createDirectory(
                            at: Skills.folder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(Skills.folder)
                    }
                }
            } footer: {
                Text("Skills are folders holding a SKILL.md — the same shape Claude "
                     + "Code uses, so one can be copied in or out without translation. "
                     + "Edit them here or in any editor; they're re-read each time a "
                     + "session starts.")
                .font(Theme.note)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxHeight: .infinity)
        .onAppear { store.reload() }
        .sheet(item: $editing) { skill in
            SkillEditor(skill: skill, store: store)
        }
    }

    private var empty: some View {
        Text("No shared skills yet.")
            .font(Theme.row)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Theme.s3)
    }

    private func row(_ skill: Skill) -> some View {
        HStack(spacing: Theme.s4) {
            Toggle("", isOn: Binding(get: { store.isEnabled(skill) },
                                     set: { store.setEnabled(skill, $0) }))
                .labelsHidden()

            VStack(alignment: .leading, spacing: Theme.s1) {
                Text(skill.name).font(Theme.row)
                Text(skill.summary.isEmpty ? "/\(skill.slug)" : skill.summary)
                    .font(Theme.note)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Theme.s4)

            Button("Edit") { editing = skill }
            Button {
                store.remove(skill)
            } label: {
                Image(systemName: "trash")
            }
            .help("Delete this skill")
        }
        .padding(.vertical, Theme.s1)
    }

    private func importSkill() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose a SKILL.md, or a folder containing one."
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(store.importFrom)
    }
}

/// One skill, open for editing.
private struct SkillEditor: View {
    @State var skill: Skill
    @ObservedObject var store: SkillStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s5) {
            Text("Edit Skill").font(Theme.heading)

            Form {
                TextField("Name:", text: $skill.name)
                TextField("Description:", text: $skill.summary,
                          prompt: Text("One line — this is what tells an agent whether "
                                       + "the skill applies"))
            }
            .formStyle(.columns)

            Text("Instructions")
                .font(Theme.label)
                .foregroundStyle(.tertiary)
            // A plain editor rather than anything clever. What goes in here is
            // markdown an agent reads, and the person writing it is someone who
            // writes prompts all day.
            TextEditor(text: $skill.body)
                .font(Theme.mono)
                .scrollContentBackground(.hidden)
                .padding(Theme.s3)
                .background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.cornerCard))
                .frame(minHeight: 260)

            HStack {
                // The command it answers to, said here because the slug is
                // fixed at creation and isn't otherwise visible.
                Text("/\(skill.slug)")
                    .font(Theme.monoSmall)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    store.update(skill)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.s6)
        .frame(width: 560)
    }
}

/// One account's two answers to "how much is left", side by side.
///
/// The command field is the reason this is a view rather than two more rows in
/// the form. An agent that publishes its limits somewhere this app cannot guess
/// — OpenAI's Codex is the one that prompted it — needs somebody to find the
/// right incantation, and a field that fails silently makes that a guessing
/// game played against a ring that never fills. So the field comes with a Test
/// button that runs the command now and says what came back and what parsed
/// out of it, which turns "watch a dash for a day" into one attempt.
private struct UsageAccountRow: View {
    let account: Account

    @State private var command = ""
    @State private var outcome: Outcome?
    @State private var testing = false

    private enum Outcome {
        /// It ran and the parser found windows.
        case found(String)
        /// It ran, and nothing in what it printed looked like a limit. Carries
        /// what it did print — the only thing that lets somebody fix it.
        case unparsed(String)
        /// It printed nothing at all, or never came back.
        case silent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            HStack(spacing: Theme.s4) {
                AccountDot(account)
                Text(account.title)
                Spacer(minLength: Theme.s5)
                TextField("Cap", value: cap, format: .currency(code: "USD"))
                    .frame(width: 96)
            }

            HStack(spacing: Theme.s4) {
                TextField("Command that prints its limits — optional",
                          text: $command)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.monoSmall)
                Button(testing ? "Testing…" : "Test") { probe() }
                    .disabled(testing
                              || command.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if let outcome { report(outcome) }
        }
        .padding(.vertical, Theme.s2)
        // Written as you type rather than on Return. A shell command is fiddly
        // enough to get right without also having to remember to commit it,
        // and `setUsageCommand` deliberately publishes nothing — see its own
        // note — so this costs a `UserDefaults` write per keystroke and no
        // redraws anywhere else.
        .onChange(of: command) { _, typed in
            UsageStore.shared.setUsageCommand(typed, for: account)
        }
        .onAppear { command = UsageStore.shared.usageCommand(for: account) ?? "" }
    }

    @ViewBuilder
    private func report(_ outcome: Outcome) -> some View {
        switch outcome {
        case .found(let summary):
            Text(summary)
                .font(Theme.note)
                .foregroundStyle(Theme.stateDone)
        case .unparsed(let output):
            VStack(alignment: .leading, spacing: Theme.s1) {
                Text("It ran, but nothing in the output looked like a limit. "
                     + "A line has to read like \u{201C}name: 21% used\u{201D} "
                     + "or \u{201C}name: 123 of 300\u{201D}.")
                Text(output)
                    .font(Theme.monoSmall)
                    .textSelection(.enabled)
            }
            .font(Theme.note)
            .foregroundStyle(Theme.stateHeld)
            .fixedSize(horizontal: false, vertical: true)
        case .silent:
            Text("Nothing came back within 20 seconds. Check the command runs "
                 + "on its own in a terminal — this has launchd\u{2019}s PATH "
                 + "plus the usual install prefixes, not your shell\u{2019}s.")
                .font(Theme.note)
                .foregroundStyle(Theme.stateBad)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Isolation spelled out rather than inferred. Everything else in this
    /// view reaches `UsageStore.shared` from a closure SwiftUI already runs on
    /// the main actor; this is the one method that starts a task of its own,
    /// and a task inheriting the wrong context here would be a compile error
    /// several files away from the cause.
    @MainActor
    private func probe() {
        testing = true
        outcome = nil
        let candidate = command
        Task {
            let (output, reading) = await UsageStore.shared.test(candidate)
            testing = false
            guard let reading else {
                outcome = output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? .silent
                    : .unparsed(Self.excerpt(output))
                return
            }
            // Read back, so what is confirmed is what the rail will draw rather
            // than a second opinion formed here.
            UsageStore.shared.refresh(account, force: true)
            outcome = .found("Found " + reading.windows
                .map { "\($0.title) \($0.percent)%" }
                .joined(separator: ", "))
        }
    }

    /// Enough of the output to recognise, not enough to take over the pane.
    private static func excerpt(_ text: String, lines: Int = 6) -> String {
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(lines)
            .joined(separator: "\n")
        return kept.count > 400 ? String(kept.prefix(400)) + "…" : kept
    }

    private var cap: Binding<Double> {
        Binding(get: { UsageStore.shared.hasOwnCap(account)
                       ? UsageStore.shared.cap(for: account) : 0 },
                set: { UsageStore.shared.setCap($0, for: account) })
    }
}

// MARK: - General

/// What a crew is allowed to do, and what it may spend.
///
/// These three were spread across General — beside an appearance picker — and,
/// in the case of the per-project verification command, buried inside a popover
/// inside the composer. They are one subject: the rules a run operates under.
private struct CrewSettings: View {
    @AppStorage("agent.skipPermissions") private var skipPermissions = true
    /// The key `Tenancy.gates` reads. `@AppStorage` and that property are the
    /// same `UserDefaults` entry seen from two sides — the engine can't import
    /// SwiftUI, and a second stored copy would be a setting that disagreed with
    /// itself.
    @AppStorage("tenancy.gateDelegation") private var gateDelegation = true
    /// The key `Agents.unattendedWritesAllowed` reads, same arrangement.
    @AppStorage("agents.unattendedWrites") private var unattendedWrites = false
    @AppStorage("usage.monthlyCap") private var monthlyCap: Double = 500
    @State private var recordedSpend: Double = UsageStore.shared.baseline(for: .work)

    var body: some View {
        Form {
            Section {
                Toggle("Skip permission prompts", isOn: $skipPermissions)
                Text(skipPermissions
                     ? "Agents edit files and run commands without asking. Turn "
                       + "this off and Claude can read but every write is refused — "
                       + "there is no middle setting over its headless protocol."
                     : "Claude can read and search, but every edit is refused. "
                       + "Copilot still asks per action.")
                    .font(Theme.note)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Let scheduled agents write", isOn: $unattendedWrites)
                Text(unattendedWrites
                     ? "An agent set to Act edits files and runs commands when "
                       + "its schedule fires, with nobody watching. It is still "
                       + "confined to its own folder — that part isn't optional "
                       + "for an unattended run."
                     : "Scheduled runs are held to propose only, whatever the "
                       + "agent is set to. Running one by hand uses its own "
                       + "setting, because you are sitting there. Either way an "
                       + "unattended run is confined to its folder: Propose is a "
                       + "paragraph asking an agent not to write, and the folder "
                       + "is the fence that actually holds.")
                    .font(Theme.note)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Permissions")
            }

            Section {
                Toggle("Keep Enterprise work inside Enterprise", isOn: $gateDelegation)
                Text(gateDelegation
                     ? "When an Enterprise session hands a piece of work to "
                       + "Kimi, Copilot or your personal Claude, the task is "
                       + "checked on this account before it is sent, and those "
                       + "agents work in an empty folder with no sight of the "
                       + "project. Anything that would carry customer names, "
                       + "credentials or internal specifics comes back for "
                       + "Enterprise to do itself."
                     : "Off. An Enterprise session hands work to the other "
                       + "agents unchecked, and they work in this project's "
                       + "directory with the same access everyone else has.")
                    .font(Theme.note)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Tenancy")
            }

            Section {
                TextField("Default monthly cap", value: $monthlyCap,
                          format: .currency(code: "USD"))
                ForEach(Account.enabled) { account in
                    UsageAccountRow(account: account)
                }
                Text("Two ways to fill a ring, and the first one wins. Ask "
                     + "the agent: a command that prints this plan's limits, "
                     + "run every half-minute or so while something is "
                     + "watching — anything in its output shaped like "
                     + "\u{201C}name: 21% used\u{201D} or "
                     + "\u{201C}name: 123 of 300\u{201D} becomes a window. "
                     + "Or measure it here: what Honeycode has spent this "
                     + "month against the cap, which is per account because "
                     + "$500 is a plausible ceiling for a usage-based seat and "
                     + "nonsense for a $20 subscription. Leave a cap at zero "
                     + "to use the default above.")
                    .font(Theme.note)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Usage")
            }

            Section {
                LabeledContent("Recorded spend") {
                    HStack(spacing: Theme.s4) {
                        TextField("", value: $recordedSpend,
                                  format: .currency(code: "USD"))
                            .frame(width: 96)
                        Button("Set") {
                            UsageStore.shared.setBaseline(recordedSpend, for: .work)
                        }
                    }
                }
                Text("Honeycode can only count its own turns, so on a seat you "
                     + "also use from the terminal its figure reads low. Type "
                     + "the real number from your admin console and it accrues "
                     + "from there — setting it again just replaces it, so it "
                     + "can't double-count.")
                    .font(Theme.note)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Spend · Claude Work")
            }
        }
        .formStyle(.grouped)
        .frame(maxHeight: .infinity)
        // Both flags are fixed at process launch, so live sessions restart.
        .onChange(of: skipPermissions) {
            NotificationCenter.default.post(name: ClaudeAdapter.permissionsChanged, object: nil)
        }
    }

}

// MARK: - Reading

/// Text size and measure.
///
/// Both matter and they're independent: bigger type in the same column means
/// fewer words per line, which is a different reading experience from the same
/// type in a wider one. The sample shows the pair together, because that's the
/// only way to judge either.
private struct ReadingSettings: View {
    /// The light/dark override, here rather than in a General tab that no
    /// longer exists. It belongs beside the measure and the ground: those three
    /// are one decision about how the transcript reads, and judging any of them
    /// against the other two was the point of a preview.
    @Binding var appearance: HoneycodeApp.Appearance
    @AppStorage("transcript.textScale") private var textScale: Double = 1
    @AppStorage("transcript.width") private var width: Double = Double(Theme.readingWidth)

    /// Roughly how many characters land on a line — the number typography
    /// actually cares about. 45–75 is the long-standing comfortable range.
    private var measure: Int {
        Int(width / (Prose.base * CGFloat(textScale) * 0.5))
    }

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(HoneycodeApp.Appearance.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
            }

            Section {
                LabeledContent("Text size") {
                    HStack(spacing: Theme.s5) {
                        Slider(value: $textScale, in: 0.85...1.45, step: 0.05)
                        Text("\(Int(textScale * 100))%")
                            .font(Theme.monoSmall)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 42, alignment: .trailing)
                    }
                }
                LabeledContent("Column width") {
                    HStack(spacing: Theme.s5) {
                        Slider(value: $width, in: 520...1000, step: 20)
                        Text("\(Int(width))")
                            .font(Theme.monoSmall)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 42, alignment: .trailing)
                    }
                }
                HStack {
                    Text("About \(measure) characters per line")
                        .font(Theme.note)
                        .foregroundStyle(measure > 85 || measure < 40
                                         ? AnyShapeStyle(Color.diffDelText)
                                         : AnyShapeStyle(.tertiary))
                    Spacer()
                    Button("Reset") { textScale = 1; width = Double(Theme.readingWidth) }
                        .buttonStyle(.link)
                }
            } header: {
                Text("Transcript")
            }

            Section {
                sample
                    .environment(\.proseScale, CGFloat(textScale))
                    .frame(width: min(CGFloat(width), 560))
                    .frame(maxWidth: .infinity, alignment: .center)
            } header: {
                Text("Preview")
            }
        }
        .formStyle(.grouped)
        // Was pinned to 560 to match `BackgroundSettings`, the other half of
        // this pane: two heights behind one segmented control read as the
        // *window* flinching every time you touched it. In the pane there is
        // no window to flinch — the pane is the size it is, and both halves
        // fill it — so the pin is gone and each half keeps its own measure.
        .frame(maxHeight: .infinity)
    }

    private var sample: some View {
        MarkdownText(raw: """
            ## Heading

            Body text at the current size, with `inline code` and a **bold** run, \
            long enough to wrap so the measure is visible.

            - A list item
            - Another one
            """)
    }
}

// MARK: - Shortcuts

private struct ShortcutSettings: View {

    /// Key combinations, in the app's own voice.
    ///
    /// These were SF Rounded, which Theme forbids in the first line of its own
    /// rules — rounded is a watchOS/Home voice. It reads as a key cap, which is
    /// presumably why it got in, but macOS's own Keyboard Shortcuts pane sets
    /// combinations in plain system type and the glyphs that carry most of the
    /// meaning here (⌘ ⌥ ⇧ ⌃) are identical in both faces anyway. So the
    /// affectation cost the app a second typeface and bought nothing.
    ///
    /// Stated once rather than five times, which is how it came to be five
    /// identical literals in one view.
    private static let keyCap = Theme.rowStrong

    var body: some View {
        Form {
            Section {
                ForEach(Shortcuts.sessions) { shortcut in
                    LabeledContent(shortcut.title) {
                        Text(shortcut.display)
                            .font(Self.keyCap)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Sessions")
            }

            // Built from `Account.enabled` rather than written out, for the
            // same reason the transcript modes below are built from
            // `allCases`: a list of shortcuts maintained by hand is a list
            // that goes quietly out of date, which is the failure this whole
            // file exists to prevent. Switching an account off in Accounts
            // takes its row with it, because the key stops doing anything.
            Section {
                ForEach(Account.enabled.filter { $0.shortcut != nil }) { account in
                    LabeledContent(account.title) {
                        Text("⌘\(account.shortcut?.character.description ?? "")")
                            .font(Self.keyCap)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Focus an account")
            } footer: {
                Text("Selects the session you last had open on that account, "
                     + "and does nothing if you have none. An account you added "
                     + "yourself gets no key: the number would depend on the "
                     + "order things were added, so it would mean different "
                     + "accounts on two Macs.")
            }

            Section {
                ForEach(Shortcuts.columns) { shortcut in
                    LabeledContent(shortcut.title) {
                        Text(shortcut.display)
                            .font(Self.keyCap)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Columns")
            } footer: {
                Text("Up to three conversations side by side. How many fit is "
                     + "decided by the window width.")
            }

            Section {
                ForEach(Shortcuts.view) { shortcut in
                    LabeledContent(shortcut.title) {
                        Text(shortcut.display)
                            .font(Self.keyCap)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Presentation")
            } footer: {
                Text("Coding mode draws the transcript as a terminal — one "
                     + "monospaced scrollback instead of cards. It appends "
                     + "rather than redrawing, so a long session streams at the "
                     + "same speed as a new one.")
            }

            Section {
                ForEach(TranscriptMode.allCases) { mode in
                    LabeledContent(mode.title) {
                        Text("⌥⌘\(mode.shortcut.character.description)")
                            .font(Self.keyCap)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Transcript detail")
            }

            Section {
                ForEach(Shortcuts.composer, id: \.0) { title, keys in
                    LabeledContent(title) {
                        Text(keys)
                            .font(Self.keyCap)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Composer")
            }
        }
        .formStyle(.grouped)
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Background

/// Modelled on System Settings → Wallpaper: one large live preview at the top,
/// then a grid of thumbnails underneath. The preview matters more than it
/// looks — a photo that reads fine as a 160pt thumbnail can be completely
/// unusable behind body text, and this is where you find that out.
private struct BackgroundSettings: View {
    @ObservedObject var store: BackgroundStore

    private let columns = [GridItem(.adaptive(minimum: 132), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s6) {
                preview
                veilControl
                Divider().overlay(Theme.rule)
                library
            }
            .padding(Theme.s7)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: Preview

    private var preview: some View {
        VStack(alignment: .leading, spacing: Theme.s4) {
            ZStack {
                PaneBackground(store: store, honoursCodingMode: false)

                // A miniature of the real thing — greeting and composer — so
                // you're judging legibility rather than the photo.
                VStack(spacing: Theme.s5) {
                    Text("Good afternoon")
                        .font(Theme.display(17))
                    RoundedRectangle(cornerRadius: Theme.cornerCard * 2)
                        .fill(Theme.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.cornerCard * 2)
                                .strokeBorder(Theme.rule, lineWidth: 1))
                        .frame(width: 300, height: 52)
                        .overlay(alignment: .leading) {
                            Text("Message Personal…")
                                .font(Theme.note)
                                .foregroundStyle(.tertiary)
                                .padding(.leading, Theme.s5)
                                .padding(.bottom, Theme.s6)
                        }
                }
            }
            .frame(height: 232)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerCard))
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerCard)
                .strokeBorder(Theme.rule, lineWidth: 1))

            HStack {
                Text(store.selected?.name ?? "No background")
                    .font(Theme.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if store.selected != nil {
                    Button("Clear") { store.select(nil) }
                        .buttonStyle(.link)
                }
            }
        }
    }

    private var veilControl: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            HStack {
                Text("Glass")
                    .font(Theme.body)
                Spacer()
                Text("\(Int(store.veil * 100))%")
                    .font(Theme.monoSmall)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            Slider(value: $store.veil, in: 0...1)
            Text("How much the background is frosted. At zero the image is "
                 + "sharp; turn it up and it diffuses to colour, which is "
                 + "what keeps text over it readable.")
                .font(Theme.note)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(store.selected == nil)
        .opacity(store.selected == nil ? 0.45 : 1)
    }

    // MARK: Library

    private var library: some View {
        VStack(alignment: .leading, spacing: Theme.s5) {
            HStack {
                VStack(alignment: .leading, spacing: Theme.s1) {
                    Text("Library")
                        .font(Theme.title)
                    Text(store.items.isEmpty
                         ? "Copied into Honeycode, so the originals can move or go"
                         : "\(store.items.count) image\(store.items.count == 1 ? "" : "s")")
                        .font(Theme.note)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Add Images…") { store.importImages() }
            }

            if store.items.isEmpty {
                emptyLibrary
            } else {
                // Grouped rather than one flat grid: fifteen unlabelled
                // thumbnails is a wall, and the thing you're actually choosing
                // is a mood — abstract or photographic, bright or dark.
                ForEach(store.categories, id: \.self) { category in
                    VStack(alignment: .leading, spacing: Theme.s4) {
                        Text(category)
                            .font(.system(size: Theme.t2, weight: .semibold))
                            .foregroundStyle(.secondary)
                        LazyVGrid(columns: columns, spacing: Theme.gapBlock) {
                            ForEach(store.items(in: category)) { item in
                                Thumbnail(item: item,
                                          image: store.thumbnails[item.file],
                                          categories: store.categories,
                                          selected: store.selected?.id == item.id,
                                          onSelect: { store.select(item) },
                                          onRename: { store.rename(item, to: $0) },
                                          onCategorise: { store.categorise(item, as: $0) },
                                          onRemove: { store.remove(item) })
                            }
                        }
                    }
                    .padding(.bottom, Theme.s3)
                }
            }
        }
    }

    private var emptyLibrary: some View {
        VStack(spacing: Theme.s3) {
            Text("No backgrounds yet")
                .font(Theme.body)
                .foregroundStyle(.secondary)
            Text("Add images and Honeycode keeps its own copy, so you can tidy "
                 + "your Downloads folder afterwards.")
                .font(Theme.note)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.s8)
    }
}

private struct Thumbnail: View {
    let item: BackgroundItem
    let image: NSImage?
    var categories: [String] = []
    let selected: Bool
    let onSelect: () -> Void
    let onRename: (String) -> Void
    var onCategorise: (String?) -> Void = { _ in }
    let onRemove: () -> Void

    @State private var renaming = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            Button(action: onSelect) {
                ZStack {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Theme.well
                    }
                }
                .frame(height: 84)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerChip))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cornerChip)
                        .strokeBorder(selected ? Color.accentColor : Theme.rule,
                                      lineWidth: selected ? 2.5 : 1)
                )
                .overlay(alignment: .bottomTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(.white, Color.accentColor)
                            .padding(Theme.s3)
                    }
                }
            }
            .buttonStyle(.plain)

            // Name sits under the thumbnail, Photos-style, and edits in place.
            if renaming {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(Theme.note)
                    .focused($focused)
                    .onSubmit { onRename(draft); renaming = false }
                    .onExitCommand { renaming = false }
            } else {
                Text(item.name)
                    .font(Theme.note)
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .onTapGesture(count: 2) { beginRename() }
            }
        }
        .contextMenu {
            Button("Rename") { beginRename() }
            Menu("Category") {
                ForEach(categories.filter { $0 != BackgroundStore.unsorted }, id: \.self) { name in
                    Button(name == item.group ? "✓ \(name)" : name) { onCategorise(name) }
                }
                Divider()
                Button("Unsorted") { onCategorise(nil) }
            }
            Divider()
            Button("Remove", role: .destructive) { onRemove() }
        }
        .help(item.name)
    }

    private func beginRename() {
        draft = item.name
        renaming = true
        DispatchQueue.main.async { focused = true }
    }
}
