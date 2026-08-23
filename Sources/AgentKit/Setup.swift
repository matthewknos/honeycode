import Foundation

// MARK: - The parts that can be switched off

/// A piece of Honeycode somebody might not want.
///
/// The app grew by adding surfaces — a branch on the header chip, an identity
/// switcher in the sidebar footer, a browser in the workbench, a crew, a mic —
/// and every one of them was written as though everybody had the tool behind
/// it. On the machine this was built on that is true. On a Mac with no `az`,
/// no `gh` and one Claude subscription, most of the chrome is either dead or
/// asking about something that isn't there.
///
/// So each of them is a switch. What a switch does *not* do is hide a feature
/// halfway: turning one off removes its controls, and where a control is the
/// only route to a thing, the thing goes too. A greyed-out button that can
/// never be pressed is worse than no button, because it still has to be read.
///
/// The set is deliberately small. These are the things that depend on
/// something outside the app — a tool, a subscription, a permission — plus the
/// two modes that are whole halves of the sidebar. Everything else is a
/// preference, and preferences live in Settings.
enum Feature: String, CaseIterable, Identifiable, Sendable {
    /// The branch on the folder chip, and the route from an edit to a commit.
    case git
    /// Which GitHub identity you push as, and pull requests.
    case gitHub
    /// Which Azure tenant you're in, and the project chip.
    case azure
    /// Several agents on one message: the Crew half of the sidebar, the Team
    /// control in a header bar, the Run tab.
    case crew
    /// Agents that run on their own — the third half of the sidebar.
    case agents
    /// The workbench's Preview tab: a page, a dev server, a rendered artifact.
    case preview
    /// The mic in the composer.
    case dictation
    /// A banner when a turn finishes in a session you aren't looking at.
    case notifications
    /// The animated background, and anything else that redraws when nothing
    /// has happened.
    case motion

    var id: String { rawValue }

    /// Which part of the app it belongs to — the two headings in setup and in
    /// Settings ▸ Features.
    enum Group: String, CaseIterable, Identifiable, Sendable {
        /// Something else on this Mac has to be installed and signed in.
        case tools
        /// Nothing outside the app is involved; it is a surface you either want
        /// on screen or don't.
        case window

        var id: String { rawValue }

        var title: String {
            switch self {
            case .tools:  return "Your other tools"
            case .window: return "In the window"
            }
        }
    }

    var group: Group {
        switch self {
        case .git, .gitHub, .azure: return .tools
        case .crew, .agents, .preview, .dictation, .notifications, .motion:
            return .window
        }
    }

    var title: String {
        switch self {
        case .git:           return "Git"
        case .gitHub:        return "GitHub"
        case .azure:         return "Azure"
        case .crew:          return "Crew"
        case .agents:        return "Agents"
        case .preview:       return "Preview"
        case .dictation:     return "Dictation"
        case .notifications: return "Notifications"
        case .motion:        return "Motion"
        }
    }

    /// One line, in the voice the rest of the app uses for a footer: what it
    /// puts on screen, not what the technology is.
    var blurb: String {
        switch self {
        case .git:
            return "The branch on each session's folder chip, and the route from "
                 + "what an agent edited to a commit."
        case .gitHub:
            return "Which account you push as, at the foot of the sidebar, and "
                 + "opening a pull request from the Changes tab."
        case .azure:
            return "Which tenant you're signed in to, and a link to the resource "
                 + "group a session deploys to."
        case .crew:
            return "Name several accounts in one message and the first one plans "
                 + "the work. Adds the Crew half of the sidebar and the Run tab."
        case .agents:
            return "Saved prompts that run on a schedule or when a file changes, "
                 + "while Honeycode is open."
        case .preview:
            return "A browser in the workbench for a page, a dev server or "
                 + "whatever an agent just drew."
        case .dictation:
            return "Speak into the composer. Asks for the microphone the first "
                 + "time you press it, and transcribes on-device."
        case .notifications:
            return "A banner when a turn finishes in a session you aren't looking "
                 + "at. Never for the one in front of you."
        case .motion:
            return "The animated background. Starts off on a Mac with integrated "
                 + "graphics, where a surface redrawing behind the window costs "
                 + "more than it gives."
        }
    }

