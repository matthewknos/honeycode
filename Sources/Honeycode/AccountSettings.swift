import SwiftUI
import AppKit

/// The subscriptions this app didn't ship knowing about.
///
/// Four accounts are built in and cannot be edited here — they are wired to
/// credentials this app knows how to find, and a form that let you rename
/// "Claude Personal" would be offering to break the one thing about it that
/// works. Everything below the rule is yours.
///
/// A plain list and a sheet, not a wizard. Adding an agent is six facts, four
/// of which have a sensible answer already.
struct AccountSettings: View {

    @State private var accounts: [CustomAccount] = CustomAccounts.all
    @State private var editing: CustomAccount?
    @State private var confirming: CustomAccount?
    /// The catalogue, which is now the front door — see `AgentPicker`. The form
    /// is still behind it for anything the registry has never heard of.
    @State private var picking = false
    /// A local mirror of which accounts are switched on, so a toggle redraws.
    /// The value on disk is written the moment it changes — see `Account.isEnabled`.
    @State private var enabled: [String: Bool] = [:]

    /// Whether each of these can actually run, and the button that fixes the
    /// ones that can't. The same object setup uses — see `AccountReady` for why
    /// both places ask, and why they had better agree.
    @StateObject private var ready = AccountReady()

    private func on(_ account: Account) -> Bool {
        enabled[account.id] ?? account.isEnabled
    }

    /// Whether this account appears anywhere you choose one.
    ///
    /// Four accounts ship and nobody has four. Off is not "broken" and not
    /// "deleted": the sessions stay in the sidebar, the transcripts stay on
    /// disk, and the account stops being offered by every menu, mention list
    /// and roster in the app.
    private func inUse(_ account: Account) -> Binding<Bool> {
        Binding(get: { enabled[account.id] ?? account.isEnabled },
                set: { on in
                    enabled[account.id] = on
                    Account.setEnabled(on, for: account)
                })
    }

    /// Bound to preferences rather than to state: this is read at process
    /// launch by every Claude session, so the value on screen has to be the
    /// value on disk and not a copy of it.
    private func claudeDirectory(_ account: Account) -> Binding<String> {
        Binding(get: { Account.claudeDirectory(account) },
                set: { Account.setClaudeDirectory($0, for: account) })
    }

    /// Whether this account can run, and the one button that fixes it if not.
    ///
    /// The same rule setup uses: a row switched off keeps its state, so you can
    /// see what you would be switching on, and loses its button — installing
    /// something you have just said you don't pay for is not a step anybody is
    /// on.
    @ViewBuilder
    private func step(_ account: Account) -> some View {
        if let state = ready.state(of: account) {
            if on(account) {
                AccountStep(ready: ready, state: state)
            } else {
                AccountStatus(state: state, muted: true)
            }
        }
    }

