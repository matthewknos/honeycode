import SwiftUI
import AppKit

/// The first run.
///
/// Everything this app does depends on something it did not install: an agent
/// CLI signed in to a subscription, `gh` holding a token, `az` holding a
/// tenant. It has always been able to *check* all of that — `tools/doctor.sh`
/// from a terminal, `Diagnostic.readiness` under the composer — and it has
/// never once asked. The first launch on a fresh Mac opened straight into two
/// conversations about folders that didn't exist, an Azure chip with no Azure
/// behind it, and a notification permission prompt four seconds in.
///
/// This is four questions, in the order they actually matter:
///
/// 1. **What is this.** One screen, because a person who just opened an
///    unfamiliar window is owed a sentence about what it is for.
/// 2. **Which subscriptions do you have.** The one question the app cannot
///    work out for itself — it can see which CLIs are installed, which is a
///    different thing from which you pay for — and the one that decides what
///    every menu in the app offers from then on.
/// 3. **What do you want on screen.** The switches from Settings ▸ Features,
///    asked once with their reasons attached.
/// 4. **What are the agents allowed to do.** Permissions, the tenancy fence
///    and the spend cap. These have real consequences and the app should not
///    be quietly choosing them for you.
///
/// Deliberately a sequence, which the rest of this app avoids — `AccountEditor`
/// says in its own comment that adding an account is a list and not a wizard,
/// and it is right, because that is one task with six fields. This is four
/// unrelated decisions, and the only thing that makes them one job is that
/// they all have to be made before anything works.
///
/// Nothing here is a commitment. Every switch on every step is also in
/// Settings, the flow can be left at any point, and leaving it counts as
/// having been asked — see `Setup.complete`.
struct SetupFlow: View {
    @ObservedObject var workspace: Workspace

    @State private var step = Step.welcome
    /// Captured on appear rather than read live: `Setup.complete` runs while
    /// this view is still on screen, and the last step needs to know which
    /// kind of run this was after that has happened.
    @State private var isFirstRun = false

    /// Which accounts can run, and the button that fixes the ones that can't.
    /// Shared with Settings ▸ Accounts — see `AccountReady`.
    @StateObject private var ready = AccountReady()
    /// Local mirrors of what is in preferences, so a toggle redraws.
    ///
    /// Written through immediately rather than gathered and applied at the
    /// end. Half of these have visible effects the moment they change — the
    /// sidebar loses a segment, the roster loses a row — and a flow whose
    /// answers only take effect when you reach the end is one you cannot check
    /// your answers in.
    @State private var accountsOn: [String: Bool] = [:]
    @State private var featuresOn: [Feature: Bool] = [:]

    @AppStorage("agent.skipPermissions") private var skipPermissions = true
    @AppStorage("tenancy.gateDelegation") private var gateDelegation = true
    @AppStorage("usage.monthlyCap") private var monthlyCap: Double = 500

    enum Step: Int, CaseIterable, Identifiable {
        case welcome, accounts, features, safety
        var id: Int { rawValue }

        var title: String {
            switch self {
            case .welcome:  return "Honeycode"
            case .accounts: return "Which subscriptions do you have?"
            case .features: return "What should be on screen?"
            case .safety:   return "What are they allowed to do?"
            }
        }

        var subtitle: String {
            switch self {
            case .welcome:
                return "Every coding subscription you pay for, in one window."
            case .accounts:
                return "Honeycode drives the agent CLIs you already have. It can see "
                     + "which are installed; only you know which you pay for."
            case .features:
                return "Each of these puts something in the window. Switch off what "
                     + "you don't use — it takes its controls with it."
            case .safety:
                return "Three rules that hold for every session and every crew run."
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.rule)

            ScrollView {
                content
                    .padding(.horizontal, Theme.s7)
                    .padding(.vertical, Theme.s6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)

            Divider().overlay(Theme.rule)
            footer
        }
        .frame(width: 620, height: 580)
        .background(Theme.canvas)
        .task {
            isFirstRun = !Setup.hasRun
            accountsOn = Dictionary(uniqueKeysWithValues:
                Account.allCases.map { ($0.id, $0.isEnabled) })
            featuresOn = Dictionary(uniqueKeysWithValues:
                Feature.allCases.map { ($0, Features.isOn($0)) })
            await ready.refresh()
        }
        // Installing a CLI and signing an account in both happen in a terminal,
        // which means leaving this window and coming back. Re-reading on the
        // way back is what turns that into a tick appearing rather than a step
        // you have to redo.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await ready.refresh() }
        }
    }

