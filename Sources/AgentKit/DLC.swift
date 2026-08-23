import Foundation

// MARK: - The bundles that change what this is for

/// A switch that changes what Honeycode *is*, rather than what it has.
///
/// `Feature` covers the latter and is deliberately flat: one switch, one
/// control, "switching one off takes its controls with it". That shape is right
/// for "do you have `gh` installed". It is wrong for a bundle — a sidebar mode,
/// a pane, a set of skills and a folder of your own files that arrive and leave
/// together and turn the window into a tool for a particular kind of work.
///
/// Four things make a DLC not simply more `Feature` cases:
///
/// - It owns **several** extension points at once, so it has to be one unit
///   that installs and uninstalls rather than four booleans somebody can get
///   into an inconsistent state.
/// - It carries **content** — skills, a harness prompt — not just visibility.
/// - It has **state on disk** that must survive being switched off. `Feature`'s
///   rule is "it doesn't delete anything"; a DLC has much more not to delete,
///   and here that is a folder of papers somebody spent a year collecting.
/// - Most of the app must not know DLCs exist. If `RootView` grew
///   `if DLCs.isOn(.academia)` in five places this would have failed. It
///   doesn't: `SidebarMode` carries a `dlc:` the way it already carries a
///   `feature:`, and the filter that was already there does the rest.
///
/// **In the binary, not installed.** "DLC" is the name for what the switch does
/// to the app, not for where the code came from. Everything a DLC contributes
/// is compiled in and revealed; the only thing that actually *installs* is its
/// skills, which are files, and which are what a DLC has to write somewhere the
/// agents can read. Making this a loadable bundle would mean a plugin loader, a
/// signing story and a versioning story, none of which is the interesting part
/// of Academia and all of which can be added later without a call site moving.
enum DLC: String, CaseIterable, Identifiable, Sendable {
    /// Read papers, mark them up, ask about what you marked, and write your own
    /// — the last of those in Word, because that is what journals and
    /// co-authors take.
    case academia

    var id: String { rawValue }

    var title: String {
        switch self {
        case .academia: return "Academia"
        }
    }

    var symbol: String {
        switch self {
        case .academia: return "books.vertical"
        }
    }

    /// One line, in the voice the rest of the app uses: what it puts on screen.
    var blurb: String {
        switch self {
        case .academia:
            return "A library beside your sessions. Read papers in the window, "
                 + "highlight a passage and ask an agent about it, and keep the "
                 + "ones you are writing — as Word documents — in the same place."
        }
    }

    /// What it says about itself once it is on and there is a folder behind it.
    var settingsBlurb: String {
        switch self {
        case .academia:
            return "Papers and highlights live in Application Support and are "
                 + "left alone when this is switched off. Nothing here deletes a "
                 + "document you added."
        }
    }

    /// Off. A DLC is never something somebody has without having asked: it
    /// replaces what the app is for, and an app that arrives already convinced
    /// you are writing a paper is the first-run problem `Setup` exists to fix.
    var initialValue: Bool { false }

    /// The skills this installs into `Skills.folder` when it is switched on.
    ///
    /// Skills rather than a prompt appended somewhere, because `Skills` is the
    /// one instruction channel that works identically on all four accounts —
    /// Kimi and Copilot have no skills mechanism of their own and would
    /// otherwise be second-class at the thing this DLC is for.
    var skills: [Skill] {
        switch self {
        case .academia: return Academia.skills
        }
    }
}

/// Which DLCs are on.
///
/// The same shape as `Features`, and read the same way — a plain boolean, from
/// `body`, several times a frame. The one difference is the default: an unset
/// `Feature` means an install that predates the switches and stays on; an unset
/// DLC means nobody has ever asked for it.
enum DLCs {

    static func isOn(_ dlc: DLC) -> Bool {
        Setup.store.object(forKey: Setup.dlcKey(dlc)) as? Bool ?? dlc.initialValue
    }

    /// Switching one on writes its skills out; switching it off leaves both the
    /// skills and everything they were for exactly where they are.
    ///
    /// Deliberately asymmetric. Removing a skill on the way out would delete a
    /// file somebody may have edited — they are plain Markdown in a folder, and
    /// editing them is the point — and a switch that eats your edits is a switch
    /// you only flick once.
    static func set(_ dlc: DLC, _ on: Bool) {
        Setup.store.set(on, forKey: Setup.dlcKey(dlc))
        if on { install(dlc) }
    }

    /// Every DLC and its state, for the settings pane.
    static var all: [(DLC, Bool)] { DLC.allCases.map { ($0, isOn($0)) } }

    /// Write out any of this DLC's skills that aren't there yet, and switch
    /// them on — a skill nobody enabled reaches no agent, and a DLC whose
    /// instructions never arrive is a DLC that half worked.
    ///
    /// Never overwrites. A skill is a file you are meant to edit — that is most
    /// of why they are files — so a second switch-on restores what you deleted
    /// and leaves alone what you changed. It is deliberately not the reverse of
    /// switching off: deleting these on the way out would eat those edits, and
    /// a switch that does that is one you only ever flick once.
    static func install(_ dlc: DLC) {
        var active = Skills.enabled
        for skill in dlc.skills {
            if !FileManager.default.fileExists(atPath: skill.file.path) {
                Skills.write(skill)
                active.insert(skill.slug)
            }
        }
        Skills.enabled = active
    }
}

extension Setup {
    /// The key spelling, in the one place `Feature`'s lives.
    static func dlcKey(_ dlc: DLC) -> String { "dlc." + dlc.rawValue }
}
