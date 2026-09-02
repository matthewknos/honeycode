import Foundation

// When an agent next runs, and whether that agrees with the check that fires it.
//
// `AgentSchedule.next(after:from:)` and `AgentStore.due` used to be two pieces
// of calendar arithmetic — the store worked out due-ness inline and the pane
// said nothing about when anything would run. They are one now, and this suite
// exists to keep them that way: every case below asserts the countdown and the
// firing decision against each other, so a change to one that doesn't suit the
// other fails here rather than months later as an agent that says "in 3 minutes"
// forever.

var failures = 0
func check(_ what: String, _ ok: Bool) {
    print(ok ? "  ok   \(what)" : "  FAIL \(what)")
    if !ok { failures += 1 }
}

/// What the store does with the answer. Kept here in the same one line the
/// store uses, so the suite is testing the relationship rather than a copy.
func fires(_ schedule: AgentSchedule, last: Date?, at now: Date) -> Bool {
    guard let next = schedule.next(after: last, from: now) else { return false }
    return next <= now
}

let now = Date(timeIntervalSinceReferenceDate: 800_000_000)  // a fixed moment
let minute = 60.0

// --- nothing a clock decides ------------------------------------------------

print("schedules no clock decides")
check("manual never has a next run",
      AgentSchedule.manual.next(after: nil, from: now) == nil)
check("and never fires on the tick",
      !fires(.manual, last: nil, at: now))
check("watching has no next run either — a file is not a time",
      AgentSchedule.watching(path: "/tmp/x").next(after: now, from: now) == nil)
check("and is not fired by the ticker",
      !fires(.watching(path: "/tmp/x"), last: nil, at: now))

// --- every N minutes --------------------------------------------------------

print("")
print("every 30 minutes")
let every = AgentSchedule.every(minutes: 30)

check("never run means run now",
      every.next(after: nil, from: now) == now)
check("which fires immediately, as a fresh agent always has",
      fires(every, last: nil, at: now))

check("just run means half an hour from then",
      every.next(after: now, from: now) == now.addingTimeInterval(30 * minute))
check("and does not fire",
      !fires(every, last: now, at: now))

let waiting = now.addingTimeInterval(-29 * minute)
check("a minute short is a minute away",
      every.next(after: waiting, from: now) == now.addingTimeInterval(minute))
check("and still doesn't fire",
      !fires(every, last: waiting, at: now))

let ready = now.addingTimeInterval(-30 * minute)
check("exactly due fires",
      fires(every, last: ready, at: now))
check("overdue fires too",
      fires(every, last: now.addingTimeInterval(-90 * minute), at: now))
// And answers *now* rather than the moment it was owed. A pane handed the
// missed slot would draw a countdown that finished an hour ago.
check("an overdue agent is due now, not an hour ago",
      every.next(after: now.addingTimeInterval(-90 * minute), from: now) == now)

// The guard in `next` — a schedule of zero minutes would otherwise be a busy
// loop with a next run of "now" forever. It is clamped to one, which is a
// schedule rather than a spin.
check("a zero-minute schedule is clamped to a minute, not to now",
      AgentSchedule.every(minutes: 0).next(after: now, from: now)
          == now.addingTimeInterval(minute))

// --- daily at h:m -----------------------------------------------------------
//
// The interesting one, and the reason this file exists. Three moments matter:
// before today's slot, after it, and the week-of-missed-mornings case that the
// store's own comment calls out.

print("")
print("daily at 09:00")
let daily = AgentSchedule.daily(hour: 9, minute: 0)
let calendar = Calendar.current

func today(_ hour: Int, _ minute: Int, near moment: Date) -> Date {
    var parts = calendar.dateComponents([.year, .month, .day], from: moment)
    parts.hour = hour
    parts.minute = minute
    return calendar.date(from: parts)!
}

let noon = today(12, 0, near: now)
let eight = today(8, 0, near: now)
let nine = today(9, 0, near: now)

