import SwiftUI

/// State, in the three colours the rest of the app already uses for it.
///
/// Here rather than beside `UsagePressure` itself, which lives in AgentKit and
/// so cannot see a `Color` — the engine has to run in `honeycoded`, which has
/// no windows. The bands are the engine's decision; what they look like is
/// this side's.
extension UsagePressure {
    var colour: Color {
        switch self {
        case .easy:     return Theme.stateDone
        case .tight:    return Theme.stateHeld
        case .critical: return Theme.stateBad
        }
    }
}

/// How much of one allowance is gone, drawn as an arc.
///
/// A ring rather than the bar the readouts use, because a row of these is not
/// a chart and is not meant to be read like one: four bars is a thing you study,
/// four rings is a thing you glance at and look away from, which is the only
/// interaction this is ever going to get.
///
/// The two colours say different things and are kept apart on purpose, the same
/// way `AccountDot` and the state palette are: the **dot in the middle** is
/// identity — which subscription this is — and the **arc around it** is state,
/// in the same three colours the rest of the app uses for going well, waiting,
/// and gone wrong. Colouring the arc in the account's own tint would have been
/// the obvious thing and would have left the row saying nothing at all: four
/// hues that mean four names, with the one fact you looked for — which of them
/// is nearly spent — carried by arc length alone.
///
/// These used to have a second home, in a panel that floated over every other
/// application on every Space. That is gone. The Crew pane is the one screen
/// whose stated job is "what have I got", which is where this question belongs
/// and the only place it now gets asked.
struct UsageRing: View {
    let account: Account
    /// Nil when this subscription has not reported an allowance and has no
    /// spend to measure against a cap.
    ///
    /// Drawn rather than skipped, which is the one place this disagrees with
    /// its own instinct. A row that shows only the accounts that answered is
    /// a row whose width changes as answers arrive, and — worse — one where
    /// a subscription that has gone quiet looks like a subscription you do not
    /// have. So every seat keeps its place, and one that has said nothing says
    /// so: a hollow dot, no arc, and a dash where the number goes. The hollow
    /// dot is not a new idea either — `AccountDot` already uses it to mean
    /// real but provisional.
    let reading: AccountUsage?
    var size: CGFloat = UsageRing.ring

    /// The ring's diameter.
    static let ring: CGFloat = 34

    private var window: UsageWindow? { reading?.binding }

    private var pressure: UsagePressure { window?.pressure ?? .easy }

    /// A hair of arc even at zero, so a subscription nobody has touched reads
    /// as "nothing used" rather than as a ring that failed to draw. Nothing at
    /// all when there is no reading, which is a different statement.
    private var fraction: Double {
        guard let window else { return 0 }
        return max(0.015, min(1, Double(window.percent) / 100))
    }

    var body: some View {
        VStack(spacing: Theme.s1) {
            ZStack {
                Circle()
                    .stroke(Theme.rule, lineWidth: Self.stroke)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(pressure.colour,
                            style: StrokeStyle(lineWidth: Self.stroke,
                                               lineCap: .round))
                    // From the top, clockwise. The default start is three
                    // o'clock, which reads as an arc that begins somewhere
                    // arbitrary rather than as a gauge filling up.
                    .rotationEffect(.degrees(-90))
                AccountDot(account, hollow: reading == nil,
                           size: Theme.dot + Theme.s1)
            }
            .frame(width: size, height: size)
            // Measured readings are this app's own arithmetic against a cap
            // somebody typed in — see `AccountUsage.Source`. Drawn a shade back
            // so the row doesn't present a guess and a fact at the same
            // weight; the tooltip says which is which in words.
            .opacity(reading?.source == .measured ? 0.72 : 1)

            Text(window.map { "\($0.percent)%" } ?? "—")
                .font(Theme.captionStrong)
                .monospacedDigit()
                .foregroundStyle(pressure.isAlarming
                                 ? AnyShapeStyle(Theme.stateBad)
                                 : AnyShapeStyle(.secondary))
        }
        .help(account.title + "\n" + summary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(account.title)
        .accessibilityValue(summary)
    }

    private var summary: String {
        reading?.summary ?? "No usage limits reported for this account"
    }

    private static let stroke: CGFloat = 3
}