    // MARK: Chrome

    private var header: some View {
        HStack(alignment: .top, spacing: Theme.s5) {
            VStack(alignment: .leading, spacing: Theme.s2) {
                Text(step.title)
                    .font(Theme.display(step == .welcome ? 22 : 16))
                Text(step.subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.s5)
            dots
        }
        .padding(.horizontal, Theme.s7)
        .padding(.top, Theme.s6)
        .padding(.bottom, Theme.s5)
    }

    /// Four dots, not a numbered progress bar. The only thing worth saying
    /// here is how much is left, and four of anything is little enough that
    /// the shape says it.
    private var dots: some View {
        HStack(spacing: Theme.s3) {
            ForEach(Step.allCases) { candidate in
                Circle()
                    .fill(candidate == step ? AnyShapeStyle(.secondary)
                                            : AnyShapeStyle(.quaternary))
                    .frame(width: 5, height: 5)
            }
        }
        .padding(.top, Theme.s2)
    }

    private var footer: some View {
        HStack(spacing: Theme.s4) {
            // Only while there is something still to answer. On the last step
            // the button beside it does the same thing and says it better.
            if step != .safety {
                Button("Skip setup") { finish(openingSession: false) }
                    .buttonStyle(.link)
                    .help("Everything here is also in Settings.")
            }
            Spacer()
            if step != .welcome {
                Button("Back") {
                    withAnimation(Motion.reveal) {
                        step = Step(rawValue: step.rawValue - 1) ?? .welcome
                    }
                }
            }
            Button(step == .safety ? "Start" : "Continue") {
                guard step != .safety else { return finish(openingSession: isFirstRun) }
                withAnimation(Motion.reveal) {
                    step = Step(rawValue: step.rawValue + 1) ?? .safety
                }
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(Theme.s5)
    }

    /// Mark it done, close, and — on a genuine first run — ask the one
    /// question this flow deliberately doesn't: which folder.
    private func finish(openingSession: Bool) {
        Setup.complete()
        workspace.showingSetup = false
        guard openingSession else { return }
        // A beat, because these are two sheets on the same view and SwiftUI
        // will drop the second if it is asked for while the first is still
        // dismissing. The delay is the dismissal animation, not a guess.
        let account = Account.enabled.first ?? .personal
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            workspace.requestNewSession(account)
        }
    }

    // MARK: The steps

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:  welcome
        case .accounts: accounts
        case .features: features
        case .safety:   safety
        }
    }

    // MARK: Welcome

