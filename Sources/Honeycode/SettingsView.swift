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
        // The measure is worked out here, on the pane, and handed to the strip
        // and the page alike. See `SettingsMetrics.inset`.
        GeometryReader { geometry in
            let inset = SettingsMetrics.inset(for: geometry.size.width)
            VStack(spacing: 0) {
                strip(inset: inset, available: geometry.size.width)
                Divider().overlay(Theme.rule)

                // Each pane is a `SettingsPage` and does its own scrolling, so
                // this only has to give them the room. It used to pin them to
                // 640 — the width the Settings *window* used to be — which was
                // a second measure the tab strip above knew nothing about.
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .environment(\.settingsInset, inset)
        }
        .background(Theme.canvas)
    }

    /// The tabs, and the way out.
    ///
    /// Same shape as the pane's own strip — icons with labels, a `Theme.surface`
    /// chip on the selected one — because it is the same control doing the same
    /// job, and the app having two ideas of what a tab looks like is how the
    /// last review found four ideas of what a shadow looks like. `PaneTabs` and
    /// the sidebar's segmented pill draw the selected one the same way.
    ///
    /// All six labels or none, which is the workbench's rule and not a
    /// coincidence: keeping the label on the selected tab and dropping the
    /// other five was tried, and one named place beside five anonymous glyphs
    /// reads as a strip that failed to draw rather than as a strip that
    /// adapted.
    ///
    /// In practice the labels always fit — six of them need about 550pt and
    /// the measure is 680. The guard is here for the cases that arithmetic
    /// doesn't cover: a longer translation, or accessibility text sizes.
    ///
    /// Set to the same measure and the same leading inset as the cards below
    /// it, so the tabs start where the cards start and Done ends where they
    /// end. It used to span the pane while the panes were pinned to a narrower
    /// column of their own, which put the tabs a couple of centimetres left of
    /// everything they switch between and left Done stranded a foot from the
    /// last tab.
    private func strip(inset: CGFloat, available: CGFloat) -> some View {
        let labelled = min(SettingsMetrics.measure, available - Theme.s6 * 2) >= 620
        return HStack(spacing: Theme.s2) {
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
        .frame(maxWidth: SettingsMetrics.measure, alignment: .leading)
        .padding(.leading, inset)
        .padding(.trailing, Theme.s6)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The pane's own strip height, so this row sits on the same line as the
        // tab strip a session shows — Settings covers the pane and leaves the
        // rest of the window alone, and a header half a centimetre off the one
        // it replaced is the tell that it is a different kind of thing.
        //
        // It used to add a traffic-light clearance, because there was no bar
        // above it and the lights were its problem. There is now.
        .frame(height: Theme.tabStripHeight)
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
            .background(on ? Theme.surface : .clear,
                        in: RoundedRectangle(cornerRadius: Theme.cornerChip))
            .shadow(color: on ? Theme.shadowLow.colour : .clear,
                    radius: Theme.shadowLow.radius, y: Theme.shadowLow.y)
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
        SettingsPage {
            ForEach(Feature.Group.allCases) { group in
                SettingsGroup(group.title) {
                    ForEach(Feature.allCases.filter { $0.group == group }) { feature in
                        row(feature)
                    }
                }
            }

            SettingsGroup(footer:
                "The first-run flow again, from the top: which subscriptions you "
                + "have, what should be on screen, and what the agents are allowed "
                + "to do. It sets the same switches as this pane — nothing is reset "
                + "by opening it.") {
                SettingsActions {
                    Button("Set Up Honeycode…") {
                        Setup.rerun()
                        NotificationCenter.default.post(name: Setup.requested, object: nil)
                    }
                }
            }
        }
        .onAppear {
            on = Dictionary(uniqueKeysWithValues: Feature.allCases.map { ($0, Features.isOn($0)) })
        }
    }

    /// The blurb is the row's own note, and the missing-tool line joins it
    /// rather than sitting under it in the state colour. Two lines of type in
    /// two sizes and two colours under one switch was more emphasis than "you
    /// haven't installed the thing" needs.
    private func row(_ feature: Feature) -> some View {
        SettingsToggle(feature.title, note: note(for: feature),
                       isOn: binding(feature))
    }

    private func note(for feature: Feature) -> String {
        // Only when it is actually missing. A line saying which tool a feature
        // needs, on a Mac that has it, is a fact nobody asked for.
        guard let requirement = feature.requirement, !feature.isAvailable else {
            return feature.blurb
        }
        return feature.blurb + "\n\u{2022} \(requirement.tool) isn\u{2019}t installed — \(requirement.install)"
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
    @Environment(\.settingsInset) private var inset

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
            // On the content column's own left edge rather than centred over
            // it. Centred, it was the one control in Settings that lined up
            // with nothing — a segmented pill floating above a left-aligned
            // page, which reads as a control belonging to the window rather
            // than to the pane under it.
            Picker("", selection: $half) {
                ForEach(Half.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)
            .frame(maxWidth: SettingsMetrics.measure, alignment: .leading)
            .padding(.leading, inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Theme.s6)

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
        SettingsPage {
            // Says what a skill *is* here, because the word means several
            // things and the one that matters is the scope: these reach every
            // account, which is the whole point of them living in the app
            // rather than in one agent's config.
            SettingsGroup("Shared skills", footer:
                "Available to every account — both Claude profiles, Kimi and "
                + "Copilot. Each session is told the name, the description and where "
                + "the file is, and reads it when the work calls for it. An enabled "
                + "skill is also a slash command: /branding.") {
                if store.skills.isEmpty {
                    SettingsRow { empty }
                } else {
                    ForEach(store.skills) { skill in
                        row(skill)
                    }
                }
                SettingsActions {
                    Button("New Skill…") { editing = store.add() }
                    Button("Add from File…") { importSkill() }
                    Spacer()
                    Button("Reveal in Finder") {
                        try? FileManager.default.createDirectory(
                            at: Skills.folder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(Skills.folder)
                    }
                }
            }

            SettingsGroup(footer:
                "Skills are folders holding a SKILL.md — the same shape Claude Code "
                + "uses, so one can be copied in or out without translation. Edit "
                + "them here or in any editor; they\u{2019}re re-read each time a "
                + "session starts.") {
                SettingsRow("Where they live") {
                    Text(Skills.folder.path
                        .replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(Theme.monoSmall)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
        }
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
    }

    private func row(_ skill: Skill) -> some View {
        SettingsRow {
            HStack(spacing: Theme.s4) {
                Toggle("", isOn: Binding(get: { store.isEnabled(skill) },
                                         set: { store.setEnabled(skill, $0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)

                VStack(alignment: .leading, spacing: Theme.s1) {
                    Text(skill.name).font(Theme.sidebarRow)
                    Text(skill.summary.isEmpty ? "/\(skill.slug)" : skill.summary)
                        .font(Theme.note)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: Theme.s5)

                Button("Edit") { editing = skill }
                // Was a bordered trash button beside a bordered Edit — two
                // buttons of equal weight, one of which deletes. The glyph
                // recedes to a plain control and keeps its tooltip.
                Button {
                    store.remove(skill)
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Delete this skill")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
        SettingsRow {
            VStack(alignment: .leading, spacing: Theme.s3) {
                HStack(spacing: Theme.s4) {
                    AccountDot(account)
                    Text(account.title).font(Theme.sidebarRow)
                    Spacer(minLength: Theme.s5)
                    Text("Cap")
                        .font(Theme.note)
                        .foregroundStyle(.secondary)
                    TextField("", value: cap, format: .currency(code: "USD"))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 110)
                }

                HStack(spacing: Theme.s4) {
                    // A prompt, not a label. It was the field's first argument,
                    // which `.formStyle(.grouped)` promotes to a leading label —
                    // so this sentence rendered as two lines of monospace beside
                    // an apparently empty field, and the field itself looked
                    // like it had no border.
                    TextField("", text: $command,
                              prompt: Text("Command that prints its limits — optional"))
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.monoSmall)
                    Button(testing ? "Testing…" : "Test") { probe() }
                        .disabled(testing
                                  || command.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if let outcome { report(outcome) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
            // Read back, so what is confirmed is what the Crew pane will draw
            // rather than a second opinion formed here.
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
    /// The three governed switches, read and written through `Policy` rather
    /// than through `@AppStorage`.
    ///
    /// `@AppStorage` was right while these were only ever this Mac's business.
    /// It is wrong now: it writes straight to `UserDefaults`, which a managed
    /// key ignores — so the toggle would move, the value would not, and the
    /// control would spring back looking broken. `Policy.set` reports whether
    /// the write landed, and a managed control is disabled rather than allowed
    /// to lie.
    ///
    /// Mirrored into `@State` because `Policy` is plain preferences with no
    /// Combine in it — the same arrangement, and for the same reason, as
    /// `FeatureSettings`.
    @State private var governed: [Policy.Key: Bool] = [:]
    @AppStorage("usage.monthlyCap") private var monthlyCap: Double = 500
    @State private var recordedSpend: Double = UsageStore.shared.baseline(for: .work)
    @State private var auditLines = 0

    private func on(_ key: Policy.Key, default fallback: Bool) -> Binding<Bool> {
        Binding(get: { governed[key] ?? Policy.value(key, default: fallback) },
                set: { governed[key] = $0; Policy.set(key, $0) })
    }

    var body: some View {
        SettingsPage {
            SettingsGroup("Permissions") {
                SettingsToggle(
                    "Skip permission prompts",
                    note: Policy.value(.skipPermissions, default: true)
                        ? "Agents edit files and run commands without asking. Turn "
                          + "this off and Claude can read but every write is refused — "
                          + "there is no middle setting over its headless protocol."
                        : "Claude can read and search, but every edit is refused. "
                          + "Copilot still asks per action.",
                    locked: Policy.isManaged(.skipPermissions),
                    isOn: on(.skipPermissions, default: true))

                SettingsToggle(
                    "Let scheduled agents write",
                    note: Policy.value(.unattendedWrites, default: false)
                        ? "An agent set to Act edits files and runs commands when "
                          + "its schedule fires, with nobody watching. It is still "
                          + "confined to its own folder — that part isn\u{2019}t optional "
                          + "for an unattended run."
                        : "Scheduled runs are held to propose only, whatever the "
                          + "agent is set to. Running one by hand uses its own "
                          + "setting, because you are sitting there. Either way an "
                          + "unattended run is confined to its folder: Propose is a "
                          + "paragraph asking an agent not to write, and the folder "
                          + "is the fence that actually holds.",
                    locked: Policy.isManaged(.unattendedWrites),
                    isOn: on(.unattendedWrites, default: false))
            }

            SettingsGroup("Tenancy") {
                SettingsToggle(
                    "Keep Enterprise work inside Enterprise",
                    note: Policy.value(.tenancyGate, default: true)
                        ? "When an Enterprise session hands a piece of work to "
                          + "Kimi, Copilot or your personal Claude, the task is "
                          + "checked on this account before it is sent, and those "
                          + "agents work in an empty folder with no sight of the "
                          + "project. Anything that would carry customer names, "
                          + "credentials or internal specifics comes back for "
                          + "Enterprise to do itself."
                        : "Off. An Enterprise session hands work to the other "
                          + "agents unchecked, and they work in this project\u{2019}s "
                          + "directory with the same access everyone else has.",
                    locked: Policy.isManaged(.tenancyGate),
                    isOn: on(.tenancyGate, default: true))
            }

            SettingsGroup("Usage", footer:
                "Two ways to fill a ring, and the first one wins. Ask the agent: a "
                + "command that prints this plan\u{2019}s limits, run every half-minute "
                + "or so while something is watching — anything in its output shaped "
                + "like \u{201C}name: 21% used\u{201D} or \u{201C}name: 123 of 300\u{201D} "
                + "becomes a window. Or measure it here: what Honeycode has spent this "
                + "month against the cap, which is per account because $500 is a "
                + "plausible ceiling for a usage-based seat and nonsense for a $20 "
                + "subscription. Leave a cap at zero to use the default above.") {
                SettingsRow("Default monthly cap") {
                    TextField("", value: $monthlyCap, format: .currency(code: "USD"))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 110)
                }
                ForEach(Account.enabled) { account in
                    UsageAccountRow(account: account)
                }
            }

            SettingsGroup("Record", footer:
                "One line of JSON per decision: a piece of work refused at the "
                + "tenancy fence or cleared through it, a delegate given a confined "
                + "folder, a scheduled run held to propose only. Kept for 90 days and "
                + "trimmed at launch.\n\nWhat it does not contain is the work itself — "
                + "a task is recorded as a hash, which can tell you two entries are "
                + "about the same piece and nothing else. Writing the material this "
                + "app is protecting into a log beside it would defeat the thing "
                + "doing the protecting.") {
                SettingsToggle("Keep a record of policy decisions",
                               locked: Policy.isManaged(.auditing),
                               isOn: on(.auditing, default: true))
                SettingsRow("Entries") {
                    HStack(spacing: Theme.s4) {
                        Text(String(auditLines))
                            .font(Theme.row)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([Audit.url])
                        }
                        .disabled(auditLines == 0)
                    }
                }
            }

            SettingsGroup("Spend · Claude Work", footer:
                "Honeycode can only count its own turns, so on a seat you also use "
                + "from the terminal its figure reads low. Type the real number from "
                + "your admin console and it accrues from there — setting it again "
                + "just replaces it, so it can\u{2019}t double-count.") {
                SettingsRow("Recorded spend") {
                    HStack(spacing: Theme.s4) {
                        TextField("", value: $recordedSpend,
                                  format: .currency(code: "USD"))
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 110)
                        Button("Set") {
                            UsageStore.shared.setBaseline(recordedSpend, for: .work)
                        }
                    }
                }
            }
        }
        // Fixed at process launch, so live sessions restart. Watched through
        // the mirror rather than through `@AppStorage`, which this no longer
        // has — and the mirror only moves when the write actually landed, so a
        // managed key can't fire this by being clicked at.
        .onChange(of: governed[.skipPermissions]) { _, _ in
            NotificationCenter.default.post(name: ClaudeAdapter.permissionsChanged, object: nil)
        }
        .onAppear { auditLines = Audit.all().count }
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
        SettingsPage {
            SettingsGroup {
                SettingsRow("Appearance") {
                    Picker("", selection: $appearance) {
                        ForEach(HoneycodeApp.Appearance.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
            }

            SettingsGroup("Transcript", footer: "About \(measure) characters per line. "
                          + "Between 45 and 75 is the long-standing comfortable range.") {
                SettingsRow("Text size") {
                    HStack(spacing: Theme.s5) {
                        Slider(value: $textScale, in: 0.85...1.45, step: 0.05)
                            .frame(width: 220)
                        Text("\(Int(textScale * 100))%")
                            .font(Theme.monoSmall)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 42, alignment: .trailing)
                    }
                }
                SettingsRow("Column width") {
                    HStack(spacing: Theme.s5) {
                        Slider(value: $width, in: 520...1000, step: 20)
                            .frame(width: 220)
                        // Not interpolated: a measurement in points is not a
                        // quantity to group, and this one reaches exactly 1000.
                        Text(String(Int(width)))
                            .font(Theme.monoSmall)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 42, alignment: .trailing)
                    }
                }
                SettingsRow {
                    HStack {
                        // Only when it is outside the range — the figure itself
                        // is in the footnote, where it doesn't need a colour to
                        // be read. This line is the warning, so it only exists
                        // when there is one.
                        if measure > 85 || measure < 40 {
                            Text(measure > 85 ? "Long lines are hard to track back from"
                                              : "Short lines break the reading rhythm")
                                .font(Theme.note)
                                .foregroundStyle(Theme.stateHeld)
                        }
                        Spacer()
                        Button("Reset") { textScale = 1; width = Double(Theme.readingWidth) }
                            .buttonStyle(.link)
                    }
                }
            }

            SettingsGroup("Preview") {
                SettingsRow {
                    sample
                        .environment(\.proseScale, CGFloat(textScale))
                        .frame(maxWidth: min(CGFloat(width), Theme.readingWidth - Theme.s7))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
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
        SettingsPage {
            SettingsGroup("Sessions") {
                ForEach(Shortcuts.sessions) { shortcut in
                    key(shortcut.title, shortcut.display)
                }
            }

            // Built from `Account.enabled` rather than written out, for the
            // same reason the transcript modes below are built from
            // `allCases`: a list of shortcuts maintained by hand is a list
            // that goes quietly out of date, which is the failure this whole
            // file exists to prevent. Switching an account off in Accounts
            // takes its row with it, because the key stops doing anything.
            SettingsGroup("Focus an account", footer:
                "Selects the session you last had open on that account, and does "
                + "nothing if you have none. An account you added yourself gets no "
                + "key: the number would depend on the order things were added, so "
                + "it would mean different accounts on two Macs.") {
                ForEach(Account.enabled.filter { $0.shortcut != nil }) { account in
                    key(account.title, "⌘\(account.shortcut?.character.description ?? "")")
                }
            }

            SettingsGroup("This conversation", footer:
                "The pop-out is a small window that stays above other apps, so a "
                + "long run stays watchable while you work in something else.") {
                ForEach(Shortcuts.conversation) { shortcut in
                    key(shortcut.title, shortcut.display)
                }
            }

            SettingsGroup("Presentation", footer:
                "Coding mode draws the transcript as a terminal — one monospaced "
                + "scrollback instead of cards. It appends rather than redrawing, so "
                + "a long session streams at the same speed as a new one.") {
                ForEach(Shortcuts.view) { shortcut in
                    key(shortcut.title, shortcut.display)
                }
            }

            SettingsGroup("Transcript detail") {
                ForEach(TranscriptMode.allCases) { mode in
                    key(mode.title, "⌥⌘\(mode.shortcut.character.description)")
                }
            }

            SettingsGroup("Composer") {
                ForEach(Shortcuts.composer, id: \.0) { title, keys in
                    key(title, keys)
                }
            }
        }
    }

    private func key(_ title: String, _ keys: String) -> some View {
        SettingsRow(title) {
            Text(keys)
                .font(Self.keyCap)
                .foregroundStyle(.secondary)
        }
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
        // The same page as the other half of this tab. It was a `ScrollView`
        // of its own with a `Theme.s7` inset and no measure at all, so
        // switching from Text to Background moved every left edge in the pane.
        SettingsPage {
            preview
            veilControl
            library
        }
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
                    .font(Theme.sidebarRow)
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
        SettingsGroup(footer: "How much the background is frosted. At zero the "
                      + "image is sharp; turn it up and it diffuses to colour, "
                      + "which is what keeps text over it readable.") {
            SettingsRow("Glass") {
                HStack(spacing: Theme.s5) {
                    Slider(value: $store.veil, in: 0...1)
                        .frame(width: 220)
                    Text("\(Int(store.veil * 100))%")
                        .font(Theme.monoSmall)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }
            }
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
                        .foregroundStyle(.secondary)
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
                            .font(Theme.label)
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
                .font(Theme.sidebarRow)
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
