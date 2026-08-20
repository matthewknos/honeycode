import SwiftUI

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

    /// Bound to preferences rather than to state: this is read at process
    /// launch by every Claude session, so the value on screen has to be the
    /// value on disk and not a copy of it.
    private func claudeDirectory(_ account: Account) -> Binding<String> {
        Binding(get: { Account.claudeDirectory(account) },
                set: { Account.setClaudeDirectory($0, for: account) })
    }

    private func exists(_ account: Account) -> Bool {
        FileManager.default.fileExists(atPath: Account.claudeDirectory(account))
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
                            .frame(width: 210)
                        Image(systemName: exists(account) ? "checkmark.circle"
                                                          : "exclamationmark.triangle")
                            .font(.system(size: 11))
                            .foregroundStyle(exists(account) ? AnyShapeStyle(.tertiary)
                                                             : AnyShapeStyle(Color.orange))
                            .help(exists(account) ? "Found" : "No such directory yet")
                    }
                }
                ForEach([Account.kimi, Account.copilot], id: \.self) { account in
                    HStack(spacing: Theme.s4) {
                        Circle().fill(account.accent).frame(width: 7, height: 7)
                        Text(account.title)
                        Spacer()
                        Text(account.agentName)
                            .foregroundStyle(.tertiary)
                    }
                }
            } header: {
                Text("Built in")
            } footer: {
                Text("Claude accounts are switched by CLAUDE_CONFIG_DIR — the directory "
                     + "is the account. With one Claude login, point both at ~/.claude "
                     + "or just use the one. Kimi and Copilot keep their own credentials "
                     + "and are signed in through their own CLIs.")
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
                        editing = CustomAccount(title: "", handle: "", command: "")
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .buttonStyle(.link)
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
        .sheet(item: $editing) { draft in
            AccountEditor(draft: draft, existing: accounts) { saved in
                if let saved { CustomAccounts.save(saved) }
                accounts = CustomAccounts.all
                editing = nil
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

private struct AccountEditor: View {
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

            Divider()

            HStack {
                if let objection {
                    Text(objection)
                        .font(Theme.label)
                        .foregroundStyle(Color.red.opacity(0.9))
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