    /// The tool this feature drives, and the one command that installs it.
    /// Nil for the features that are nothing but the app itself.
    var requirement: (tool: String, install: String)? {
        switch self {
        case .git:    return ("git", "xcode-select --install")
        case .gitHub: return ("gh", "brew install gh")
        case .azure:  return ("az", "brew install azure-cli")
        default:      return nil
        }
    }

    /// Whether that tool is on this Mac.
    ///
    /// Looked for in the same absolute places everything else here looks — an
    /// app launched from Finder has launchd's `PATH` and would otherwise
    /// report Homebrew's entire contents missing. Cheap: `Shell.locate`
    /// remembers what it found.
    var isAvailable: Bool {
        switch self {
        case .git:    return Git.binary != nil
        case .gitHub: return GitHubAuth.isInstalled
        case .azure:  return AzureAuth.isInstalled
        default:      return true
        }
    }

    /// What a fresh install starts with.
    ///
    /// On for anything already possible, off for anything that isn't — a Mac
    /// with no `az` should not open with an Azure row saying `az` isn't
    /// installed, because nobody asked it about Azure.
    ///
    /// Notifications are an exception and are off until asked for. Switching
    /// them on is what triggers the system's permission prompt, and a prompt
    /// that arrives in the first four seconds of an app's life — before there
    /// is anything to be notified about — is the one people deny out of hand.
    ///
    /// Motion is the other one, and the question it asks is about the Mac
    /// rather than about what is installed. `isAvailable` would say yes: there
    /// is no tool to look for, and an animation is always *possible*. What it
    /// isn't, on integrated graphics, is free.
    var initialValue: Bool {
        switch self {
        case .notifications: return false
        case .motion:        return Machine.hasFastGraphics
        default:             return isAvailable
        }
    }
}

/// Which features are on.
///
/// A plain read of one boolean per feature, because these are consulted from
/// `body` — several of them on every redraw of a header bar. Nothing here
/// stats a file or launches a process; the detection that decides the *initial*
/// answer happens once, in `Setup.prepare`.
enum Features {

    static func isOn(_ feature: Feature) -> Bool {
        // Unset means an install that predates the switches, where everything
        // was on and should stay on. A fresh install never reaches this: its
        // values are written by `Setup.prepare` before the window is up.
        Setup.store.object(forKey: Setup.featureKey(feature)) as? Bool ?? true
    }

    static func set(_ feature: Feature, _ on: Bool) {
        Setup.store.set(on, forKey: Setup.featureKey(feature))
    }

    /// Every feature and its state, for the settings pane.
    static var all: [(Feature, Bool)] {
        Feature.allCases.map { ($0, isOn($0)) }
    }
}

// MARK: - Which subscriptions are in play

extension Account {

    /// Whether this account appears anywhere you choose one.
    ///
    /// Not the same question as whether it *works* — `Diagnostic.readiness`
    /// answers that, and a Kimi that is installed but signed out is still an
    /// account you have. This is the other one: whether you have it at all.
    /// Four subscriptions is this app's happy case and nobody's starting point.
    var isEnabled: Bool {
        Setup.store.object(forKey: Setup.accountKey(self)) as? Bool ?? true
    }

    static func setEnabled(_ on: Bool, for account: Account) {
        Setup.store.set(on, forKey: Setup.accountKey(account))
    }

    /// The accounts to *offer*. Every menu, picker, mention list and roster
    /// reads this.
    ///
    /// `allCases` still means every account that exists, and everything that
    /// enumerates *sessions* keeps reading that — a conversation on an account
    /// you have since switched off is still a conversation, and hiding it
    /// would be losing it rather than tidying it.
    static var enabled: [Account] { allCases.filter(\.isEnabled) }
}

// MARK: - First run

/// Whether this Mac has been through setup, and what a fresh one starts with.
///
/// The app had no first run. It had *Matthew's* first run, encoded as defaults:
/// two seeded sessions in `~/Workspace`, four accounts on the assumption you
/// pay for all four, a notification permission prompt four seconds after
/// launch, and an Azure chip on a machine with no Azure. Everything worked and
/// nothing said what it needed, so the first thing a new person saw was an app
/// confidently mid-conversation with tools they hadn't installed.
///
/// `SetupFlow` is the answer to that, and this is the state behind it.
enum Setup {

