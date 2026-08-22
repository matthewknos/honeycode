import SwiftUI
import AppKit

/// Which accounts can actually run, and the one button that fixes the ones
/// that can't.
///
/// Two places ask this. The accounts step of `SetupFlow` asks it once, on a
/// machine that has just been unpacked; Settings ▸ Accounts asks it every time
/// afterwards, which is where somebody lands who skipped setup, or bought a
/// second subscription in March. They used to answer it differently and both
/// incompletely: setup could see readiness and offered a command to copy out of
/// a code box, and Settings offered a checkmark meaning "that directory
/// exists" — and, for Kimi and Copilot, nothing at all.
///
/// So this is the answer once, with the doing attached. The state lives here
/// rather than in either view because the doing takes a minute and happens in
/// another application, which has to be watched for; that is a thing with a
/// lifetime, and a `@State` in a step you can page away from is not where it
/// belongs.
@MainActor
final class AccountReady: ObservableObject {

    /// Every account that exists, switched-off ones included — both callers
    /// draw rows you can switch *on*, and you cannot decide about a row you
    /// cannot see.
    @Published private(set) var readiness: [AccountReadiness] = []

    /// An Install or a Sign in that has been started and not yet seen through.
    struct Pending: Equatable {
        /// What the row was showing when its button was pressed. The wait ends
        /// when the step *changes*, not when it reaches any particular value:
        /// an install that lands on "now sign in" has plainly worked, and a
        /// watch for `.ready` would sit straight through it.
        let step: AccountReadiness.Step
        /// When, so a wait can be given up on. Per row rather than per loop,
        /// because two rows started four minutes apart are two different waits.
        let at: Date
    }

    /// The rows currently waiting on a terminal.
    ///
    /// The remembering is the point. Until now this window sat behind the
    /// terminal with nothing to say and then showed the same unchanged row
    /// back, so the only way to tell an install in progress from one that never
    /// started was to press the button a second time.
    @Published private(set) var started: [String: Pending] = [:]

    /// One poll loop at a time, however many rows are waiting on it.
    private var watching = false

    /// How long a row waits before deciding it was ignored. Long enough for a
    /// slow `npm install` on a slow connection, short enough that a terminal
    /// somebody closed without answering doesn't leave a spinner up for the
    /// rest of the afternoon.
    private static let patience: TimeInterval = 300

    func refresh() async {
        readiness = await Task.detached(priority: .utility) {
            Diagnostic.readinessOfAll()
        }.value
    }

    func state(of account: Account) -> AccountReadiness? {
        readiness.first { $0.id == account.id }
    }

    /// Open the terminal, and start watching for what it does.
    func start(_ state: AccountReadiness, _ script: (Account) -> URL?) {
        guard let file = script(state.account) else { return }
        started[state.id] = Pending(step: state.next, at: Date())
        NSWorkspace.shared.open(file)
        Task { await watch() }
    }

    /// Give up on a row by hand.
    ///
    /// There has to be one. An install can fail in the terminal — no `npm`, no
    /// network, a typo in a password — and when it does, the row has nothing
    /// new to see and would otherwise spin out its full patience before
    /// offering its button back. The failure is on screen in the other window;
    /// this is how you say so.
    func stopWaiting(_ state: AccountReadiness) {
        started[state.id] = nil
    }

    /// Re-read until every started row has moved, or given up on.
    ///
    /// Both callers already re-read when the app comes forward, which catches
    /// the shape this was written for — go away, install, come back — and
    /// misses the one people actually do, which is to watch. An `npm install`
    /// takes the better part of a minute, the window is visible for most of it,
    /// and without this it is the one rectangle on screen where nothing is
    /// happening.
    ///
    /// Two seconds, because the check stats a dozen paths and there is nothing
    /// to be gained from noticing sooner than a person can look up.
    private func watch() async {
        guard !watching else { return }
        watching = true
        defer { watching = false }

        while !started.isEmpty {
            try? await Task.sleep(for: .seconds(2))
            await refresh()
            let now = Date()
            for state in readiness {
                guard let pending = started[state.id] else { continue }
                if pending.step != state.next
                    || now.timeIntervalSince(pending.at) > Self.patience {
                    started[state.id] = nil
                }
            }
        }
    }
}

// MARK: - The one thing to do

/// What to do about this account, as a control rather than as a command to
/// carry somewhere else.
///
/// Every state here used to be something to read. Not installed was a code box
/// with a Copy link beside it; not signed in was a link that only the two
/// Claude accounts had; and installed-but-unverifiable was a green tick reading
/// "ready", which is the one that actually cost people an afternoon. Three of
/// the four rows on a fresh Mac open in a state whose fix is a single command
/// the app already knows — so it runs it.
///
/// Exactly one control, whatever the state. A row offering both a command to
/// copy and a button that runs it is a row asking somebody to decide how they
/// would like to install something, which is not a decision anyone wanted to be
/// handed.
struct AccountStep: View {
    @ObservedObject var ready: AccountReady
    let state: AccountReadiness

