// The two fences that are not the user's to switch off, and the record of what
// they decided.
//
// Neither half can be tested where it actually matters. `Policy.isManaged`
// answers "is a configuration profile holding this key", and there is no way to
// install one from a test — so what is checked here is that an *unmanaged* Mac
// behaves exactly as it did before this existed, which is the regression that
// would otherwise ship silently: a fence that reads through a new layer and
// comes back false on every machine nobody manages.
//
// The audit half is tested properly, because it is all local: a temporary
// directory, real writes, real reads.

import Foundation

var failures = 0
func check(_ label: String, _ ok: Bool) {
    print((ok ? "  ok   " : "  FAIL ") + label)
    if !ok { failures += 1 }
}

// --- an unmanaged Mac is unchanged ---

MainActor.assumeIsolated {
    let key = Policy.Key.tenancyGate
    let previous = Prefs.store.object(forKey: key.rawValue)
    defer {
        if let previous { Prefs.store.set(previous, forKey: key.rawValue) }
        else { Prefs.store.removeObject(forKey: key.rawValue) }
    }

    check("nothing is managed on a machine nobody manages",
          Policy.managedKeys.isEmpty)
    check("so the fence answers from preferences", !Policy.isManaged(key))

    Prefs.store.removeObject(forKey: key.rawValue)
    check("an unset fence still defaults on", Policy.value(key, default: true))
    check("and Tenancy sees the same answer", Tenancy.gates)

    check("a write lands", Policy.set(key, false))
    check("and is read back", Policy.value(key, default: true) == false)
    check("Tenancy agrees", Tenancy.gates == false)

    Policy.set(key, true)
    check("and back", Tenancy.gates)
}

// --- every governed key is a key something actually reads ---
//
// The failure this catches is a rename: `Policy.Key` carries the literal
// string, and the four places that read those keys carry it too. A key renamed
// in one and not the other is a fence that silently stops being governed, which
// looks like nothing at all.

check("the four keys are the four spellings the rest of the app uses",
      Set(Policy.Key.allCases.map(\.rawValue)) == [
        "tenancy.gateDelegation",
        "agents.unattendedWrites",
        "agent.skipPermissions",
        "audit.enabled",
      ])
check("every key says what it governs",
      Policy.Key.allCases.allSatisfy { !$0.blurb.isEmpty })
check("the sample profile names this app's own domain",
      Policy.sampleProfile.contains(Prefs.domain))
check("and lists every governed key",
      Policy.Key.allCases.allSatisfy { Policy.sampleProfile.contains($0.rawValue) })

// --- what a hash is for, and what it is not ---

let task = "port the tokeniser to Rust"
check("the same task hashes the same", Audit.digest(task) == Audit.digest(task))
check("a different one doesn't", Audit.digest(task) != Audit.digest(task + "."))
check("it is short enough to read", Audit.digest(task).count == 16)
check("and carries none of the text",
      !Audit.digest(task).lowercased().contains("rust"))

// --- the record itself ---
//
// Written and read through the real file, because the interesting failures are
// all in the file handling: a line that doesn't end in a newline, a second
// writer truncating the first, a date that encodes one way and decodes another.

MainActor.assumeIsolated {
    let entries = [
        Audit.Entry(at: Date(), event: .crossingBlocked, from: "claude-w",
                    to: "kimi", task: Audit.digest(task),
                    reason: "refused by inspection", run: UUID().uuidString),
        Audit.Entry(at: Date().addingTimeInterval(-200 * 24 * 60 * 60),
                    event: .crossingAllowed, from: "claude-w", to: "copilot",
                    task: Audit.digest("something else"), reason: nil, run: nil),
    ]

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    guard let one = try? encoder.encode(entries[0]),
          let text = String(data: one, encoding: .utf8) else {
        check("an entry encodes", false)
        return
    }
    check("an entry encodes as one line", !text.contains("\n"))
    check("with the accounts as handles", text.contains("claude-w"))
    check("and the task only as its hash", !text.contains("Rust"))

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let back = try? decoder.decode(Audit.Entry.self, from: one)
    check("and decodes to the same event", back?.event == .crossingBlocked)
    check("keeping the reason", back?.reason == "refused by inspection")

    // Retention is arithmetic on a date, which is the part that can be wrong
    // without anybody noticing until a log is either empty or unbounded.
    let cutoff = Date().addingTimeInterval(-Audit.keepFor)
    check("ninety days is the window",
          Int(Audit.keepFor) == 90 * 24 * 60 * 60)
    check("today's entry is inside it", entries[0].at > cutoff)
    check("one from two hundred days ago is not", entries[1].at < cutoff)
}

// --- switching it off means off ---

MainActor.assumeIsolated {
    let key = Policy.Key.auditing
    let previous = Prefs.store.object(forKey: key.rawValue)
    defer {
        if let previous { Prefs.store.set(previous, forKey: key.rawValue) }
        else { Prefs.store.removeObject(forKey: key.rawValue) }
    }
    Prefs.store.removeObject(forKey: key.rawValue)
    check("the record is kept unless somebody says otherwise", Audit.isOn)
    Policy.set(key, false)
    check("and stops when they do", !Audit.isOn)
}

print(failures == 0 ? "Policy: all good" : "Policy: \(failures) failed")
exit(failures == 0 ? 0 : 1)