    /// The preferences these are written to.
    ///
    /// Settable for one reason: the suite in `Tests/Setup` exercises the real
    /// seeding logic, and the real logic writes to the domain the app you are
    /// using right now reads. A test that turned your own Azure switch off
    /// while proving that switches work would be a poor trade.
    nonisolated(unsafe) static var store: UserDefaults = Prefs.store

    private static let completedKey = "setup.completedAt"
    private static let versionKey = "setup.version"

    /// Bumped when the flow gains a step existing users should see. Nothing
    /// does that yet; it exists so that the day it does, the check is already
    /// the right shape.
    static let version = 1

    /// Somebody asked for the flow from a window that can't reach it.
    ///
    /// Settings is its own scene with its own view tree, and the flow is a
    /// sheet on the main window — there is no binding between the two. A
    /// notification is the whole of what needs to cross: "show it", with no
    /// payload and nothing to keep in sync.
    static let requested = Notification.Name("honeycode.setupRequested")

    /// Has this Mac been through it — either by running it, or by having been
    /// in use since before it existed.
    static var hasRun: Bool { store.object(forKey: completedKey) != nil }

    /// Should the window open on it.
    static var needsRun: Bool {
        !hasRun || store.integer(forKey: versionKey) < version
    }

    /// Run once, from `Workspace.init`, before anything is on screen.
    ///
    /// - Parameter returning: whether this Mac already holds a session roster.
    ///   That is the honest test for "has used this before": preferences alone
    ///   are not, because `Prefs.adopt` and `Migration.run` both write some,
    ///   and neither means a person has ever opened the window.
    ///
    /// A returning install is marked complete without being shown anything.
    /// The switches all default to on, so nothing about their app changes —
    /// which is the point. Setup is for the machine that has nothing, not a
    /// tour for the person who wrote it.
    static func prepare(returning: Bool) {
        guard needsRun else { return }
        guard !returning else { return complete() }
        seedDefaults()
    }

    /// Write the detected answer for anything not yet decided.
    ///
    /// Written rather than computed on read. Detection stats the filesystem,
    /// `Features.isOn` is called from `body`, and a default that re-derives
    /// itself is also a default that changes under you the moment you install
    /// Homebrew — so it is measured once, stored, and yours from then on.
    static func seedDefaults() {
        for feature in Feature.allCases where store.object(forKey: featureKey(feature)) == nil {
            store.set(feature.initialValue, forKey: featureKey(feature))
        }
        for account in Account.allCases where store.object(forKey: accountKey(account)) == nil {
            // An account whose CLI is nowhere on this Mac is one you don't
            // have. It can be switched on in setup regardless — the roster
            // shows it either way, with the command that installs it.
            store.set(Diagnostic.readiness(of: account).hasCLI, forKey: accountKey(account))
        }
    }

    /// Finished, or skipped — the same thing as far as this is concerned. What
    /// setup was for is a machine that has been asked; declining to answer is
    /// an answer, and being asked again next launch is how an app loses that
    /// argument.
    static func complete() {
        store.set(Date(), forKey: completedKey)
        store.set(version, forKey: versionKey)
    }

    /// Show it again from the top. The switches keep their current values —
    /// this is a way back into the flow, not a factory reset.
    static func rerun() {
        store.removeObject(forKey: completedKey)
        store.removeObject(forKey: versionKey)
    }

    /// Everything setup owns, back to unset. Only the test suite calls this;
    /// there is no button for it, because "start again" and "forget which
    /// subscriptions I have" are different requests and only the first one is
    /// ever meant.
    static func forgetEverything() {
        for feature in Feature.allCases { store.removeObject(forKey: featureKey(feature)) }
        for account in Account.allCases { store.removeObject(forKey: accountKey(account)) }
        rerun()
    }

    /// The two key spellings, in one place. `Features` and `Account.isEnabled`
    /// read them and this writes them, and a second literal of either is a
    /// switch that reads one key and sets another.
    static func featureKey(_ feature: Feature) -> String {
        "feature." + feature.rawValue
    }

