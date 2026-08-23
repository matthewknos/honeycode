import SwiftUI
import AppKit

/// Shared visual constants.
///
/// Design rules this file exists to enforce:
///
/// - **SF Pro, not SF Rounded.** Rounded is a watchOS/Home voice.
/// - **Semantic system colours, never hand-mixed ones.** An earlier version used
///   custom "clay / slate / sage" accents. They read muddy against Apple's own
///   palette and didn't adapt between appearances. `NSColor.system*` are tuned
///   for both, and are what Finder tags and Mail mailboxes actually use.
/// - **The content pane is opaque; only the sidebar is vibrant.** This is the
///   single biggest thing separating a Mac sidebar app from a web app wearing
///   one. When both panes sample the desktop, the sidebar has no weight and the
///   whole window takes on whatever tint the wallpaper happens to be.
/// - **One spacing scale, applied everywhere.** Values are multiples of 2 from
///   a small set; anything outside it is a mistake, not a nuance.
/// - **No cards.** Messages are separated by rhythm and rules, not by rounded
///   rectangles with borders.
enum Theme {

    // MARK: Type scale

    /// The whole scale, and the same rule as the spacing one: anything outside
    /// it is a mistake, not a nuance.
    ///
    /// That rule was written down for spacing, enforced, and passed over the
    /// app. Type never got the same treatment, and the result was 168 inline
    /// sizes in twelve values — an unbroken half-point ramp from 9.5 to 13.5,
    /// with 11 and 11.5 at thirty-odd sites each, used interchangeably for the
    /// same kind of text. Nobody can see a half point. What it costs is the
    /// ability to change the app's small type at all.
    ///
    /// Whole points, because `mono` and `monoSmall` already are, and in this
    /// app proportional text sits beside monospaced constantly — a session name
    /// next to its path, a label next to a number. Two runs of text on one line
    /// should be the same size or visibly not.
    ///
    /// `t5` is the exception and is the only half point left: 13.5 is the
    /// reading size, and the paragraph on `body` argues for it.
    static let t1: CGFloat = 10    // a tally, a badge, a gutter
    static let t2: CGFloat = 11    // small chrome — a label, a hint
    static let t3: CGFloat = 12    // a row's own text
    static let t4: CGFloat = 13    // sidebar rows, section titles
    static let t5: CGFloat = 13.5  // prose
    static let t6: CGFloat = 15    // a screen's or sheet's own name

    // MARK: Type

    /// Body prose. 13.5 sits between `.body` and `.callout` — slightly more
    /// generous without tipping into large-text territory.
    static let body = Font.system(size: t5)
    static let mono = Font.system(size: t3, design: .monospaced)
    static let monoSmall = Font.system(size: t2, design: .monospaced)
    static let monoCaption = Font.system(size: t1, design: .monospaced)
    static let label = Font.system(size: t2, weight: .medium)
    static let title = Font.system(size: t4, weight: .semibold)
    /// Sidebar rows. Chrome, so a step below body.
    static let sidebarRow = Font.system(size: t4)

    /// The smallest type in the app: a count, a badge, a line-number gutter,
    /// the second line of a dense row. Below this nothing is worth reading.
    static let caption = Font.system(size: t1)
    static let captionStrong = Font.system(size: t1, weight: .medium)
    /// Chrome that is a sentence rather than a label — a hint under a control,
    /// an empty state's blurb. `label` is the same size in medium, for the ones
    /// that are a word or two naming the thing beside them.
    static let note = Font.system(size: t2)
    /// A row's own text: a session name, an account title, a mention.
    static let row = Font.system(size: t3)
    static let rowStrong = Font.system(size: t3, weight: .medium)
    /// The name of a screen, a sheet or an empty state.
    static let heading = Font.system(size: t6, weight: .semibold)

    /// Display type, used once per screen at most.
    ///
    /// Plain SF at medium weight. A serif was tried here and pulled — it read
    /// as borrowed rather than native, and SF at display size with a lighter
    /// weight than the usual semibold gets the same calm without leaving the
    /// system's own voice.
    ///
    /// The one exemption from the scale, and the exemption is what the "once
    /// per screen" is for: a greeting on a wallpaper preview and a heading over
    /// an agent's transcript are answering a question about *that* screen, not
    /// taking a step on a ladder shared with every row in the app.
    static func display(_ size: CGFloat) -> Font {
        .system(size: size, weight: .medium)
    }

