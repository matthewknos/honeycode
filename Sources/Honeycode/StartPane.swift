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
    /// Puts a suggestion in the field rather than sending it.
    ///
    /// Deliberately not send-on-click. A suggestion is a starting point you are
    /// meant to edit — "run the tests" is nearly always followed by *which*
    /// ones — and a chip that fires a turn is a chip you learn not to press.
    var suggest: (String) -> Void = { _ in }
    @ViewBuilder var composer: (Bool) -> Composer

    @State private var readiness: [AccountReadiness] = []

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                Spacer().frame(height: max(0, geometry.size.height * 0.16))

                VStack(alignment: .leading, spacing: Theme.s3) {
                    // An eyebrow, because the big line underneath is a
                    // greeting: warm, and silent about what this pane is. Two
                    // lines say both without either doing two jobs badly.
                    Text("NEW SESSION")
                        .font(Theme.captionStrong)
                        .kerning(0.7)
                        .foregroundStyle(.tertiary)

                    Text(Self.greeting)
                        .font(Theme.display(28))

                    Text(blurb)
                        .font(Theme.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: CGFloat(Theme.readingWidth), alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Theme.pane)
                .padding(.bottom, Theme.s6)

                if geometry.size.height > 380 {
                    suggestions
                        .padding(.bottom, Theme.s6)
                        .transition(.opacity)
                }

                composer(true)

                if geometry.size.height > 480 {
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

    /// What this pane is for, in one line.
    ///
    /// Names the folder, because that is the fact a new session most often gets
    /// wrong — an agent pointed at the wrong directory looks exactly like an
    /// agent that has misunderstood the question.
    private var blurb: String {
        let folder = session.directory.lastPathComponent
        return Features.isOn(.crew)
            ? "Working in \(folder). Name several accounts in one message and the "
              + "first one leads — it plans the work and hands out the pieces."
            : "Working in \(folder). Describe the task, or start with one of these."
    }

    /// Three openings, as chips.
    ///
    /// They are not suggestions about your work — nothing here knows what your
    /// work is. They are the three questions that are worth asking of *any*
    /// folder you have just pointed an agent at, and the reason they are on
    /// screen is that an empty field is a worse prompt than a wrong one: the
    /// first message is the one that teaches you what this thing does with a
    /// codebase, and picking one is faster than composing one.
    private var suggestions: some View {
        FlowRow(spacing: Theme.s3) {
            ForEach(StartOpenings.all, id: \.self) { text in
                Button { suggest(text) } label: {
                    Text(text)
                        .font(Theme.note)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, Theme.s5)
                        .frame(height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(InsetSurface(radius: Theme.cornerField))
                .help("Put this in the composer — you can edit it before sending")
            }
        }
        .frame(maxWidth: CGFloat(Theme.readingWidth), alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Theme.pane)
    }

    /// The roster and one line of grammar, sharing the composer's measure.
    private var hints: some View {
        VStack(alignment: .leading, spacing: Theme.s4) {
            roster

            // The two keys that do something in the field below, and the only
            // two: the crew sentence this used to sit beside is in `blurb`
            // now, where it can name the folder in the same breath.
            Text("Type **@** for a file, **/** for a command.")
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
                HStack(spacing: Theme.s2) {
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

/// The three questions worth asking of any folder.
///
/// A type of its own because `StartPane` is generic over its composer, and Swift
/// will not put a stored static on a generic type. Which is a fair rule and a
/// silly reason to inline three strings into a view body.
enum StartOpenings {
    static let all = [
        "Explore this folder and explain how it is put together.",
        "Find the tests, run them, and report what fails.",
        "What would you change first, and why?",
    ]
}
