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

    // MARK: Type

    /// Body prose. 13.5 sits between `.body` and `.callout` — slightly more
    /// generous without tipping into large-text territory.
    static let body = Font.system(size: 13.5)
    static let bodyEmphasis = Font.system(size: 13.5, weight: .medium)
    static let mono = Font.system(size: 12, design: .monospaced)
    static let monoSmall = Font.system(size: 11, design: .monospaced)
    static let label = Font.system(size: 11, weight: .medium)
    static let title = Font.system(size: 13, weight: .semibold)
    /// Sidebar rows. Chrome, so a step below body.
    static let sidebarRow = Font.system(size: 13)

    /// Display type, used once per screen at most.
    ///
    /// Plain SF at medium weight. A serif was tried here and pulled — it read
    /// as borrowed rather than native, and SF at display size with a lighter
    /// weight than the usual semibold gets the same calm without leaving the
    /// system's own voice.
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

    // MARK: Layout

    /// Maximum width of the text column — roughly 80 characters at 13.5pt.
    static let readingWidth: CGFloat = 680
    static let sidebarWidth: CGFloat = 240
    /// Collapsed sidebar. 28pt hit target with a 16pt margin either side, so
    /// the floating pill sits the same distance from the window edge as the
    /// View menu does on the other side.
    static let railWidth: CGFloat = 60
    static let cornerCard: CGFloat = 8
    static let cornerField: CGFloat = 10

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
    static var wellRaised: Color { Color(nsColor: .tertiarySystemFill) }
    /// Hairline rules. Quieter than a `.separator` border.
    static var rule: Color { Color(nsColor: .separatorColor) }

    /// The ground under code blocks and diffs.
    ///
    /// Opaque, unlike `well`. The system fills are translucent, which was fine
    /// while the pane behind them was a flat colour — but with a background
    /// photo the wallpaper showed straight through the code, and monospace
    /// text over a photograph is unreadable at any blur setting. A block of
    /// code has to sit on something solid.
    static var codeGround: Color { Color(nsColor: .honeycodeCodeGround) }
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
}

/// Account and diff colours, all derived from the system palette so they track
/// appearance changes and match the rest of macOS.
extension Color {
    static var accentPersonal: Color { Color(nsColor: .systemOrange) }
    static var accentWork: Color { Color(nsColor: .systemBlue) }
    static var accentKimi: Color { Color(nsColor: .systemPurple) }
    static var accentCopilot: Color { Color(nsColor: .systemGreen) }

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