    var body: some View {
        Form {
            Section {
                // The two Claude accounts are switched entirely by
                // `CLAUDE_CONFIG_DIR`, so where that points *is* the account.
                // Editable because the defaults encode one particular machine's
                // arrangement: the CLI puts a single account in `~/.claude`, and
                // `~/.claude-personal` exists only where somebody has two and
                // moved one. Pointed at a directory that has never existed, the
                // failure reads as a login problem rather than a settings one.
                ForEach([Account.personal, Account.work], id: \.self) { account in
                    HStack(spacing: Theme.s4) {
                        Toggle("", isOn: inUse(account))
                            .labelsHidden()
                            .controlSize(.mini)
                        Circle().fill(account.accent).frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: Theme.s1) {
                            Text(account.title)
                            Text(account.agentName)
                                .font(Theme.label)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        TextField("", text: claudeDirectory(account),
                                  prompt: Text("~/.claude"))
                            .font(Theme.monoSmall)
                            .frame(width: 190)
                        // Was a checkmark meaning "that directory exists",
                        // which is a weaker claim than it looked: `claude`
                        // makes the directory the first time it runs for any
                        // reason, so the tick appeared for a sign-in somebody
                        // had cancelled. This says whether there is a login in
                        // there, and offers the one click that puts one there.
                        step(account)
                    }
                }
                ForEach([Account.kimi, Account.copilot], id: \.self) { account in
                    HStack(spacing: Theme.s4) {
                        Toggle("", isOn: inUse(account))
                            .labelsHidden()
                            .controlSize(.mini)
                        Circle().fill(account.accent).frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: Theme.s1) {
                            Text(account.title)
                            Text(account.agentName)
                                .font(Theme.label)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        // These two said nothing about themselves at all — the
                        // right-hand side was the CLI's name, which is on the
                        // row above it now. A page for deciding which
                        // subscriptions you have was the one place that
                        // wouldn't say whether they worked.
                        step(account)
                    }
                }
            } header: {
                Text("Built in")
            } footer: {
                Text("The switch is whether you have the subscription at all — an "
                     + "account switched off stops being offered anywhere, and its "
                     + "existing conversations stay where they are. Claude accounts "
                     + "are then switched by CLAUDE_CONFIG_DIR: the directory is the "
                     + "account. With one Claude login, point both at ~/.claude or "
                     + "just use the one. Kimi and Copilot keep their own credentials, "
                     + "so all this can see is that they're installed — the button "
                     + "beside them opens a terminal to sign in with if they turn "
                     + "out not to be.")
                    .font(Theme.label)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                if accounts.isEmpty {
                    Text("Nothing added yet.")
                        .foregroundStyle(.tertiary)
                }
                ForEach(accounts) { account in
                    HStack(spacing: Theme.s4) {
                        Toggle("", isOn: inUse(.custom(account.id)))
                            .labelsHidden()
                            .controlSize(.mini)
                        Circle().fill(account.tint.colour).frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: Theme.s1) {
                            Text(account.title)
                            Text("@\(account.handle) · \(account.command)")
                                .font(Theme.label)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button("Edit") { editing = account }
                            .buttonStyle(.link)
                        Button("Remove") { confirming = account }
                            .buttonStyle(.link)
                    }
                }
            } header: {
                HStack {
                    Text("Added")
                    Spacer()
                    Button {
                        picking = true
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .buttonStyle(.link)
                    .help("\(AgentCatalogue.all.count) agents that speak the "
                          + "Agent Client Protocol, or a form for one that isn't "
                          + "in the list.")
                }
            } footer: {
                // Said here because it is the question this page raises and the
                // answer is not obvious. An API key is how a CLI authenticates;
                // it is not itself an agent.
                Text("Any command that speaks the Agent Client Protocol can be an "
                     + "account. An API key is stored in your Keychain and handed to "
                     + "that command as an environment variable — the CLI is what "
                     + "reads your files and runs your commands, and a key on its "
                     + "own can't do either.")
                    .font(Theme.label)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            enabled = Dictionary(uniqueKeysWithValues:
                Account.allCases.map { ($0.id, $0.isEnabled) })
        }
        .task { await ready.refresh() }
        // Installing a CLI and signing one in both happen in a terminal, which
        // means leaving this window and coming back. Re-reading on the way back
        // is what turns that into a tick appearing rather than a step you have
        // to know to repeat.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await ready.refresh() }
        }
        .sheet(isPresented: $picking) {
            AgentPicker(existing: accounts) { outcome in
                picking = false
                switch outcome {
                case .add(let account):
                    CustomAccounts.save(account)
                    Account.setEnabled(true, for: .custom(account.id))
                    accounts = CustomAccounts.all
                    enabled[account.id] = true
                    Task { await ready.refresh() }
                // A beat: two sheets on one view, and SwiftUI drops the second
                // if it is asked for while the first is still dismissing.
                case .freeform:
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        editing = CustomAccount(title: "", handle: "", command: "")
                    }
                case .cancel:
                    break
                }
            }
        }
        .sheet(item: $editing) { draft in
            AccountEditor(draft: draft, existing: accounts) { saved in
                if let saved { CustomAccounts.save(saved) }
                accounts = CustomAccounts.all
                editing = nil
                Task { await ready.refresh() }
            }
        }
        .alert("Remove \(confirming?.title ?? "")?", isPresented: .init(
            get: { confirming != nil },
            set: { if !$0 { confirming = nil } })) {
            Button("Remove", role: .destructive) {
                if let going = confirming { CustomAccounts.remove(going.id) }
                accounts = CustomAccounts.all
                confirming = nil
            }
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: {
            Text("Its API keys are deleted from your Keychain too. Conversations "
                 + "already on this account stay on disk but won't be able to run.")
        }
    }
}

// MARK: - The sheet

/// Six fields for an agent nobody has published.
///
/// Reachable from `AgentPicker` as **Something else…** rather than being the
/// front door, now that the catalogue answers the common case. Internal rather
/// than file-private because the setup flow opens it too — the moment somebody
/// is deciding which subscriptions they have is the moment they remember the
/// in-house one.
struct AccountEditor: View {
    @State var draft: CustomAccount
    let existing: [CustomAccount]
    let done: (CustomAccount?) -> Void

