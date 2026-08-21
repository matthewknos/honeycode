import SwiftUI
import AppKit

/// The Settings window (⌘,).
///
/// Classic macOS preferences shape: a toolbar of tabs, one pane each, sized to
/// its content. Deliberately *not* the System Settings sidebar — that layout is
/// for a hundred panes, and borrowing it for two makes an app look like it's
/// wearing a coat three sizes too big.
struct SettingsView: View {
    @ObservedObject var background: BackgroundStore
    @Binding var appearance: HoneycodeApp.Appearance

    /// Grouped by the *thing being configured*, not by the kind of control.
    ///
    /// The six tabs before this were General, Reading, Skills, Background,
    /// Accounts and Shortcuts, and the split ran along the wrong seam. A Claude
    /// account's config directory was under Accounts while the permission flag
    /// that decides what that account may do was under General; the tenancy
    /// fence and the spend cap — both facts about running a crew — were filed
    /// beside an appearance picker; and the reading measure and the wallpaper,
    /// which are the same decision about how the window looks, were two tabs
    /// apart.
    ///
    /// Five now, each answering one question: who can run, what a crew is
    /// allowed to do, how it looks, what the agents know, and which keys do
    /// what.
    var body: some View {
        TabView {
            AccountSettings()
                .tabItem { Label("Accounts", systemImage: "person.2") }

            CrewSettings()
                .tabItem { Label("Crew & Safety", systemImage: "lock.shield") }

            AppearanceSettings(store: background, appearance: $appearance)
                .tabItem { Label("Appearance", systemImage: "paintpalette") }

            SkillSettings()
                .tabItem { Label("Skills", systemImage: "wand.and.stars") }

            ShortcutSettings()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 640)
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

    var body: some View {
        TabView {
            ReadingSettings(appearance: $appearance)
                .tabItem { Label("Text", systemImage: "textformat.size") }
            BackgroundSettings(store: store)
                .tabItem { Label("Background", systemImage: "photo") }
        }
        .padding(.top, Theme.s4)
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
                .font(.system(size: 11))
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
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 440)
        .onAppear { store.reload() }
        .sheet(item: $editing) { skill in
            SkillEditor(skill: skill, store: store)
        }
    }

    private var empty: some View {
        Text("No shared skills yet.")
            .font(.system(size: 12))
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
                Text(skill.name).font(.system(size: 12.5))
                Text(skill.summary.isEmpty ? "/\(skill.slug)" : skill.summary)
                    .font(.system(size: 11))
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
            Text("Edit Skill").font(.system(size: 14, weight: .semibold))

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
                    .foregroundStyle(.quaternary)
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
                    .font(.system(size: 11))
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
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Tenancy")
            }

            Section {
                TextField("Monthly cap", value: $monthlyCap,
                          format: .currency(code: "USD"))
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
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Spend · Claude Work")
            }
        }
        .formStyle(.grouped)
        .frame(height: 560)
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
                        .font(.system(size: 11))
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
        .frame(height: 440)
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
    private static let keyCap = Font.system(size: 12, weight: .medium)

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
        .frame(height: 560)
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
        .frame(height: 560)
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
                        .font(.system(size: 17, weight: .medium))
                    RoundedRectangle(cornerRadius: Theme.cornerCard * 2)
                        .fill(Theme.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.cornerCard * 2)
                                .strokeBorder(Theme.rule, lineWidth: 1))
                        .frame(width: 300, height: 52)
                        .overlay(alignment: .leading) {
                            Text("Message Personal…")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .padding(.leading, Theme.s5)
                                .padding(.bottom, Theme.s6)
                        }
                }
            }
            .frame(height: 232)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.rule, lineWidth: 1))

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
                .font(.system(size: 11))
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
                        .font(.system(size: 13, weight: .semibold))
                    Text(store.items.isEmpty
                         ? "Copied into Honeycode, so the originals can move or go"
                         : "\(store.items.count) image\(store.items.count == 1 ? "" : "s")")
                        .font(.system(size: 11))
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
                            .font(.system(size: 11, weight: .semibold))
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
                .font(.system(size: 11))
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
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
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
                    .font(.system(size: 11.5))
                    .focused($focused)
                    .onSubmit { onRename(draft); renaming = false }
                    .onExitCommand { renaming = false }
            } else {
                Text(item.name)
                    .font(.system(size: 11.5))
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
