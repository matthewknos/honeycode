import SwiftUI

/// The crew, as a place rather than as a moment.
///
/// A crew run had exactly one surface before this: a block at the foot of the
/// session that started it, drawn while the run was in flight and gone the
/// instant it finished. So the thing this whole application is *for* — several
/// paid subscriptions working at once — was the least durable thing in it. You
/// could not see what four agents cost after the fact, could not see whether a
/// subscription was near its limit before spending it, and could not see that a
/// second session was mid-run while you were reading the first.
///
/// This is the third sidebar mode, beside Code and Agents, and it answers the
/// three questions that had nowhere to be asked:
///
/// - **who is running right now**, across every session, not just this one;
/// - **what have I got** — the four subscriptions, whether each is installed
///   and signed in, what it can run, and how much of it is left;
/// - **what teams have I saved**, which lived inside a popover inside the
///   composer of whichever session happened to be selected.
struct CrewPane: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject private var usage = UsageStore.shared

    @State private var readiness: [AccountReadiness] = []
    @State private var teams: [SavedTeam] = []

    private var live: [Session] {
        workspace.sessions.filter { $0.crewRun != nil }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s7) {
                if !live.isEmpty { running }
                seats
                checking
                saved
            }
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.pane)
            .padding(.top, Chrome.trafficLightClearance + Theme.s5)
            .padding(.bottom, Theme.s8)
        }
        .task {
            readiness = await Task.detached(priority: .utility) {
                Diagnostic.readiness()
            }.value
            teams = TeamStore.all
        }
    }

    // MARK: Running now

    /// Every live run in the window, not just this session's.
    ///
    /// Two crews at once is an ordinary thing to want — that is the entire
    /// point of holding four subscriptions — and until now the second one was
    /// invisible unless you happened to be looking at its column.
    private var running: some View {
        VStack(alignment: .leading, spacing: Theme.s5) {
            heading("Running now")
            ForEach(live) { session in
                VStack(alignment: .leading, spacing: Theme.s4) {
                    Button {
                        workspace.reveal(session.id)
                    } label: {
                        HStack(spacing: Theme.s3) {
                            AccountDot(session.account)
                            Text(session.name)
                                .font(Theme.rowStrong)
                            Text(session.directory.lastPathComponent)
                                .font(Theme.monoSmall)
                                .foregroundStyle(.tertiary)
                            Spacer(minLength: Theme.s4)
                            Text("Open")
                                .font(Theme.label)
                                .foregroundStyle(Color.accentColor)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if let run = session.crewRun {
                        CrewRunPanel(run: run, session: session)
                    }
                }
            }
        }
    }

    // MARK: What you have

    /// The four subscriptions, and the state of each.
    ///
    /// Readiness comes from the same check `tools/doctor.sh` runs — see
    /// `Diagnostic.readiness` — which until now was only answerable from a
    /// terminal. Usage comes from whatever the account reports, which is
    /// genuinely different per account and so is shown differently per account
    /// rather than forced into one meaningless number.
    private var seats: some View {
        VStack(alignment: .leading, spacing: Theme.s5) {
            heading("Seats")
            VStack(spacing: 0) {
                ForEach(readiness) { state in
                    seatRow(state)
                    if state.id != readiness.last?.id {
                        Divider().overlay(Theme.rule)
                    }
                }
            }
            .modifier(InsetSurface(radius: Theme.cornerField))
        }
    }

    private func seatRow(_ state: AccountReadiness) -> some View {
        let account = state.account
        let open = workspace.sessions(in: account).count
        return HStack(alignment: .top, spacing: Theme.s5) {
            AccountDot(account, dimmed: state.isReady ? 1 : 0.3)
                // Nudging the dot down onto the title's cap height, not a gap
                // between two things — but it was a bare 5, and the scale does
                // not have one. What this is reaching for is a baseline
                // alignment guide; that wants measuring against real type on a
                // real screen, and a 1pt shift onto the scale is the honest
                // version until somebody does.
                .padding(.top, Theme.s3)

            VStack(alignment: .leading, spacing: Theme.s2) {
                HStack(spacing: Theme.s3) {
                    Text(account.title)
                        .font(Theme.rowStrong)
                    Text(account.agentName)
                        .font(Theme.label)
                        .foregroundStyle(.tertiary)
                }
                Text(modelSummary(account))
                    .font(Theme.monoSmall)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: Theme.s5)

            VStack(alignment: .trailing, spacing: Theme.s2) {
                if state.isReady {
                    if let allowance = allowance(account) {
                        Text(allowance)
                            .font(Theme.label)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    } else {
                        Text("ready")
                            .font(Theme.label)
                            .foregroundStyle(Theme.stateDone)
                    }
                } else {
                    Text(state.summary)
                        .font(Theme.label)
                        .foregroundStyle(Theme.stateHeld)
                        .help(state.remedy ?? "")
                }
                Text(open == 1 ? "1 session" : "\(open) sessions")
                    .font(Theme.label)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Theme.s5)
        .padding(.vertical, Theme.s4 + 1)
        .help(state.remedy ?? "\(account.title) — ready")
    }

    /// What is left, in whatever unit this account actually bills in.
    private func allowance(_ account: Account) -> String? {
        if let reported = usage.usage[account], let binding = reported.binding {
            return "\(binding.percent)% \(binding.label)"
        }
        if let cap = usage.capUsage(account) {
            return String(format: "%d%% of $%.0f", cap.percent, cap.cap)
        }
        let spent = usage.monthlySpend[account] ?? 0
        return spent > 0 ? String(format: "$%.2f this month", spent) : nil
    }

    private func modelSummary(_ account: Account) -> String {
        let models = ModelCatalog.models(for: account)
        guard !models.isEmpty else { return "no models reported yet" }
        let names = models.prefix(4).map(\.title).joined(separator: " · ")
        return models.count > 4 ? names + " · +\(models.count - 4)" : names
    }

    // MARK: What gets checked before the lead assembles

    /// The project's own check, said where a crew is the subject.
    ///
    /// It exists in the Team popover too, and deliberately: that is where you
    /// are standing when you decide what a run will do, and `TeamBar`'s
    /// reasoning for putting it there — a check is a fact about *this*
    /// directory, and the Settings window has no idea which one you are looking
    /// at — is still correct. What was wrong was that being the *only* place:
    /// a setting reachable solely by opening a popover inside a composer, on
    /// the session that happened to be selected, is a setting most people never
    /// learn exists.
    ///
    /// Both bind straight to `Verification`, so there is one value and two
    /// views of it rather than two settings that can disagree.
    @ViewBuilder
    private var checking: some View {
        if let session = workspace.selected {
            VStack(alignment: .leading, spacing: Theme.s4) {
                heading("Before assembling")
                Text("Runs when the delegates finish and before the lead puts "
                     + "their work together, in **\(session.directory.lastPathComponent)**. "
                     + "The lead sees the result.")
                    .font(Theme.note)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextField("", text: checkCommand(for: session),
                          prompt: Text("Nothing is checked"))
                    .textFieldStyle(.plain)
                    .font(Theme.monoSmall)
                    .padding(.horizontal, Theme.s5)
                    .padding(.vertical, Theme.s4)
                    .modifier(FormField())

                HStack(spacing: Theme.s4) {
                    Text(checkBlurb(for: session))
                        .font(Theme.label)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if Verification.configured(for: session.directory) != nil {
                        Button("Reset") {
                            Verification.setCommand(nil, for: session.directory)
                        }
                        .buttonStyle(.plain)
                        .font(Theme.label)
                        .foregroundStyle(Color.accentColor)
                        .help("Go back to what this project declares or implies")
                    }
                }
            }
        }
    }

    private func checkCommand(for session: Session) -> Binding<String> {
        Binding(get: { Verification.check(for: session.directory)?.command ?? "" },
                set: { Verification.setCommand($0, for: session.directory) })
    }

    private func checkBlurb(for session: Session) -> String {
        guard let check = Verification.check(for: session.directory) else {
            return "Nothing runs. Type a command to check the work before the lead assembles."
        }
        switch check.source {
        case .configured: return "Set for this project."
        case .declared:   return "From this project's .honeycode-check file."
        case .detected:   return "Inferred from this project."
        }
    }

    // MARK: Teams

    /// The saved teams, out of the popover they were hiding in.
    ///
    /// They were reachable only through the composer's Team control, on the
    /// session that happened to be selected — so a list of crews you had
    /// deliberately named and kept was addressable from one place, and only
    /// while you were about to send a message.
    private var saved: some View {
        VStack(alignment: .leading, spacing: Theme.s5) {
            heading("Saved teams")
            if teams.isEmpty {
                Text("None yet. Assemble a crew in a session's **Team** control "
                     + "and save it there, and it will be here for every session "
                     + "afterwards.")
                    .font(Theme.note)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(teams) { team in
                        teamRow(team)
                        if team.id != teams.last?.id {
                            Divider().overlay(Theme.rule)
                        }
                    }
                }
                .modifier(InsetSurface(radius: Theme.cornerField))
            }
        }
    }

    private func teamRow(_ team: SavedTeam) -> some View {
        HStack(spacing: Theme.s5) {
            VStack(alignment: .leading, spacing: Theme.s1) {
                Text(team.name)
                    .font(Theme.rowStrong)
                Text(TeamStore.summary(of: team))
                    .font(Theme.monoSmall)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: Theme.s5)

            // Applying needs a session to apply *to*, and the leader of that
            // session is never a delegate of itself — the same rule `TeamBar`
            // enforces, restated here rather than duplicated: this calls the
            // same restore and drops the same member.
            if let target = workspace.selected {
                Button("Use in \(target.name)") { apply(team, to: target) }
                    .buttonStyle(.plain)
                    .font(Theme.label)
                    .foregroundStyle(Color.accentColor)
            }

            Button {
                TeamStore.remove(team.id)
                teams = TeamStore.all
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HoverCapsule())
            .help("Delete this team")
        }
        .padding(.horizontal, Theme.s5)
        .padding(.vertical, Theme.s4 + 1)
    }

    private func apply(_ team: SavedTeam, to session: Session) {
        let restored = TeamStore.picks(of: team)
        session.team = restored.picks.filter { $0.account != session.account }
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(Theme.display(Theme.t6))
    }
}

// MARK: - The sidebar in Crew mode

/// Live runs first, then the teams — the two lists you navigate by.
///
/// Not the session list. In this mode the question is "what is my crew doing",
/// and the answer is not organised by conversation: one session can hold a run
/// and four others hold none, so a list of every session would be mostly rows
/// with nothing to say.
struct CrewSidebar: View {
    @ObservedObject var workspace: Workspace
    /// Switching back to the conversation, since opening a run means going to
    /// the session it belongs to.
    var onOpenSession: (Session.ID) -> Void

    @State private var teams: [SavedTeam] = []

    private var live: [Session] {
        workspace.sessions.filter { $0.crewRun != nil }
    }

    var body: some View {
        List {
            Section("Running now") {
                if live.isEmpty {
                    Text("Nothing running")
                        .font(Theme.sidebarRow)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(live) { session in
                        Button { onOpenSession(session.id) } label: {
                            HStack(spacing: Theme.s3) {
                                AccountDot(session.account, gutter: 12)
                                Text(session.name)
                                    .font(Theme.sidebarRow)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: Theme.s2)
                                if let run = session.crewRun {
                                    Text("\(run.members.count)")
                                        .font(Theme.label)
                                        .monospacedDigit()
                                        .foregroundStyle(Theme.stateLive)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section("Teams") {
                if teams.isEmpty {
                    Text("None saved")
                        .font(Theme.sidebarRow)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(teams) { team in
                        HStack(spacing: Theme.s3) {
                            Image(systemName: "person.2")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                                .frame(width: 12, alignment: .center)
                            Text(team.name)
                                .font(Theme.sidebarRow)
                                .lineLimit(1)
                        }
                        .help(TeamStore.summary(of: team))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 26)
        .onAppear { teams = TeamStore.all }
    }
}
