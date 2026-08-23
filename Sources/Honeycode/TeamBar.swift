import SwiftUI

/// Who this message goes to besides the agent you're talking to.
///
/// The grammar underneath — `@kimi#2:k3` — is exact, documented and readable,
/// and it is still grammar. Somebody had to be *told* it to run four Kimis on
/// K3, which makes it the one part of a crew you cannot use without being
/// taught. Everything it encodes is already known here: which accounts exist,
/// what each can run, and that a subscription may hold up to `Seat.limit`
/// conversations at once. So the bar composes the mentions and the person picks
/// from a list.
///
/// It doesn't type into the field. A mention that lives in the draft is one you
/// can half-delete, and a crew assembled by editing a string is a crew that
/// changes when you fix a typo — so the team is state on the session, rendered
/// as chips, and prepended when you send. It also survives switching sessions
/// and coming back, which the draft does not: you assemble a team once and then
/// talk to it.
struct TeamBar: View {
    @ObservedObject var session: Session
    /// The account this composer belongs to. It leads, so it is never a
    /// delegate — naming it would be asking the conversation to help itself.
    var leader: Account
    /// In the header bar rather than on a row of its own.
    ///
    /// Drops the trailing spacer and the agent count. A row inside the composer
    /// card had the width to spend on both; a cluster sharing a 34pt bar with
    /// the usage readouts and two buttons does not, and "3 agents" is a fact
    /// the three chips beside it already state.
    var inline = false

    @State private var picking = false
    /// Loaded when the popover opens rather than observed. Teams change only
    /// when this control changes them, and a store that published would be
    /// machinery for an event that has one source.
    @State private var teams: [SavedTeam] = []
    @State private var naming = false
    @State private var draftName = ""
    /// What was lost restoring a team, if anything. See `apply`.
    @State private var note: String?

    var body: some View {
        HStack(spacing: Theme.s3) {
            ForEach(session.team, id: \.seat) { pick in
                chip(pick)
            }
            addButton
            if !inline {
                Spacer(minLength: 0)
                if !session.team.isEmpty { cost }
            }
        }
    }

    // MARK: One agent on the team

