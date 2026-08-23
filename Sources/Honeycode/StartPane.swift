import SwiftUI

/// The head of an empty session.
///
/// It used to be a greeting and a composer, floating a quarter of the way down
/// an otherwise blank pane. That is the right shape — every one of these
/// applications opens on a big field and a friendly line — but it left the two
/// things a first run actually needs unanswered:
///
/// - **whether anything works.** `tools/doctor.sh` has always been able to say
///   which agent CLIs are installed and which accounts are signed in, and it
///   says it in a terminal, which is not where somebody who has just opened a
///   Mac application is looking. A missing CLI used to surface as a spawn error
///   *after* you had written a message.
/// - **that a crew exists at all.** Naming several accounts in one message is
///   the entire idea of this program, and an empty session said nothing about
///   it — you had to already know to reach for the team control.
///
/// Both are answered here, under the composer, where they cost nothing once you
/// are working: the whole pane is replaced by the transcript the moment there
/// is one.
struct StartPane<Composer: View>: View {
    @ObservedObject var session: Session
    @ObservedObject var workspace: Workspace
    @ViewBuilder var composer: (Bool) -> Composer

    @State private var readiness: [AccountReadiness] = []

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                Spacer().frame(height: max(0, geometry.size.height * 0.18))

                Text(Self.greeting)
                    .font(Theme.display(28))
                    .padding(.bottom, Theme.s7)

                composer(true)

                if geometry.size.height > 420 {
                    hints
                        .padding(.top, Theme.s5)
                        .transition(.opacity)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        }
        .task {
            readiness = await Task.detached(priority: .utility) {
                Diagnostic.readiness()
            }.value
        }
    }

    /// The roster and one line of grammar, sharing the composer's measure.
    private var hints: some View {
        VStack(alignment: .leading, spacing: Theme.s4) {
            roster

            // The crew sentence only where a crew exists. With it switched off
            // the Team control isn't in the header bar, and pointing at a
            // control that isn't there is worse than saying nothing.
            Text(Features.isOn(.crew)
                 ? "Add agents with **Team** above to run a crew — the first one "
                 + "named plans the work and hands out the pieces. "
                 + "Type **@** for a file, **/** for a command."
                 : "Type **@** for a file, **/** for a command.")
                .font(Theme.note)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: CGFloat(Theme.readingWidth), alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Theme.pane)
    }

    /// Every subscription, and whether it can actually run.
    ///
    /// Deliberately shows the working ones too. A list that only appears when
    /// something is broken is a list nobody trusts when it is empty — and on a
    /// machine where all four are ready, four green ticks is the fastest way to
    /// learn what this application is for.
    private var roster: some View {
        HStack(spacing: Theme.s5) {
            ForEach(readiness) { state in
                HStack(spacing: Theme.s3 - Theme.s1) {
                    AccountDot(state.account, dimmed: state.isReady ? 1 : 0.3)
                    Text(state.account.shortTitle)
                        .font(Theme.label)
                        .foregroundStyle(state.isReady ? AnyShapeStyle(.secondary)
                                                       : AnyShapeStyle(.tertiary))
                    if !state.isReady {
                        Text(state.summary)
                            .font(Theme.label)
                            .foregroundStyle(Theme.stateHeld)
                    }
                }
                .help(state.remedy ?? "\(state.account.title) — ready")
            }
            Spacer(minLength: 0)
        }
    }

    /// Time-of-day greeting using the account holder's first name.
    static var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let part = switch hour {
        case 0..<5:   "Still up"
        case 5..<12:  "Good morning"
        case 12..<18: "Good afternoon"
        default:      "Good evening"
        }
        let first = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? part : "\(part), \(first)"
    }
}