    /// Typed in, never read back out. A key already stored shows as stored
    /// rather than as itself — putting a live credential into a text field on
    /// screen is how one ends up in a screenshot.
    @State private var secrets: [String: String] = [:]
    @State private var newSecretName = ""
    @State private var argumentLine = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Name") {
                    TextField("Name", text: $draft.title, prompt: Text("Gemini CLI"))
                    TextField("Short name", text: $draft.shortTitle, prompt: Text("Gemini"))
                    HStack {
                        Text("@")
                            .foregroundStyle(.tertiary)
                        TextField("Handle", text: $draft.handle, prompt: Text("gemini"))
                    }
                    Picker("Colour", selection: $draft.tint) {
                        ForEach(CustomAccount.Tint.allCases, id: \.self) { tint in
                            Text(tint.title).tag(tint)
                        }
                    }
                }

                Section {
                    TextField("Command", text: $draft.command, prompt: Text("gemini"))
                    TextField("Arguments", text: $argumentLine, prompt: Text("--acp"))
                    Toggle("It's a Node program", isOn: $draft.isNode)
                    Picker("Speaks", selection: $draft.dialect) {
                        ForEach(ACPAgent.Dialect.allCases, id: \.self) { dialect in
                            Text(dialect.title).tag(dialect)
                        }
                    }
                    Picker("/usage reports", selection: $draft.usageReports) {
                        ForEach(ACPAgent.UsageKind.allCases, id: \.self) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                } header: {
                    Text("Command")
                } footer: {
                    Text("A bare name is looked for in ~/.local/bin, Homebrew and, for "
                         + "a Node program, your nvm versions. Anything with a slash in "
                         + "it is used as the path it is. Leave /usage on “doesn't "
                         + "report” unless you know the command exists — a slash "
                         + "command an agent doesn't know reaches the model as text "
                         + "and costs a request.")
                        .font(Theme.label)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section {
                    ForEach(draft.secretNames, id: \.self) { name in
                        HStack {
                            Text(name).font(Theme.monoSmall)
                            Spacer()
                            SecureField(Keychain.has(account: draft.id, key: name)
                                        ? "stored" : "not set",
                                        text: binding(for: name))
                                .frame(width: 200)
                            Button {
                                draft.secretNames.removeAll { $0 == name }
                                secrets[name] = nil
                            } label: {
                                Image(systemName: "xmark").font(.system(size: 9))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    HStack {
                        TextField("ANTHROPIC_API_KEY", text: $newSecretName)
                            .font(Theme.monoSmall)
                        Button("Add key") {
                            let name = newSecretName.trimmingCharacters(in: .whitespaces)
                            guard !name.isEmpty, !draft.secretNames.contains(name) else { return }
                            draft.secretNames.append(name)
                            newSecretName = ""
                        }
                        .disabled(newSecretName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("API keys")
                } footer: {
                    Text("Stored in your Keychain, not in preferences, and handed to the "
                         + "command as environment variables. Name them exactly as the "
                         + "CLI expects.")
                        .font(Theme.label)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)

            Divider().overlay(Theme.rule)

            HStack {
                if let objection {
                    Text(objection)
                        .font(Theme.label)
                        // `Theme.stateBad`, not `Color.red` — the pattern
                        // Theme's State section says was removed. Raw red is
                        // the same value in both appearances; this one is
                        // darkened for light mode, which matters most in the
                        // one place in a form where legibility does.
                        .foregroundStyle(Theme.stateBad)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Cancel") { done(nil) }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(objection != nil)
            }
            .padding(Theme.s5)
        }
        .frame(width: 560, height: 620)
        .onAppear {
            argumentLine = draft.arguments.joined(separator: " ")
            if draft.shortTitle.isEmpty { draft.shortTitle = draft.title }
        }
    }

    private var objection: String? {
        var candidate = draft
        candidate.arguments = Self.split(argumentLine)
        return CustomAccount.objection(to: candidate, existing: existing)
    }

    private func binding(for name: String) -> Binding<String> {
        Binding(get: { secrets[name] ?? "" }, set: { secrets[name] = $0 })
    }

    private func save() {
        var saving = draft
        saving.arguments = Self.split(argumentLine)
        if saving.shortTitle.trimmingCharacters(in: .whitespaces).isEmpty {
            saving.shortTitle = saving.title
        }
        saving.handle = saving.handle.lowercased()
        // Only what was actually typed. An untouched field means "leave what is
        // already there", which is the difference between editing a name and
        // wiping a credential you can't see.
        for (name, value) in secrets where !value.isEmpty {
            Keychain.write(account: saving.id, key: name, value: value)
        }
        // A key whose name was removed goes from the Keychain with it.
        for name in Set(draft.secretNames).subtracting(saving.secretNames) {
            Keychain.delete(account: saving.id, key: name)
        }
        done(saving)
    }

    /// Arguments as typed, split on spaces but honouring quotes — `--flag "a b"`
    /// is two arguments, and somebody who quoted meant it.
    static func split(_ line: String) -> [String] {
        var out: [String] = []
        var current = ""
        var quote: Character?
        for character in line {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == " " {
                if !current.isEmpty { out.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}