    var body: some View {
        if let pending = ready.started[state.id], pending.step == state.next {
            waiting
        } else {
            switch state.next {
            case .install:
                button("Install") { Setup.installScript(for: $0) }
                    .help(state.remedy ?? "")

            case .signIn:
                button("Sign in") { Setup.signInScript(for: $0) }
                    .help("Opens a terminal running \(state.account.agentName) "
                          + "against this account's own login directory.")

            case .unknownLogin:
                // A word and an offer. The word is the whole of what this app
                // can honestly say — the CLI is on the machine — because
                // nothing here can see whether an ACP agent is signed in. So it
                // claims no fault, carries no tick, and still doesn't make you
                // go and read a README to find out how to fix one.
                HStack(spacing: Theme.s4) {
                    AccountStatus(state: state)
                    Button("Sign in…") {
                        ready.start(state) { Setup.signInScript(for: $0) }
                    }
                    .buttonStyle(.link)
                    .help("\(state.account.title) keeps its own login, where this "
                          + "app can't see it. If it turns out not to be signed "
                          + "in, this is where.")
                }

            case .get:
                // Nothing this app can run. An added agent that ships its own
                // binary gets a link to where it lives; an `npx` one that
                // reports itself missing has nothing wrong with it at all —
                // the machine has no Node — and its tooltip says so.
                if let site = state.account.custom?.site,
                   let url = URL(string: site) {
                    HStack(spacing: Theme.s4) {
                        AccountStatus(state: state)
                        Button("Get…") { NSWorkspace.shared.open(url) }
                            .buttonStyle(.link)
                            .help(state.remedy ?? "")
                    }
                } else {
                    AccountStatus(state: state)
                        .help(state.remedy ?? "")
                }

            case .ready, .configure:
                AccountStatus(state: state)
            }
        }
    }

    private var waiting: some View {
        HStack(spacing: Theme.s3) {
            ProgressView()
                .controlSize(.small)
            Text("waiting on the terminal")
                .font(Theme.label)
                .foregroundStyle(.tertiary)
            Button {
                ready.stopWaiting(state)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Stop waiting and put the button back. Use it if the install "
                  + "failed, or you closed the terminal without finishing.")
        }
    }

    private func button(_ title: String,
                        _ script: @escaping (Account) -> URL?) -> some View {
        Button(title) { ready.start(state, script) }
            .buttonStyle(.bordered)
            .controlSize(.small)
    }
}

/// One short phrase, and a mark beside it where the app has earned one. Not a
/// sentence: this sits in a row beside three others, and a paragraph per
/// account is a wall rather than a status.
struct AccountStatus: View {
    let state: AccountReadiness

    /// Whether an unresolved state here is a problem or just a fact.
    ///
    /// A row switched off is a fact. Nobody asked for that account, so "not
    /// installed" describes the machine rather than complaining about it — and
    /// a column of amber warnings about subscriptions somebody has never had is
    /// the exact noise `Feature.initialValue` was written to avoid. So the mark
    /// goes and the words stay.
    var muted = false

    var body: some View {
        HStack(spacing: Theme.s2) {
            if let mark {
                Image(systemName: mark.symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(mark.tint)
            }
            // `.secondary` either way. Muting is the mark going, not the
            // text fading: the caller that dims a switched-off row already
            // multiplies this by 0.55, and a `.tertiary` under that lands at
            // about 14% — the same compounded-alpha hole that put `.quaternary`
            // on the review list.
            Text(state.summary)
                .font(Theme.label)
                .foregroundStyle(.secondary)
        }
    }

    /// Nil wherever this app is not in a position to have an opinion.
    ///
    /// `unknownLogin` is the one that matters, and it used to carry the same
    /// green tick as `ready` — the app claiming to have checked a thing it had
    /// just finished explaining it cannot check. The word on its own is the
    /// whole of what is known: the CLI is there.
    private var mark: (symbol: String, tint: AnyShapeStyle)? {
        guard !muted else { return nil }
        switch state.next {
        case .ready:
            return ("checkmark.circle.fill", AnyShapeStyle(Theme.stateDone))
        case .unknownLogin:
            return nil
        case .install, .signIn, .get, .configure:
            return ("exclamationmark.circle", AnyShapeStyle(Theme.stateHeld))
        }
    }
}