    /// Leading for body prose. The SwiftUI default is tight for long-form text.
    static let lineSpacing: CGFloat = 5

    // MARK: Spacing scale

    /// The whole scale. Nothing in the app should use a spacing value that
    /// isn't one of these.
    static let s1: CGFloat = 2
    static let s2: CGFloat = 4
    static let s3: CGFloat = 6
    static let s4: CGFloat = 8
    static let s5: CGFloat = 12
    static let s6: CGFloat = 16
    static let s7: CGFloat = 24
    static let s8: CGFloat = 32

    /// Semantic aliases, so call sites say why rather than how much.
    static let gapTight = s3       // within a cluster of tool calls
    static let gapBlock = s5 + s1  // 14 — between blocks in one turn
    static let gapTurn = s8 - s1   // 30 — between turns
    static let pane = s7           // transcript inset

    // What counts as "on the scale", since the three above are not `sN`.
    //
    // A sum or difference of scale values is on it: `gapBlock` is `s5 + s1`
    // and `gapTurn` is `s8 - s1`, and both are still expressed in the only
    // units this file has. A bare number is not, however carefully it was
    // chosen by eye — that is the case the rule is for, because a literal
    // records the answer and loses the question.
    //
    // `Theme.sN ± 1` — a nudge by one point, not by a scale value — is the
    // in-between case and appears in about twenty places. It is almost always
    // a control reaching for a hit-target height rather than a gap between two
    // things, which is a different measurement wearing the spacing scale's
    // clothes. Left as it is deliberately; the fix is to name the heights, not
    // to round the nudges away.

    // MARK: Layout

    /// Maximum width of the text column — roughly 80 characters at 13.5pt.
    static let readingWidth: CGFloat = 680
    static let sidebarWidth: CGFloat = 240
    /// Collapsed sidebar. 28pt hit target with a 16pt margin either side, so
    /// the floating pill sits the same distance from the window edge as the
    /// View menu does on the other side.
    static let railWidth: CGFloat = 60
    /// A panel of content sitting on the pane, and a control you type into.
    ///
    /// The same number, and deliberately: at this app's sizes a settings card
    /// and a search field want the same corner, and two names for one value
    /// costs nothing while letting a call site say which it means. If they ever
    /// diverge it will be here, once, rather than at forty call sites.
    static let cornerCard: CGFloat = 10
    static let cornerField: CGFloat = 10
    /// A tab in a strip, and anything else the size of one. Tighter than a
    /// card because at 24pt tall a 10pt radius is most of the way to a capsule,
    /// and a row of capsules reads as segmented control rather than as tabs.
    ///
    /// This is the one that kept being reinvented — as 5, 6, 7 and 8, at
    /// fifteen sites, for the same kind of small thing: a segment, a thumbnail,
    /// an inline path, a tooltip over a plot. None of those differences were
    /// decisions and none of them are visible; what they cost is the ability to
    /// change the app's small corner at all.
    static let cornerChip: CGFloat = 7
    /// A layer floating free of the document, with the whole window under it —
    /// the command palette, the mini chat. Larger than a card because it is
    /// larger *and* nearer: the same corner that reads as crisp on a panel in
    /// the pane reads as sharp on something hanging in front of it.
    static let cornerFloat: CGFloat = 12

    /// One shape inside another, inset by `inset`, keeps the two curves
    /// concentric: `cornerChip + Theme.s1` around a chip padded by `s1`. Worth
    /// stating because the alternative reads as two unrelated numbers, and the
    /// segmented pill in the View menu had exactly that — an inner 6 and an
    /// outer 8, correct by arithmetic and unmaintainable by inspection.
    static func corner(around inner: CGFloat, inset: CGFloat) -> CGFloat {
        inner + inset
    }

    /// The account identity dot — see `AccountDot`, which draws it.
    ///
    /// Six, because the four-account palette was tuned at six: the comment
    /// justifying those hues reasons about "dots six points across" and "a 6pt
    /// dot ... against a near-white ground". It was then drawn at 4, 5, 6 and 7
    /// across twenty-eight sites, so for a third of them the tuning was being
    /// checked against a size it was never checked at.
    static let dot: CGFloat = 6
    /// The other dot: something in this account needs looking at.
    ///
    /// Deliberately smaller than `dot` rather than equal to it. Both are drawn
    /// in the account's colour and the sidebar puts them on the same row, so if
    /// they were the same size the row would read as having two identity dots —
    /// which is a rendering fault, not a message.
    static let dotAttention: CGFloat = 4