    static func accountKey(_ account: Account) -> String {
        "account.enabled." + account.id
    }
}

// MARK: - Signing a Claude account in

extension Setup {

    /// A terminal running `claude` with this account's config directory set.
    ///
    /// The README has told people to type this by hand since the beginning:
    ///
    ///     CLAUDE_CONFIG_DIR="$HOME/.claude-personal" claude
    ///
    /// It is two facts — that the variable is the whole mechanism, and which
    /// directory this particular account means — and both of them are already
    /// known here. So setup hands them over rather than asking somebody to
    /// carry them to a terminal.
    ///
    /// A terminal rather than anything in-app because signing in is the CLI's
    /// business: it opens a browser, waits on OAuth, and writes credentials
    /// this app deliberately never touches. Same reasoning as
    /// `GitHubAuth.loginScript`.
    ///
    /// The directory is created first. `claude` started against a path that
    /// does not exist fails in a way that reads as an authentication problem
    /// rather than a missing folder — the exact confusion the Troubleshooting
    /// section of the README exists to undo.
    static func claudeLoginScript(for account: Account) -> URL? {
        guard let binary = Shell.locate("claude"),
              let directory = account.configDir else { return nil }
        return Shell.terminalScript(
            named: "honeycode-claude-login-\(account.id)",
            announcing: "Signing in \(account.title). "
                      + "Choose the subscription this account should use.",
            preamble: "mkdir -p \"\(directory)\"\n"
                    + "export CLAUDE_CONFIG_DIR=\"\(directory)\"\n",
            run: binary)
    }
}

// MARK: - Doing the next step

extension Setup {

    /// A terminal that installs this account's CLI.
    ///
    /// Setup used to print `npm install -g …` in a code box with a Copy link
    /// beside it, which is a fine way to hand somebody a command and a poor way
    /// to install something: on a fresh Mac three of the four rows start there,
    /// and each one costs finding a terminal, pasting, waiting, and coming back
    /// to a window that has no idea any of it happened. The app knows the
    /// command. It can run it.
    ///
    /// A login shell rather than an absolute `npm`, which makes this the one
    /// place here that doesn't hunt for a binary by path. Everything else does
    /// because a GUI app inherits launchd's `PATH` — but this script runs in
    /// *your* terminal, under your profile, so it finds the `npm` you would
    /// have used yourself, including one installed by nvm. `Shell.toolPath` is
    /// appended as a floor under that, for a profile that sets up nothing.
    ///
    /// Nil for an added account, which runs a command somebody else installed
    /// and has no line this could name without guessing.
    static func installScript(for account: Account) -> URL? {
        let command = AccountReadiness.installCommand(account)
        guard !command.isEmpty else { return nil }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return Shell.terminalScript(
            named: "honeycode-install-\(account.id)",
            announcing: "Installing \(account.agentName), for \(account.title).",
            preamble: "export PATH=\"$PATH:" + Shell.toolPath + "\"\n",
            run: shell, ["-lc", command])
    }

    /// A terminal this account can be signed in from.
    ///
    /// Two different jobs behind one button. A Claude account is signed in by
    /// running `claude` with `CLAUDE_CONFIG_DIR` pointed at it — see
    /// `claudeLoginScript`, which is the whole mechanism. Kimi and Copilot are
    /// signed in by running Kimi and Copilot, which is what the README has told
    /// people to do by hand and what this now does for them.
    ///
    /// Nil when there is nothing to run, which for an ACP agent means its
    /// binary isn't installed — a state whose button says Install instead.
    static func signInScript(for account: Account) -> URL? {
        switch account.protocolKind {
        case .claudeStreamJSON:
            return claudeLoginScript(for: account)
        case .acp(let agent):
            guard let binary = agent.binaryCandidates.first(where: {
                FileManager.default.isExecutableFile(atPath: $0)
            }) else { return nil }
            return Shell.terminalScript(
                named: "honeycode-signin-\(account.id)",
                announcing: "Sign in to \(account.title) here. It keeps its own "
                          + "login, and Honeycode uses whichever one it finds.",
                run: binary)
        }
    }
}
