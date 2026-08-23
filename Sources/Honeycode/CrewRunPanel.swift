import SwiftUI

/// A crew run, while you are watching it.
///
/// The terminal has drawn this for as long as delegates have run in parallel;
/// the window never has. See `CrewRun` for what that cost — five of the six
/// messages in the run that prompted it were the person asking what the system
/// was doing, because nothing on screen said.
///
/// Deliberately at the foot of the pane rather than in the transcript. The
/// transcript is a record and this is a *state*: it changes every second, it is
/// only true while the run is in flight, and interleaving it with what the
/// agents said would push the conversation up the screen once per tick. The
/// terminal put its block at the bottom for the same reason.
struct CrewRunPanel: View {
    @ObservedObject var run: CrewRun
    @ObservedObject var session: Session

    var body: some View {
        // One clock for the whole panel, so seven rows don't run seven timers.
        // Paused when nothing is in flight — a finished run has nothing left to
        // count and shouldn't keep the display awake to say so.
        TimelineView(.periodic(from: .now, by: run.isBusy ? 1 : 60)) { _ in
            VStack(alignment: .leading, spacing: Theme.s3) {
                header
                ForEach(run.members) { member in
                    MemberRow(member: member)
                }
            }
            .padding(.horizontal, Theme.s5)
            .padding(.vertical, Theme.s4 + Theme.s1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(InsetSurface(radius: Theme.cornerField))
        }
    }

    // MARK: The line that answers "how long, how much, and can I stop it"

    private var header: some View {
        HStack(spacing: Theme.s4) {
            Text(headline)
                .font(Theme.label)
                .foregroundStyle(.secondary)

            if let phase = run.phase {
                Text(phase)
                    .font(Theme.label)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: Theme.s4)

            // Said while it is being spent, not once it has been. Four
            // subscriptions at once is exactly when a number climbing is worth
            // looking at, and the end of the run is the one moment it no longer
            // changes anything.
            if run.spend > 0 {
                Text(String(format: "$%.2f", run.spend))
                    .font(Theme.monoSmall)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            Text(Self.clock(run.elapsed))
                .font(Theme.monoSmall)
                .foregroundStyle(.tertiary)
                .monospacedDigit()

            if run.isBusy {
                Button(action: session.stopCrew) {
                    Text("Stop")
                        .font(Theme.label)
                        .padding(.horizontal, Theme.s4)
                        .padding(.vertical, Theme.s1 + 1)
                        .background(Theme.well, in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Stop every agent in this run")
            }
        }
    }

    private var headline: String {
        let live = run.members.filter {
            $0.state == .working || $0.state == .answering
        }.count
        if run.finished { return "Run finished" }
        guard !run.members.isEmpty else { return "Planning" }
        return live == 0
            ? "\(run.members.count) agent\(run.members.count == 1 ? "" : "s")"
            : "\(live) of \(run.members.count) working"
    }

    /// `2m 14s`. Seconds all the way up, because a run is minutes long and
    /// "1m" for anything under two is less informative than the number.
    private static func clock(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded())
        return total < 60 ? "\(total)s" : "\(total / 60)m \(total % 60)s"
    }
}

// MARK: - One agent

/// Split in two around one fact: a member that is working has a conversation to
/// observe, and a member whose piece never left has nothing. Observing requires
/// an object, so the alternative is a stand-in `Session` for rows that will
/// never read it — a real child process and a real model catalogue, built to be
/// ignored. The row that needs a session takes one; the row that doesn't,
/// doesn't exist.
private struct MemberRow: View {
    let member: CrewRun.Member

    var body: some View {
        if let session = member.session {
            LiveRow(member: member, session: session)
        } else {
            RowChrome(member: member, detail: member.detail)
        }
    }
}

private struct LiveRow: View {
    let member: CrewRun.Member
    @ObservedObject var session: Session

    var body: some View {
        // What it is doing beats what it was given: the plan is a line you read
        // a minute ago, and "what is it doing *now*" is the question the panel
        // exists to answer. Until it has started, the piece is the better
        // answer than "starting".
        let now = session.activity()
        RowChrome(member: member,
                  detail: now == "starting" ? member.detail : now)
    }
}

private struct RowChrome: View {
    let member: CrewRun.Member
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.s4) {
            // Tinted by account, named by seat: two instances of one
            // subscription are the same colour on purpose, because what they
            // cost comes out of the same place.
            AccountDot(member.seat.account, dimmed: dimmed ? 0.35 : 1)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }

            Text(member.seat.mention)
                .font(Theme.monoSmall)
                .foregroundStyle(dimmed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))

            if !member.model.isEmpty {
                Text(member.model)
                    .font(Theme.monoSmall)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }

            Text(detail)
                .font(Theme.monoSmall)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            // What it changed, beside what it says. A delegate that wrote
            // nothing and one that wrote nine both used to read "done".
            if let files = member.files, !member.state.isLive {
                Text(files == 0 ? "no files" : "\(files) file\(files == 1 ? "" : "s")")
                    .font(Theme.monoSmall)
                    .foregroundStyle(files == 0 ? AnyShapeStyle(Theme.stateHeld)
                                                : AnyShapeStyle(.tertiary))
            }

            Text(badge)
                .font(Theme.label)
                .foregroundStyle(badgeTint)
        }
    }

    private var badge: String {
        switch member.state {
        case .waiting:   return "queued"
        case .working:   return "working"
        case .answering: return "answering"
        case .done:      return "done"
        case .held:      return "not sent"
        case .gaveUp:    return "gave up"
        }
    }

    /// State, in the state palette — never in the account's own.
    ///
    /// "working" used to be drawn in the member's account tint, which put the
    /// same orange on the dot (meaning *personal*) and on the word beside it
    /// (meaning *in flight*), so a row said one thing twice and neither
    /// unambiguously. See `Theme.stateLive`.
    private var badgeTint: AnyShapeStyle {
        switch member.state {
        case .working, .answering: return AnyShapeStyle(Theme.stateLive)
        case .done:                return AnyShapeStyle(Theme.stateDone)
        case .held:                return AnyShapeStyle(Theme.stateHeld)
        case .gaveUp:              return AnyShapeStyle(Theme.stateBad)
        default:                   return AnyShapeStyle(.tertiary)
        }
    }

    private var dimmed: Bool {
        switch member.state {
        case .working, .answering: return false
        default: return true
        }
    }
}

extension CrewRun.State {
    /// Still going, so "what it changed" is not yet a finished number.
    var isLive: Bool {
        self == .working || self == .answering || self == .waiting
    }
}

extension CrewRun.Member {
    /// What to say when the agent isn't saying anything itself. A refusal
    /// explains itself; everyone else is described by their piece.
    var detail: String {
        if case .held(let reason) = state { return reason }
        return piece
    }
}