    /// The header bar above every column.
    static let headerHeight: CGFloat = 34
    /// How narrow the workbench may be dragged. Below this its tab strip loses
    /// its labels and its toolbars start wrapping.
    static let workbenchMinWidth: CGFloat = 340

    // MARK: Surfaces

    /// The content pane — a warm off-white, not `.textBackgroundColor` white.
    ///
    /// This is the one place the app leaves the system palette, and it's a
    /// deliberate trade. Pure white gives raised elements nothing to sit
    /// against: a white card on a white pane needs a heavy border to exist at
    /// all. Dropping the ground a few points warm lets `surface` be plain white
    /// and read as lifted with only a hairline. Warm rather than grey because
    /// neutral grey at this lightness goes cold and clinical.
    static var canvas: Color { Color(nsColor: .honeycodeCanvas) }

    /// Raised surfaces — the composer, the palette. White on the warm ground.
    static var surface: Color { Color(nsColor: .honeycodeSurface) }

    /// Recessed well — hover fills, chips, expanded detail.
    static var well: Color { Color(nsColor: .quaternarySystemFill) }
    /// Hairline rules. Quieter than a `.separator` border.
    ///
    /// For rules this app draws — `Divider().overlay(Theme.rule)`, and the
    /// places that stroke one by hand. Not for a `Divider()` inside a `Menu` or
    /// a `.contextMenu` builder: that is not a view, it is a request for a menu
    /// separator, and AppKit draws it to the system's own metrics. Most of the
    /// bare `Divider()`s a scan turns up are those, which is why they are bare.
    static var rule: Color { Color(nsColor: .separatorColor) }

    /// The ground under code blocks and diffs.
    ///
    /// Opaque, unlike `well`. The system fills are translucent, which was fine
    /// while the pane behind them was a flat colour — but with a background
    /// photo the wallpaper showed straight through the code, and monospace
    /// text over a photograph is unreadable at any blur setting. A block of
    /// code has to sit on something solid.
    static var codeGround: Color { Color(nsColor: .honeycodeCodeGround) }

    // MARK: Elevation
    //
    // One shadow, at three depths, and nothing else. The app had grown four
    // ad-hoc shadows — a segmented pill's 1pt, a popover's, a card's — which is
    // how a window ends up with three different ideas of how far off the page
    // anything is. It then grew four more, which is why there is a third depth
    // here rather than a fourth round of snapping everything to `high`.
    //
    // A raised control uses `low`. A layer over the document — a completion
    // panel, a tooltip over a plot — uses `high`. A layer over the *window*,
    // with nothing of its own underneath, uses `float`: the command palette
    // and the mini chat were both hand-tuned to roughly twice `high`, from
    // opposite directions, and agreed closely enough that the disagreement was
    // drift rather than a decision.

    static let shadowLow = (colour: Color.black.opacity(0.10),
                            radius: CGFloat(1.5), y: CGFloat(0.5))
    static let shadowHigh = (colour: Color.black.opacity(0.16),
                             radius: CGFloat(14), y: CGFloat(4))
    static let shadowFloat = (colour: Color.black.opacity(0.28),
                              radius: CGFloat(28), y: CGFloat(10))

    // MARK: How faint anything is allowed to be
    //
    // The app leans on SwiftUI's hierarchy styles — `.secondary`, `.tertiary`,
    // `.quaternary` — and those were never checked against the standard this
    // file already applies to colour. `systemGreen` was called a legibility bug
    // here at about 1.8:1. `.quaternary` is roughly 10% of the label colour,
    // which on `canvas` lands near 1.2:1 — a tier *below* the thing already
    // called a bug — and it was carrying real content at forty sites: a seat's
    // model list, a session count, a slug shown precisely because it "isn't
    // otherwise visible".
    //
    // So there is a floor, and it is stated rather than felt:
    //
    // - **`.secondary`** is where text bottoms out. Anything that is the only
    //   place a piece of information appears is at least this.
    // - **`.tertiary`** is for text that recedes on purpose and is not the only
    //   copy of anything — a diff's line-number gutter, a completed to-do, an
    //   8pt disclosure chevron — and for small glyphs that are affordances
    //   rather than content.
    // - **`.quaternary` is never text.** Separators, disabled controls, a large
    //   empty-state symbol, a background fill. Things whose job is to be nearly
    //   invisible, where being nearly invisible is not a failure.
    //
    // `.tertiary` is around 1.9:1 and is a floor rather than a comfortable
    // place to sit; the reason it is still allowed is that everything using it
    // is either duplicated elsewhere on screen or is not a word.

