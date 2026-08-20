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

    @State private var picking = false

    var body: some View {
        HStack(spacing: Theme.s3) {
            ForEach(session.team, id: \.seat) { pick in
                chip(pick)
            }
            addButton
            Spacer(minLength: 0)
            if !session.team.isEmpty { cost }
        }
    }

    // MARK: One agent on the team

    private func chip(_ pick: AgentMention.Pick) -> some View {
        HStack(spacing: Theme.s3 - Theme.s1) {
            Circle()
                .fill(pick.account.accent)
                .frame(width: 5, height: 5)

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

            ForEach(Account.allCases.filter { $0 != leader }, id: \.self) { account in
                accountRow(account)
            }

            Divider()

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
    }

    private func accountRow(_ account: Account) -> some View {
        let count = instances(of: account)
        return HStack(spacing: Theme.s4) {
            Circle()
                .fill(account.accent)
                .frame(width: 6, height: 6)
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
