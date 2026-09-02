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
check("a pane tab whose feature is off is not offered",
      !PaneTab.available.contains(.run)
          && !PaneTab.available.contains(.preview))
// Files has no switch of its own but goes with Preview anyway, because
// opening a file in Preview is the only thing a row in it does. On its own it
// listed a directory in which every row silently landed you on Changes.
check("and Files goes with Preview, having nowhere else to open a file",
      !PaneTab.available.contains(.files))
check("the ones that depend on nothing are always offered",
      PaneTab.available.contains(.changes) && PaneTab.available.contains(.agent))

Features.set(.preview, true)
check("and Files comes back with it",
      PaneTab.available.contains(.files))
Features.set(.preview, false)

// --- a default that is off rather than detected ---
//
// Every other default answers "is the tool here". Notifications answer "should
// the system's permission dialog be raised before anybody asked for it", which
// nothing on disk can be consulted about — so it is written down, and it is now
// the only default that would silently stop being checked if somebody folded it
// back into `isAvailable`.

check("notifications are a window feature, not a tool",
      Feature.notifications.group == .window)
check("and they start off", Feature.notifications.initialValue == false)

check("a fresh install writes that decision down", {
    let fresh = "com.matthewquigley.honeycode.tests.notifications"
    let store = UserDefaults(suiteName: fresh)!
    store.removePersistentDomain(forName: fresh)
    let previous = Setup.store
    Setup.store = store
    defer { Setup.store = previous; store.removePersistentDomain(forName: fresh) }
    Setup.seedDefaults()
    return store.object(forKey: Setup.featureKey(.notifications)) as? Bool == false
}())

print(failures == 0 ? "Setup: all ok" : "Setup: \(failures) failed")
exit(failures == 0 ? 0 : 1)
