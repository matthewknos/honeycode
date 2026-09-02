// What each subscription has left.
//
// The parser is the whole of this suite, and it is worth a suite because of
// what it replaced: two hardcoded Claude sentences, matched by two bespoke
// regexes, with every other vendor's answer read and thrown away. The rings
// draw whatever comes out of here, so a shape they silently fail to match is
// a subscription that reads as having no limits at all — which is the one
// wrong answer that looks exactly like good news.
//
// `UsageStore` itself isn't exercised. It is `@MainActor` and every path
// through it reads or writes `Prefs.store`, which outside the app resolves to
// the real preference domain — so a suite that tested caps and remembered
// readings would be a suite that edited the preferences of whoever ran it.
// Everything with a decision in it is a static function on the value types for
// exactly that reason.

import Foundation

var failures = 0
func check(_ label: String, _ ok: Bool) {
    print((ok ? "  ok   " : "  FAIL ") + label)
    if !ok { failures += 1 }
}

// --- Claude's two lines, which is where this started ---

let claude = """
Current session: 34% used · resets Jul 31 at 4:59pm (Europe/Dublin)
Current week (all models): 69% used · resets Aug 1 at 3:59pm (Europe/Dublin)
"""

if let reading = AccountUsage.read(claude) {
    check("both Claude windows are found", reading.windows.count == 2)
    check("the session percentage is read",
          reading.windows.first?.percent == 34)
    check("the window keeps the agent's own wording",
          reading.windows.first?.title == "Current session")
    check("the reset time survives",
          reading.windows.first?.resets == "Jul 31 at 4:59pm")
    check("the timezone in brackets does not",
          reading.windows.first?.resets?.contains("Europe") == false)
    check("the week is the binding one, not the first one",
          reading.binding?.percent == 69)
    check("a parenthesised qualifier doesn't become a second window",
          reading.windows.last?.title == "Current week (all models)")
    check("and still shortens to one word for a ring",
          reading.windows.last?.short == "week")
    check("a reading off an agent is marked as reported",
          reading.source == .reported)
} else {
    check("Claude's usage is read at all", false)
}

// --- a count rather than a percentage, which is Copilot's shape ---

if let reading = AccountUsage.read("Premium requests: 123 of 300 used this month") {
    check("a count is turned into a percentage",
          reading.windows.first?.percent == 41)
    check("and the count itself is kept for the popover",
          reading.windows.first?.detail == "123 of 300")
    check("a count shortens on the word that means something",
          reading.windows.first?.short == "premium")
} else {
    check("a counted allowance is read", false)
}

check("a thousands separator is not three digits",
      AccountUsage.read("Requests: 1,500 of 3,000")?.windows.first?.percent == 50)
check("a slash means the same as \"of\"",
      AccountUsage.read("Requests: 30/60")?.windows.first?.percent == 50)

// --- the cases that must produce nothing ---
//
// Silence is the correct answer far more often than it looks. An enterprise
// usage-based seat has no percentage anywhere, and a window invented for it
// would draw an empty ring that reads as "plenty left" — the opposite of what
// is known, which is nothing.

check("prose with no allowance in it reports none",
      AccountUsage.read("You're on a usage-based plan. Spend is billed monthly.") == nil)
check("an empty answer reports none", AccountUsage.read("") == nil)
check("a bare percentage with no label is not a window",
      AccountUsage.read("73%") == nil)
check("a zero limit is not divided by",
      AccountUsage.read("Requests: 4 of 0") == nil)

// --- the same window said twice ---
//
// Both passes run over the whole text, so a line carrying a percentage *and* a
// count — "Premium requests: 123 of 300 used (41%)" — matches both. The first
// one wins, which is the stated percentage, because that is the agent's own
// arithmetic rather than ours.

if let reading = AccountUsage.read("Premium requests: 41% used (123 of 300)") {
    check("a line matching both shapes yields one window",
          reading.windows.count == 1)
    check("and it is the percentage the agent stated",
          reading.windows.first?.percent == 41)
} else {
    check("a doubly-matching line is read", false)
}

