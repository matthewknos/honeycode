// What a fresh Mac starts with, and what a used one is spared.
//
// Two things here are worth checking and neither is obvious from reading the
// code. The first is that seeding is *one-way*: it writes an answer where
// there isn't one and never overwrites one there is, because the alternative
// is an app that quietly reconsiders your settings every time it launches.
// The second is the returning-install path — an existing roster means setup is
// marked done without being shown, and marked done without seeding, so nothing
// somebody has been using for months silently loses a feature because the tool
// behind it moved.
//
// It runs against a scratch preferences domain rather than the app's own. The
// logic under test writes to `Setup.store`, and `Setup.store` is by default the
// domain the Honeycode you are using right now reads — a suite that proved
// switches work by turning yours off would be a poor trade.

import Foundation

var failures = 0
func check(_ label: String, _ ok: Bool) {
    print((ok ? "  ok   " : "  FAIL ") + label)
    if !ok { failures += 1 }
}

let domain = "com.matthewquigley.honeycode.tests"
let scratch = UserDefaults(suiteName: domain)!
scratch.removePersistentDomain(forName: domain)
Setup.store = scratch
defer { scratch.removePersistentDomain(forName: domain) }

// --- a fresh install ---

check("a fresh install needs setup", Setup.needsRun)
check("and has not run it", !Setup.hasRun)

Setup.prepare(returning: false)

check("still needs to be shown the flow after preparing", Setup.needsRun)
check("every feature has a decided value", Feature.allCases.allSatisfy {
    scratch.object(forKey: Setup.featureKey($0)) != nil
})
check("every account has a decided value", Account.allCases.allSatisfy {
    scratch.object(forKey: Setup.accountKey($0)) != nil
})

// Notifications are the one feature that starts off whatever the machine
// looks like: switching them on is what raises the system's permission
// dialog, and that belongs to a moment somebody asked for it.
check("notifications start off", !Features.isOn(.notifications))
check("a feature with no tool behind it starts on", Features.isOn(.crew))
check("a feature's initial value follows its tool",
      Features.isOn(.azure) == Feature.azure.isAvailable)

// --- seeding never overwrites ---

Features.set(.crew, false)
Account.setEnabled(false, for: .kimi)
Setup.seedDefaults()
check("seeding leaves a feature you have set alone", !Features.isOn(.crew))
check("seeding leaves an account you have set alone", !Account.kimi.isEnabled)
check("a switched-off account is not offered",
      !Account.enabled.contains(.kimi))
check("a switched-off account still exists",
      Account.allCases.contains(.kimi))

// --- completing ---

Setup.complete()
check("completing settles it", !Setup.needsRun && Setup.hasRun)
check("and the choices survive it", !Features.isOn(.crew))

Setup.rerun()
check("rerun asks again", Setup.needsRun)
check("rerun keeps the choices", !Features.isOn(.crew))

// --- a machine that was already in use ---

Setup.forgetEverything()
check("forgetting clears the switches too", Feature.allCases.allSatisfy {
    scratch.object(forKey: Setup.featureKey($0)) == nil
})

Setup.prepare(returning: true)
check("a returning install is never shown the flow", !Setup.needsRun)
// The important half: nothing was written, so every switch falls back to on
// and the app is exactly the app they had yesterday.
check("a returning install decides nothing for you", Feature.allCases.allSatisfy {
    scratch.object(forKey: Setup.featureKey($0)) == nil
})
check("and everything stays on", Feature.allCases.allSatisfy(Features.isOn))
check("including notifications, which they already had",
      Features.isOn(.notifications))
check("and every account stays offered",
      Account.enabled.count == Account.allCases.count)

// --- the tabs and halves that hang off these ---

Features.set(.crew, false)
Features.set(.preview, false)
check("a workbench tab whose feature is off is not offered",
      !WorkbenchTab.available.contains(.run)
          && !WorkbenchTab.available.contains(.preview))
check("the two that depend on nothing are always offered",
      WorkbenchTab.available.contains(.changes)
          && WorkbenchTab.available.contains(.files))

print(failures == 0 ? "Setup: all ok" : "Setup: \(failures) failed")
exit(failures == 0 ? 0 : 1)