    private func chip(_ pick: AgentMention.Pick) -> some View {
        HStack(spacing: Theme.s3 - Theme.s1) {
            AccountDot(pick.account)

            // The handle, because that is what will be on the wire and what the
            // transcript will show. Nothing is hidden by the control.
            Text(pick.seat.handle)
                .font(Theme.monoSmall)

            Menu {
                Button("Default") { setModel(nil, for: pick.seat) }
                Divider()
                ForEach(ModelCatalog.models(for: pick.account), id: \.id) { model in
                    Button(model.title) { setModel(model.id, for: pick.seat) }
                }
            } label: {
                Text(modelLabel(pick))
                    .font(Theme.monoSmall)
                    .foregroundStyle(.tertiary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Button {
                session.team.removeAll { $0.seat == pick.seat }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Take \(pick.seat.mention) off the team")
        }
        .padding(.horizontal, Theme.s4)
        .padding(.vertical, Theme.s2)
        .background(Theme.well, in: Capsule())
    }

    private func modelLabel(_ pick: AgentMention.Pick) -> String {
        guard let hint = pick.model else {
            // What it will actually run, rather than the word "default" — the
            // question this answers is "which model is this", and the honest
            // answer is a name.
            return ModelCatalog.models(for: pick.account)
                .first { $0.id == ModelCatalog.preferred(for: pick.account) }?.title
                ?? ModelCatalog.models(for: pick.account).first?.title ?? "default"
        }
        return ModelCatalog.models(for: pick.account)
            .first { $0.id == hint }?.title ?? hint
    }

    // MARK: Adding one

    private var addButton: some View {
        Button { picking = true } label: {
            HStack(spacing: Theme.s3 - Theme.s1) {
                Image(systemName: "person.2")
                    .font(.system(size: 9.5))
                Text(session.team.isEmpty ? "Team" : "Add")
                    .font(Theme.label)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, Theme.s4)
            .padding(.vertical, Theme.s2)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Send this message to other agents as well")
        .popover(isPresented: $picking, arrowEdge: .top) {
            picker
        }
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: Theme.s4) {
            Text("Also send to")
                .font(Theme.label)
                .foregroundStyle(.secondary)

            ForEach(Account.enabled.filter { $0 != leader }, id: \.self) { account in
                accountRow(account)
            }

            saved

            checking

            Divider().overlay(Theme.rule)

            if let note {
                Text(note)
                    .font(Theme.label)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 260, alignment: .leading)
            }

            // Said once, here, where the decision is made. A person adding a
            // fourth agent is committing to four times the spend, and finding
            // that out from the bill is finding out too late.
            Text("Each instance is a separate agent running at the same time, "
                 + "on that subscription. Three of one agent costs three times "
                 + "as much as one.")
                .font(Theme.label)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 260, alignment: .leading)
        }
        .padding(Theme.s5)
        .onAppear { teams = TeamStore.all; note = nil; naming = false }
    }

    // MARK: Teams that outlive the session

    /// The saved list, and the way into it.
    ///
    /// Below the account rows rather than above them: assembling a team is what
    /// this popover is for, and reusing one is what you do once you have. A
    /// list at the top would put the less common action in the more prominent
    /// place — and on a machine with no saved teams, an empty heading.
    @ViewBuilder
    private var saved: some View {
        if !teams.isEmpty || !session.team.isEmpty {
            Divider().overlay(Theme.rule)
            HStack {
                Text("Saved teams")
                    .font(Theme.label)
                    .foregroundStyle(.secondary)
                Spacer(minLength: Theme.s6)
                if !session.team.isEmpty && !naming {
                    Button("Save this one") {
                        draftName = ""
                        naming = true
                    }
                    .buttonStyle(.plain)
                    .font(Theme.label)
                    .foregroundStyle(Color.accentColor)
                }
            }

            if naming { nameField }

            ForEach(teams) { team in
                savedRow(team)
            }
        }
    }

    private var nameField: some View {
        // Submitting on Enter and nowhere else. A team is named in one word and
        // a Save button beside a one-word field is a button nobody reaches for.
        TextField("Name this team", text: $draftName)
            .textFieldStyle(.plain)
            .font(Theme.label)
            .padding(.horizontal, Theme.s4)
            .padding(.vertical, Theme.s3)
            .modifier(FormField())
            .frame(width: 260)
            .onSubmit {
                TeamStore.save(draftName, session.team)
                teams = TeamStore.all
                naming = false
                draftName = ""
            }
    }

    private func savedRow(_ team: SavedTeam) -> some View {
        Button {
            apply(team)
        } label: {
            VStack(alignment: .leading, spacing: Theme.s1) {
                Text(team.name)
                    .font(Theme.body)
                // What it will actually put on the team, in the grammar the
                // chips will show — so choosing between two saved teams is
                // reading, not remembering.
                Text(TeamStore.summary(of: team))
                    .font(Theme.monoSmall)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(width: 260, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Replace with the current team") {
                TeamStore.save(team.name, session.team)
                teams = TeamStore.all
            }
            .disabled(session.team.isEmpty)
            Divider()
            Button("Delete", role: .destructive) {
                TeamStore.remove(team.id)
                teams = TeamStore.all
            }
        }
    }

    // MARK: What gets checked before the lead assembles

    /// The project's own check, shown where the crew is configured.
    ///
    /// Here rather than in Settings because a check is a fact about *this*
    /// directory, and the Settings window has no idea which one you are looking
    /// at. This popover already knows: it belongs to a session, and a session
    /// is a conversation about a folder.
    ///
    /// Shown resolved rather than blank — whatever is in the field is what will
    /// actually run, whether somebody typed it, the project declared it in
    /// `.honeycode-check`, or it was inferred from a manifest. A field that
    /// shows nothing while a check runs anyway is the control lying about the
    /// thing it controls.
    @ViewBuilder
    private var checking: some View {
        Divider().overlay(Theme.rule)
        VStack(alignment: .leading, spacing: Theme.s2) {
            Text("Before assembling")
                .font(Theme.label)
                .foregroundStyle(.secondary)

            TextField("", text: checkCommand, prompt: Text("Nothing is checked"))
                .textFieldStyle(.plain)
                .font(Theme.monoSmall)
                .padding(.horizontal, Theme.s4)
                .padding(.vertical, Theme.s3)
                .modifier(FormField())
                .frame(width: 260)

            HStack(spacing: Theme.s3) {
                Text(checkBlurb)
                    .font(Theme.label)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if Verification.configured(for: session.directory) != nil {
                    Button("Reset") {
                        Verification.setCommand(nil, for: session.directory)
                        note = nil
                    }
                    .buttonStyle(.plain)
                    .font(Theme.label)
                    .foregroundStyle(Color.accentColor)
                    .help("Go back to what this project declares or implies")
                }
            }
            .frame(width: 260, alignment: .leading)
        }
    }

    /// Bound straight to the store, not to `@State`. The check is read at the
    /// end of a run by code that has never seen this view, so what is on screen
    /// has to be what is on disk.
    private var checkCommand: Binding<String> {
        Binding(get: { Verification.check(for: session.directory)?.command ?? "" },
                set: { Verification.setCommand($0, for: session.directory) })
    }

    private var checkBlurb: String {
        guard let check = Verification.check(for: session.directory) else {
            return "Nothing runs. Type a command to check the work before the lead assembles."
        }
        switch check.source {
        case .configured: return "Set for this project."
        case .declared:   return "From this project's .honeycode-check file."
        case .detected:   return "Inferred from this project. Runs after the team finishes; "
                               + "the lead sees the result before it assembles."
        }
    }

    /// Put a saved team on this session, and say what didn't come with it.
    ///
    /// Two things can go missing between saving and restoring, and both are the
    /// kind of quiet subtraction that ends with somebody wondering why a piece
    /// never got done: an account whose definition has since been deleted, and
    /// the account that happens to lead *this* session — which is on the team
    /// by being the conversation you are in, not by being a delegate of itself.
    private func apply(_ team: SavedTeam) {
        let restored = TeamStore.picks(of: team)
        let usable = restored.picks.filter { $0.account != leader }
        session.team = usable

        var why: [String] = []
        if restored.dropped > 0 {
            why.append(restored.dropped == 1 ? "one account no longer exists"
                                             : "\(restored.dropped) accounts no longer exist")
        }
        if restored.picks.count > usable.count {
            why.append("\(leader.shortTitle) leads this session")
        }
        note = why.isEmpty
            ? nil
            : "Restored \(usable.count) of \(team.members.count) — " + why.joined(separator: ", ")
        picking = why.isEmpty ? false : true
    }

    private func accountRow(_ account: Account) -> some View {
        let count = instances(of: account)
        return HStack(spacing: Theme.s4) {
            AccountDot(account)
            Text(account.title)
                .font(Theme.body)
            Spacer(minLength: Theme.s6)

            // A stepper rather than a number field: the range is one to four,
            // and the only two things anyone does here are "one more" and
            // "none".
            Button { remove(account) } label: {
                Image(systemName: "minus")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .disabled(count == 0)
            .opacity(count == 0 ? 0.3 : 1)

            Text("\(count)")
                .font(Theme.monoSmall)
                .monospacedDigit()
                .frame(width: 14)
                .foregroundStyle(count == 0 ? AnyShapeStyle(.tertiary)
                                            : AnyShapeStyle(.primary))

            Button { add(account) } label: {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .disabled(count >= Seat.limit)
            .opacity(count >= Seat.limit ? 0.3 : 1)
            .help(count >= Seat.limit
                  ? "\(Seat.limit) at once is the most one subscription will run"
                  : "One more \(account.shortTitle)")
        }
    }

    // MARK: What it costs, before it is spent

    private var cost: some View {
        Text(session.team.count == 1
             ? "1 agent"
             : "\(session.team.count) agents")
            .font(Theme.label)
            .foregroundStyle(.tertiary)
    }

    // MARK: Editing the team

    private func instances(of account: Account) -> Int {
        session.team.filter { $0.account == account }.count
    }

    /// Seats are always 1…n with no gaps, so removing the middle one and adding
    /// another can't produce `@kimi#1, @kimi#3`. The numbers are an ordinal, not
    /// an identity — nothing is attached to a particular one.
    private func add(_ account: Account) {
        let next = instances(of: account) + 1
        guard next <= Seat.limit else { return }
        // Inherit the model already chosen for this account's other instances,
        // which is nearly always what was meant: four Kimis on K3 is one
        // decision, not four.
        let model = session.team.first { $0.account == account }?.model
        session.team.append(AgentMention.Pick(seat: Seat(account, next), model: model))
    }

    private func remove(_ account: Account) {
        guard let last = session.team.lastIndex(where: { $0.account == account }) else { return }
        session.team.remove(at: last)
        renumber(account)
    }

    private func setModel(_ id: String?, for seat: Seat) {
        guard let index = session.team.firstIndex(where: { $0.seat == seat }) else { return }
        session.team[index] = AgentMention.Pick(seat: seat, model: id,
                                                effort: session.team[index].effort)
    }

    private func renumber(_ account: Account) {
        var seen = 0
        for index in session.team.indices where session.team[index].account == account {
            seen += 1
            let pick = session.team[index]
            session.team[index] = AgentMention.Pick(seat: Seat(account, seen),
                                                    model: pick.model, effort: pick.effort)
        }
    }
}