    // MARK: State
    //
    // Kept apart from the account tints below, and this separation is the whole
    // point of both sets existing. An account colour answers *who*; a state
    // colour answers *how it is going*. They were the same palette until now —
    // a working delegate was drawn in its account's orange, a failed one in a
    // raw `Color.red.opacity(0.8)` — so a run of four agents put four hues on
    // screen that meant identity and a fifth that meant trouble, all at the
    // same weight, and nothing said which kind of thing you were reading.
    //
    // Identity stays with the dot. State is always the *text*, in one of these
    // four, so the meaning of a colour never depends on where it is.

    /// In flight. Deliberately not any account's tint.
    static var stateLive: Color { Color(nsColor: .honeycodeStateLive) }
    /// Finished, and fine.
    static var stateDone: Color { Color(nsColor: .honeycodeDiffAdd) }
    /// Waiting, held back, or otherwise not going anywhere by itself.
    static var stateHeld: Color { Color(nsColor: .honeycodeStateHeld) }
    /// Failed, refused, gave up.
    static var stateBad: Color { Color(nsColor: .honeycodeDiffDel) }
}

/// One elevation, applied the same way everywhere.
struct Elevated: ViewModifier {
    enum Depth { case low, high, float }

    var depth = Depth.low

    func body(content: Content) -> some View {
        let shadow: (colour: Color, radius: CGFloat, y: CGFloat) = {
            switch depth {
            case .low:   return Theme.shadowLow
            case .high:  return Theme.shadowHigh
            case .float: return Theme.shadowFloat
            }
        }()
        return content.shadow(color: shadow.colour,
                              radius: shadow.radius, y: shadow.y)
    }
}

/// One motion vocabulary.
///
/// The app had grown four: 0.1s for some hover fills, 0.12s for others, none at
/// all for a third set, and two different springs. Nobody notices any single
/// duration, but they notice that two adjacent controls don't behave the same
/// way — it reads as parts of the interface having been made by different
/// people. Three curves cover everything here.
enum Motion {
    /// A fill or tint responding to the pointer. Short enough to feel
    /// immediate, long enough not to snap.
    static let hover = Animation.easeOut(duration: 0.12)
    /// Something appearing or leaving — a row's ⋯, a header's +.
    static let reveal = Animation.easeOut(duration: 0.16)
    /// A card opening or closing — thinking, a tool's detail, a to-do list.
    /// Slower than a reveal because the whole column moves with it.
    static let disclose = Animation.easeOut(duration: 0.2)
    /// Structural movement: the sidebar opening, a pane swapping.
    ///
    /// `smooth` rather than a hand-tuned spring. At `dampingFraction: 0.9` the
    /// sidebar overshot its width and settled back — barely a pixel, but on a
    /// hard vertical edge running the height of the window it reads as a snap.
    /// `smooth` is critically damped by definition: it decelerates like a
    /// spring and never passes its target.
    static let panel = Animation.smooth(duration: 0.34)
}