// --- a percentage over 100 ---
//
// Reported rather than hypothetical: an over-quota seat can answer with more
// than a full window, and a ring drawn from 143 wraps round to look like 43.

check("a percentage past the end is clamped",
      AccountUsage.read("Current session: 143% used")?.windows.first?.percent == 100)

// --- a status command written for a person, not for us ---
//
// The declared probe runs whatever prints an account's limits, which means the
// text arriving here was written to be read in a terminal: a heading, some
// lines that are not limits at all, and — from anything that ignores NO_COLOR
// — escape codes wrapped round the numbers. Every one of those had to survive,
// because the failure mode is silent. A parser that matches nothing draws a
// dash, and a dash reads as "this plan has no limits" rather than as "nobody
// asked properly".

let status = """
Signed in as someone@example.com
Plan: Pro

  5h limit: 21% used · resets 14:32
  Weekly limit: 63% used · resets Mon 09:00

Model: gpt-5.6-codex
"""

if let reading = AccountUsage.read(status) {
    check("a limit indented under a heading is still found",
          reading.windows.count == 2)
    check("and the lines that are not limits are not windows",
          reading.windows.allSatisfy { $0.title.contains("limit") })
    check("the binding window is the tighter one", reading.binding?.percent == 63)
    check("a 5h window shortens to something that fits a ring",
          reading.windows.first?.short == "5h")
} else {
    check("a terminal status block is read", false)
}

let coloured = "5h limit: \u{1B}[32m21%\u{1B}[0m used · resets 14:32"
check("colour codes don't hide the number",
      AccountUsage.read(coloured)?.windows.first?.percent == 21)
check("and don't end up in the window's name",
      AccountUsage.read(coloured)?.windows.first?.title == "5h limit")
check("text with no escapes in it is returned untouched",
      AccountUsage.plain("plain text") == "plain text")

// --- how worried to look ---
//
// The bands are where a *choice* is still available, which is why the top one
// starts at 70 rather than at the 90 the old readouts used. At ninety per cent
// of a five-hour window the decision it would have informed — give this piece
// to a different subscription — is already behind you.

check("nothing to think about below 40", UsagePressure.of(21) == .easy)
check("worth knowing in the middle", UsagePressure.of(52) == .tight)
check("route around it past 70", UsagePressure.of(73) == .critical)
check("the boundary belongs to the band above it", UsagePressure.of(40) == .tight)
check("and so does the top one", UsagePressure.of(70) == .critical)
check("only the top band is said out loud",
      UsagePressure.allCases.filter(\.isAlarming) == [.critical])

// --- what a reading says about itself ---

let measured = AccountUsage(
    windows: [UsageWindow(title: "This month", percent: 8, resets: nil,
                          detail: "$41.00 of $500")],
    source: .measured)
check("a measured reading says it only counts this app",
      measured.summary.contains("Honeycode"))
check("a measured reading still shows the money behind it",
      measured.summary.contains("$41.00 of $500"))
check("an empty reading says so rather than showing 0%",
      AccountUsage().summary == "No usage limits reported for this account")

// --- it survives the round trip to disk ---
//
// The rings read the last known figure out of preferences at launch, so a type
// that encodes but doesn't decode would show an empty row on every cold
// start and fill in a minute later — by which time you have looked once, seen
// nothing, and stopped looking.

if let data = try? JSONEncoder().encode(measured),
   let back = try? JSONDecoder().decode(AccountUsage.self, from: data) {
    // The windows and where they came from, rather than whole-value equality:
    // `measuredAt` is a `Date` through a JSON double, and a suite that fails on
    // the last bit of a float is a suite that gets muted.
    check("the windows survive the round trip", back.windows == measured.windows)
    check("and so does where they came from", back.source == .measured)
} else {
    check("a reading round-trips through JSON", false)
}

print(failures == 0 ? "Usage: all good" : "Usage: \(failures) failed")
exit(failures == 0 ? 0 : 1)
