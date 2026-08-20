import Foundation

/// A crew, kept.
///
/// `Session.team` already survives more than it looks — switching sessions and
/// coming back finds it intact, which is deliberate and documented in
/// `TeamBar`: a team assembled by editing a draft string is one that changes
/// when you fix a typo. What it does not survive is being a *different* piece
/// of work. Open a new session and the four agents you settled on, with the
/// models you settled on, are gone, and the way back is to remember which they
/// were.
///
/// That is a small enough friction to put up with once and an absurd one to put
/// up with weekly, and the thing being retyped is exactly the thing the team
/// control was built to stop anybody having to know: `@kimi#2:k3` is grammar,
/// and the point of the bar is that nobody should have to hold it in their
/// head.
///
/// Stored in the shared preference domain rather than beside a session, because
/// a team is not a fact about one conversation — it is a fact about how you
/// like to work, and the same four agents are the right four in the next
/// session too. `ai` reaches the same domain, so a team saved in the window is
/// readable from the terminal; nothing there offers it yet.
struct SavedTeam: Codable, Identifiable, Equatable {

    /// Stable across renaming, because the name is the part people change.
    let id: String
    var name: String
    var members: [Member]

    /// One agent on a saved team.
    ///
    /// A seat taken apart into the two things it is made of. `Seat` itself is
    /// deliberately not `Codable`: its initialiser clamps the index into range,
    /// and a decoder that bypassed that would be the one way to get a seat
    /// number this app cannot address. Rebuilding through `Seat(_:_:)` on the
    /// way out keeps the clamp on the only path there is.
    ///
    /// `Account` encodes as its own id string, so a saved team survives a
    /// custom account being renamed and refers to it by the same identifier
    /// every saved session does.
    struct Member: Codable, Equatable {
        let account: Account
        let index: Int
        var model: String?
        var effort: EffortChoice?
    }
}

enum TeamStore {

    private static let key = "crew.teams"

    /// Every saved team, in the order they were saved.
    ///
    /// Not sorted. A list of four things in the order you made them is one you
    /// navigate by memory; re-sorting it alphabetically on every save moves the
    /// row somebody was about to click.
    static var all: [SavedTeam] {
        guard let data = Prefs.store.data(forKey: key),
              let teams = try? JSONDecoder().decode([SavedTeam].self, from: data)
        else { return [] }
        return teams
    }

    private static func write(_ teams: [SavedTeam]) {
        guard let data = try? JSONEncoder().encode(teams) else { return }
        Prefs.store.set(data, forKey: key)
    }

    /// Keep this team under this name.
    ///
    /// Saving over an existing name replaces it rather than making a second
    /// entry, and keeps the original id — "save it as *frontend* again" means
    /// the team called frontend is now this, not that there are two of them.
    /// Names are compared trimmed and case-insensitively for that decision and
    /// stored exactly as typed.
    ///
    /// Refuses the empty cases rather than storing them. A team with no members
    /// restores nothing, and one with no name is a row nobody can identify.
    @discardableResult
    static func save(_ name: String, _ picks: [AgentMention.Pick]) -> SavedTeam? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !picks.isEmpty else { return nil }

        let members = picks.map {
            SavedTeam.Member(account: $0.seat.account, index: $0.seat.index,
                             model: $0.model, effort: $0.effort)
        }
        var teams = all
        if let at = teams.firstIndex(where: {
            $0.name.compare(trimmed, options: .caseInsensitive) == .orderedSame
        }) {
            teams[at].name = trimmed
            teams[at].members = members
            write(teams)
            return teams[at]
        }
        let made = SavedTeam(id: UUID().uuidString, name: trimmed, members: members)
        teams.append(made)
        write(teams)
        return made
    }

    static func remove(_ id: String) {
        write(all.filter { $0.id != id })
    }

    static func rename(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var teams = all
        guard let at = teams.firstIndex(where: { $0.id == id }) else { return }
        teams[at].name = trimmed
        write(teams)
    }

    /// A saved team as something that can be put on a session.
    ///
    /// Members whose account no longer exists are **dropped, not resurrected.**
    /// `Account(id:)` is total and would hand back a `.custom` for a definition
    /// that has been deleted — which is right for an orphaned session, whose
    /// transcript must stay readable, and wrong here: this list is about to be
    /// sent work, and a phantom account launches nothing while occupying a row
    /// that says it will.
    ///
    /// The count is returned alongside so a caller can say so. Silently
    /// restoring three of four agents is the kind of quiet subtraction that
    /// ends with somebody wondering why a piece never got done.
    static func picks(of team: SavedTeam) -> (picks: [AgentMention.Pick], dropped: Int) {
        var picks: [AgentMention.Pick] = []
        var dropped = 0
        for member in team.members {
            guard let account = Account.known(member.account.id) else {
                dropped += 1
                continue
            }
            picks.append(AgentMention.Pick(seat: Seat(account, member.index),
                                           model: member.model, effort: member.effort))
        }
        return (picks, dropped)
    }

    /// What a saved team reads as in one line — "@kimi#2 · @copilot".
    static func summary(of team: SavedTeam) -> String {
        team.members
            .map { member -> String in
                let seat = Seat(Account(id: member.account.id), member.index)
                return seat.mention
            }
            .joined(separator: " · ")
    }
}