/// The two custom grounds.
///
/// Built with the dynamic-provider initialiser rather than an asset catalog so
/// they still resolve correctly when the appearance changes at runtime — a
/// plain `Color(red:green:blue:)` would freeze at whichever appearance was
/// active when the view was first built.
extension NSColor {
    static let honeycodeCanvas = NSColor(name: "honeycodeCanvas") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.110, green: 0.107, blue: 0.102, alpha: 1)   // warm near-black
            : NSColor(srgbRed: 0.969, green: 0.965, blue: 0.953, alpha: 1)   // warm off-white
    }

    static let honeycodeSurface = NSColor(name: "honeycodeSurface") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.153, green: 0.149, blue: 0.145, alpha: 1)
            : NSColor.white
    }

    /// A step *down* from the canvas in light and a step *up* in dark, so code
    /// reads as recessed either way rather than as a raised card.
    static let honeycodeCodeGround = NSColor(name: "honeycodeCodeGround") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.145, green: 0.141, blue: 0.137, alpha: 1)
            : NSColor(srgbRed: 0.941, green: 0.937, blue: 0.925, alpha: 1)
    }

    /// Diff text and fills, tuned per appearance.
    ///
    /// `systemGreen` was used raw here and it fails in light mode: at (52, 199,
    /// 89) on white it lands near 1.8:1 contrast, so an 11pt `+3` tally is
    /// effectively invisible. Every transcript colour in this app was tuned
    /// against dark, and this is the one where that showed up as a legibility
    /// bug rather than a matter of taste.
    static let honeycodeDiffAdd = NSColor(name: "honeycodeDiffAdd") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.353, green: 0.816, blue: 0.451, alpha: 1)
            : NSColor(srgbRed: 0.106, green: 0.451, blue: 0.196, alpha: 1)
    }

    static let honeycodeDiffDel = NSColor(name: "honeycodeDiffDel") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 1.000, green: 0.451, blue: 0.420, alpha: 1)
            : NSColor(srgbRed: 0.706, green: 0.145, blue: 0.110, alpha: 1)
    }

    /// In flight. A cool grey-blue rather than a hue any account owns — the one
    /// state colour that had no home, because "working" was being drawn in the
    /// working agent's own tint and so said nothing the dot wasn't already
    /// saying.
    static let honeycodeStateLive = NSColor(name: "honeycodeStateLive") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.541, green: 0.639, blue: 0.741, alpha: 1)
            : NSColor(srgbRed: 0.294, green: 0.373, blue: 0.475, alpha: 1)
    }

    /// Queued, held, waiting on something. Amber, and distinguishable from
    /// `honeycodeAccountPersonal` by being noticeably duller — the difference
    /// between "this is the personal account" and "this is stuck" can't rest on
    /// hue alone when both are orange, so it rests on chroma.
    static let honeycodeStateHeld = NSColor(name: "honeycodeStateHeld") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.839, green: 0.678, blue: 0.373, alpha: 1)
            : NSColor(srgbRed: 0.549, green: 0.404, blue: 0.078, alpha: 1)
    }

    // MARK: The four accounts
    //
    // Tuned pairs rather than `systemOrange` / `systemBlue` / `systemPurple` /
    // `systemGreen`, which is what these were.
    //
    // The system hues are each tuned to be the *only* saturated colour in a
    // window. Four of them at once, on dots six points across, don't sit in one
    // palette: system green and system orange are far brighter than system
    // purple at the same size, so a Copilot dot shouted and a Kimi dot
    // whispered, and the difference read as importance rather than as identity.
    // These four hold one chroma and one lightness across the set, so the only
    // thing that varies between them is hue — which is the only thing that is
    // supposed to mean anything.
    //
    // Light mode is the darker half of each pair: a 6pt dot and an 11pt tally
    // both have to hold against a near-white ground.

    static let honeycodeAccountPersonal = NSColor(name: "honeycodeAccountPersonal") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.941, green: 0.659, blue: 0.271, alpha: 1)
            : NSColor(srgbRed: 0.761, green: 0.439, blue: 0.039, alpha: 1)
    }

    static let honeycodeAccountWork = NSColor(name: "honeycodeAccountWork") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.420, green: 0.651, blue: 0.961, alpha: 1)
            : NSColor(srgbRed: 0.114, green: 0.388, blue: 0.780, alpha: 1)
    }

    static let honeycodeAccountKimi = NSColor(name: "honeycodeAccountKimi") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.710, green: 0.541, blue: 0.949, alpha: 1)
            : NSColor(srgbRed: 0.478, green: 0.267, blue: 0.788, alpha: 1)
    }

    static let honeycodeAccountCopilot = NSColor(name: "honeycodeAccountCopilot") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.373, green: 0.796, blue: 0.557, alpha: 1)
            : NSColor(srgbRed: 0.106, green: 0.478, blue: 0.294, alpha: 1)
    }
}