check("at noon, having run at ten, the next is tomorrow morning",
      daily.next(after: today(10, 0, near: now), from: noon)
          == calendar.date(byAdding: .day, value: 1, to: nine))
check("and it does not fire",
      !fires(daily, last: today(10, 0, near: now), at: noon))

check("at noon, having last run yesterday, this morning is owed",
      daily.next(after: calendar.date(byAdding: .day, value: -1, to: noon), from: noon) == noon)
check("so it fires",
      fires(daily, last: calendar.date(byAdding: .day, value: -1, to: noon), at: noon))

check("at eight, having run at seven, nine o'clock is next",
      daily.next(after: today(7, 0, near: now), from: eight) == nine)
check("and nothing fires before it",
      !fires(daily, last: today(7, 0, near: now), at: eight))

// A week away. The old comment promises one run, not seven, and that promise
// is the whole reason `daily` compares against a slot rather than counting.
let weekAgo = calendar.date(byAdding: .day, value: -7, to: now)!
check("a week of missed mornings is owed once, not seven times",
      daily.next(after: weekAgo, from: noon) == noon)
check("which fires",
      fires(daily, last: weekAgo, at: noon))

// A brand-new agent. This is the case the old check got wrong: it asked
// "is the most recent 09:00 after the last run", and with no last run every
// 09:00 qualifies — so an agent made at two in the afternoon and set to Daily
// at 09:00 ran the moment you enabled it, which is the one time it was told
// not to.
check("a new agent made in the afternoon waits for tomorrow morning",
      daily.next(after: nil, from: noon)
          == calendar.date(byAdding: .day, value: 1, to: nine))
check("and does not fire on the way past",
      !fires(daily, last: nil, at: noon))
check("one made before nine waits until nine, today",
      daily.next(after: nil, from: eight) == nine)
check("and doesn't fire before it",
      !fires(daily, last: nil, at: eight))

// The missed-mornings rule is for an agent that *has* been running and
// stopped, which is why it survives the change above.
check("an agent that ran and then stopped is still owed its morning",
      fires(daily, last: weekAgo, at: eight))

// --- the countdown never points backwards -----------------------------------
//
// The property the pane leans on: whatever it is handed, "next run" is now or
// later. A moment in the past would render as a countdown that has already
// finished and never moves.

print("")
print("the answer is never in the past")
for (name, schedule) in [("every 5", AgentSchedule.every(minutes: 5)),
                         ("daily 09:00", .daily(hour: 9, minute: 0))] {
    var ok = true
    for hoursAgo in [0.0, 0.5, 1, 6, 24, 216] as [Double] {
        let last = now.addingTimeInterval(-hoursAgo * 3600)
        guard let next = schedule.next(after: last, from: now) else { continue }
        if next < now { ok = false }
    }
    check("\(name), for any last run", ok)
}

// --- naming a copy -----------------------------------------------------------

print("")
print("duplicating an agent")
check("an unused name is taken as it is",
      AgentStore.copyName(of: "Orbit todos", among: ["Nightly build"]) == "Orbit todos")
check("a taken one is numbered",
      AgentStore.copyName(of: "Orbit todos", among: ["Orbit todos"]) == "Orbit todos 2")
check("and keeps counting",
      AgentStore.copyName(of: "Orbit todos", among: ["Orbit todos", "Orbit todos 2"])
          == "Orbit todos 3")
// Duplicating a duplicate counts from the base, so a column of copies reads
// 2, 3, 4 rather than "Orbit todos 2 2".
check("duplicating a numbered copy counts from the base",
      AgentStore.copyName(of: "Orbit todos 2", among: ["Orbit todos", "Orbit todos 2"])
          == "Orbit todos 3")
check("a name that merely ends in a word is not mistaken for a number",
      AgentStore.copyName(of: "Release notes", among: ["Release notes"])
          == "Release notes 2")

print(failures == 0 ? "Schedule: all ok" : "Schedule: \(failures) failed")
exit(failures == 0 ? 0 : 1)