    private var welcome: some View {
        VStack(alignment: .leading, spacing: Theme.s6) {
            point("person.2", "Four subscriptions, one window",
                  "Claude, Kimi and Copilot each keep their own login and their "
                  + "own conversation. Honeycode drives the CLIs you already "
                  + "installed — it never talks to a model itself.")

            point("arrow.triangle.branch", "Or all of them at once",
                  "Name several accounts in one message and the first one named "
                  + "leads: it plans the work, hands out the pieces, waits, and "
                  + "assembles what comes back.")

            point("lock.shield", "Enterprise work stays enterprise",
                  "Before a piece of work leaves a work session for a personal "
                  + "subscription it is checked on the work account, and agents "
                  + "off the tenancy get an empty folder rather than your project.")

            Text("This takes about a minute. Every answer is also in Settings, "
                 + "so nothing here is decided for good.")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Theme.s2)
        }
    }

    private func point(_ symbol: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: Theme.s5) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .center)
            VStack(alignment: .leading, spacing: Theme.s2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(body)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Accounts

    private var accounts: some View {
        VStack(alignment: .leading, spacing: Theme.s5) {
            // A Mac with none of the CLIs installed seeds every switch off —
            // see `Setup.seedDefaults`, which is right not to assume you pay
            // for something it cannot see. What it leaves behind is this step
            // opening on four dimmed rows and no obvious move, which was the
            // one place the flow could still strand somebody.
            if !ready.readiness.isEmpty,
               ready.readiness.allSatisfy({ !isOn($0.account) }) {
                Text("Nothing is switched on yet. Switch on the subscriptions you "
                     + "pay for and Honeycode will install and sign in whatever "
                     + "they need.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.stateHeld)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(ready.readiness) { state in
                accountRow(state)
                if state.id != ready.readiness.last?.id {
                    Divider().overlay(Theme.rule)
                }
            }

            Text("A button here opens a terminal, because a terminal is where "
                 + "these CLIs install and sign in — this window watches for it to "
                 + "finish. Switching an account off hides it from every menu, "
                 + "mention list and roster; it doesn't delete anything, and "
                 + "conversations you already have on it stay in the sidebar. Add "
                 + "a CLI of your own later in Settings ▸ Accounts.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Theme.s2)
        }
    }

    private func accountRow(_ state: AccountReadiness) -> some View {
        let account = state.account
        let on = isOn(account)
        return VStack(alignment: .leading, spacing: Theme.s4) {
            HStack(spacing: Theme.s4) {
                Toggle("", isOn: accountBinding(account))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)

                Circle().fill(account.accent).frame(width: 7, height: 7)

                VStack(alignment: .leading, spacing: Theme.s1) {
                    Text(account.title).font(.system(size: 13))
                    Text("@\(AgentMention.handle(account)) · \(account.agentName)")
                        .font(Theme.label)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: Theme.s4)
                // A row switched off keeps its state, so you can see what you
                // would be switching on, and loses its button. Installing
                // something you have just said you don't pay for is not a step
                // anybody is on.
                if on {
                    AccountStep(ready: ready, state: state)
                } else {
                    AccountStatus(state: state, muted: true)
                }
            }

            // The directory *is* the Claude account — see `Account.configDir`.
            //
            // Only at the step where it is the question. Before the CLI is
            // installed it is a field about a program that isn't there, and
            // once the account is signed in it is a working detail — and a
            // form that shows you its working details is one you have to read
            // before you can trust it. Settings ▸ Accounts keeps it on screen
            // permanently, which is the right place for a thing you go looking
            // for rather than one you are being walked past.
            if on, state.next == .signIn {
                claudeDirectory(account)
                    .padding(.leading, Theme.s8)
            }
        }
        .opacity(on ? 1 : 0.55)
    }

    /// Where this Claude account's login lives, and the one-click answer to the
    /// question that raises.
    ///
    /// `CLAUDE_CONFIG_DIR` is the whole of Claude account switching, and the
    /// two defaults assume two logins: Enterprise in `~/.claude`, where the CLI
    /// puts one, and Personal in `~/.claude-personal`, which exists only on a
    /// machine that has two and moved one out of the way. Most people have one.
    /// The route for them was to read the README, work out that the second
    /// account *is* a directory, and type the first one's path in by hand — or,
    /// far more often, to press Sign in and put the same subscription in twice
    /// under two names.
    @ViewBuilder
    private func claudeDirectory(_ account: Account) -> some View {
        HStack(spacing: Theme.s4) {
            Text("Login directory")
                .font(Theme.label)
                .foregroundStyle(.tertiary)
            TextField("", text: Binding(
                get: { Account.claudeDirectory(account) },
                set: { Account.setClaudeDirectory($0, for: account) }),
                      prompt: Text("~/.claude"))
                .font(Theme.monoSmall)
                .frame(width: 200)
            if let other = signedInSibling(of: account) {
                Button("Use \(other.shortTitle)'s") {
                    Account.setClaudeDirectory(Account.claudeDirectory(other),
                                               for: account)
                    Task { await ready.refresh() }
                }
                .buttonStyle(.link)
                .help("One Claude subscription, both accounts pointed at it. They "
                      + "then share a login and a history, which is what having "
                      + "one subscription means.")
            }
            Spacer(minLength: 0)
        }
    }

    /// The other Claude account, when it is signed in and this one is not
    /// already pointed at the same place.
    private func signedInSibling(of account: Account) -> Account? {
        let other: Account = account == .personal ? .work : .personal
        guard ready.state(of: other)?.next == .ready,
              Account.claudeDirectory(other) != Account.claudeDirectory(account)
        else { return nil }
        return other
    }

    // MARK: Features

    private var features: some View {
        VStack(alignment: .leading, spacing: Theme.s6) {
            ForEach(Feature.Group.allCases) { group in
                VStack(alignment: .leading, spacing: Theme.s5) {
                    Text(group.title)
                        .font(Theme.label)
                        .foregroundStyle(.tertiary)
                    ForEach(Feature.allCases.filter { $0.group == group }) { feature in
                        featureRow(feature)
                    }
                }
            }
        }
    }

    private func featureRow(_ feature: Feature) -> some View {
        HStack(alignment: .top, spacing: Theme.s4) {
            Toggle("", isOn: featureBinding(feature))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .padding(.top, Theme.s1)

            VStack(alignment: .leading, spacing: Theme.s1) {
                HStack(spacing: Theme.s3) {
                    Text(feature.title).font(.system(size: 12.5))
                    // Said on the row rather than hidden behind the switch.
                    // Turning a feature on without its tool is allowed — you
                    // may be about to install it — and the app should say what
                    // that would take rather than refuse.
                    if let requirement = feature.requirement, !feature.isAvailable {
                        Text("needs `\(requirement.tool)` · \(requirement.install)")
                            .font(Theme.monoSmall)
                            .foregroundStyle(Theme.stateHeld)
                    }
                }
                Text(feature.blurb)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Safety

    private var safety: some View {
        VStack(alignment: .leading, spacing: Theme.s6) {
            rule(isOn: $skipPermissions, title: "Let agents work without asking",
                 on: "Files are edited and commands run without a prompt for each "
                   + "one. This is what makes an unattended run possible, and it "
                   + "is exactly as powerful as it sounds.",
                 off: "Claude can read and search, but every write is refused — "
                    + "there is no middle setting over its headless protocol.")

            // Only where it can apply. The fence is about handing enterprise
            // work to an off-tenant subscription, which needs both halves to
            // exist; on a Mac with one Claude account it is a paragraph about
            // a situation that cannot arise.
            if Account.work.isEnabled && Account.enabled.count > 1 {
                rule(isOn: $gateDelegation, title: "Keep Enterprise work inside Enterprise",
                     on: "Work handed from an Enterprise session to Kimi, Copilot or "
                       + "your personal Claude is checked on the Enterprise account "
                       + "first, and those agents work in an empty folder rather than "
                       + "in your project.",
                     off: "Enterprise sessions hand work to the other accounts "
                        + "unchecked, in this project's directory.")

                VStack(alignment: .leading, spacing: Theme.s3) {
                    HStack {
                        Text("Monthly cap").font(.system(size: 12.5))
                        Spacer()
                        TextField("", value: $monthlyCap, format: .currency(code: "USD"))
                            .frame(width: 110)
                    }
                    Text("What the Enterprise seat is allowed to spend through this "
                         + "app in a month. Honeycode counts only its own turns, so "
                         + "on a seat you also use from a terminal the figure reads "
                         + "low — the real one goes in Settings ▸ Crew & Safety.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider().overlay(Theme.rule)

            VStack(alignment: .leading, spacing: Theme.s2) {
                Text("Where your work lives")
                    .font(.system(size: 12.5, weight: .semibold))
                Text("Sessions, transcripts and anything an agent draws are kept in "
                     + "~/Library/Application Support/Honeycode. Agent logins stay "
                     + "wherever each CLI keeps them and are never copied. Nothing "
                     + "leaves this Mac except through the agent CLIs themselves.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A switch whose explanation changes with it, rather than one sentence
    /// describing the on position and leaving you to invert it yourself.
    private func rule(isOn: Binding<Bool>, title: String,
                      on: String, off: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            Toggle(title, isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.system(size: 12.5))
            Text(isOn.wrappedValue ? on : off)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Bindings

    private func isOn(_ account: Account) -> Bool {
        accountsOn[account.id] ?? account.isEnabled
    }

    private func accountBinding(_ account: Account) -> Binding<Bool> {
        Binding(get: { isOn(account) },
                set: { on in
                    accountsOn[account.id] = on
                    Account.setEnabled(on, for: account)
                })
    }

    private func featureBinding(_ feature: Feature) -> Binding<Bool> {
        Binding(get: { featuresOn[feature] ?? Features.isOn(feature) },
                set: { on in
                    featuresOn[feature] = on
                    Features.set(feature, on)
                    // The system's permission prompt, at the moment somebody
                    // asked for notifications rather than four seconds into
                    // the first launch. Asking twice is harmless — after the
                    // first answer the system returns it without a dialog.
                    if feature == .notifications && on { Notifier.configure() }
                })
    }
}