/// Account and diff colours, all derived from the system palette so they track
/// appearance changes and match the rest of macOS.
extension Color {
    static var accentPersonal: Color { Color(nsColor: .honeycodeAccountPersonal) }
    static var accentWork: Color { Color(nsColor: .honeycodeAccountWork) }
    static var accentKimi: Color { Color(nsColor: .honeycodeAccountKimi) }
    static var accentCopilot: Color { Color(nsColor: .honeycodeAccountCopilot) }

    /// Fills carry the signal; the text stays legible. Saturated full-row
    /// green and red turns a review surface into a Christmas tree and stops
    /// you reading the code, which is the actual job.
    ///
    /// The fill keeps using the bright system hue — a wash wants saturation,
    /// not contrast — while the text uses the darkened light-mode pair.
    static var diffAddFill: Color { Color(nsColor: .systemGreen).opacity(0.14) }
    static var diffDelFill: Color { Color(nsColor: .systemRed).opacity(0.13) }
    static var diffAddText: Color { Color(nsColor: .honeycodeDiffAdd) }
    static var diffDelText: Color { Color(nsColor: .honeycodeDiffDel) }
}

/// The colour that stands for an account, everywhere it appears.
///
/// Lives here rather than on `Account` because `Account` is engine-side now and
/// `honeycoded` has no use for a `Color` — and importing SwiftUI into the
/// engine to satisfy one computed property is how the boundary would have been
/// lost on the first day it existed.
extension Account {
    var accent: Color {
        switch self {
        case .personal: return .accentPersonal
        case .work:     return .accentWork
        case .kimi:     return .accentKimi
        case .copilot:  return .accentCopilot
        case .custom:   return custom?.tint.colour ?? .secondary
        }
    }

    /// The account a delegate label names, if any.
    ///
    /// An `.opinion` block carries a *label* rather than an account — either
    /// "Enterprise · Opus" from `askOpinion` or "Kimi Code #2" from a mirrored
    /// crew seat — because the two callers that build one had no reason to keep
    /// the account around. Both spellings begin with `Account.title`, which is
    /// enough to get the tint right, and getting it right is the difference
    /// between four delegates in a transcript being four identifiable agents
    /// and four identical accent-coloured boxes.
    static func named(inLabel label: String) -> Account? {
        allCases.first { label.hasPrefix($0.title) }
    }

    /// The same colour for AppKit, which the terminal renderer draws in.
    ///
    /// Was a second `switch` inside `TerminalTranscript` naming the four system
    /// colours directly — so retuning the palette here would have left coding
    /// mode on the old one, and the same account would have been two different
    /// oranges depending on which renderer you were looking at.
    var nsAccent: NSColor {
        switch self {
        case .personal: return .honeycodeAccountPersonal
        case .work:     return .honeycodeAccountWork
        case .kimi:     return .honeycodeAccountKimi
        case .copilot:  return .honeycodeAccountCopilot
        case .custom:   return custom?.tint.nsColour ?? .labelColor
        }
    }
}

extension CustomAccount.Tint {
    /// System colours rather than literals, so an added account sits in the
    /// same palette as the four that ship and follows the appearance with them.
    var colour: Color {
        switch self {
        case .teal:   return Color(nsColor: .systemTeal)
        case .pink:   return Color(nsColor: .systemPink)
        case .indigo: return Color(nsColor: .systemIndigo)
        case .brown:  return Color(nsColor: .systemBrown)
        case .red:    return Color(nsColor: .systemRed)
        case .yellow: return Color(nsColor: .systemYellow)
        }
    }

    /// The same colour for AppKit, which the terminal renderer draws in.
    var nsColour: NSColor {
        switch self {
        case .teal:   return .systemTeal
        case .pink:   return .systemPink
        case .indigo: return .systemIndigo
        case .brown:  return .systemBrown
        case .red:    return .systemRed
        case .yellow: return .systemYellow
        }
    }
}


/// What a text field looks like in this app.
///
/// Lived inside `PullRequestSheet` as a private type, which is where it was
/// first needed and not where it belongs: it is the app's field, not that
/// sheet's. The cost of it being private showed up the moment a second surface
/// wanted one — the team popover reached for `.roundedBorder`, which is AppKit's
/// field rather than this app's, and read as a control borrowed from another
/// program.
struct FormField: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.cornerField)
        return content
            .background(Theme.surface, in: shape)
            .overlay(shape.strokeBorder(Theme.rule, lineWidth: 1))
    }
}
