import SwiftUI
import AppKit

/// One line along the foot of the window, saying where you are and what it is
/// doing.
///
/// The case for it is the case against the old `HeaderBar`, which said all of
/// this and had to shed most of it whenever the column narrowed — see the
/// `showsUsage` / `showsLocation` / `showsTeam` ladder it grew. Those readouts
/// disappeared at exactly the width where several things were running at once,
/// which is the only time anybody reads them.
///
/// A strip along the bottom has no such problem: it is as wide as the window,
/// it never competes with the conversation for room, and it is in the one place
/// on screen your eye is not using. So the facts that were being shed live here
/// permanently, and the header above the transcript is free to be short.
///
/// Everything in it describes the *focused* session, which is the same session
/// the title bar's breadcrumb and the inspector describe. One window, one
/// current conversation, three surfaces agreeing about it.
struct StatusBar: View {
    @ObservedObject var workspace: Workspace
    /// What the pane is showing, when it isn't a conversation — Settings, Crew
    /// or Agents. Nil means the pane is on a session and this strip describes
    /// it.
    ///
    /// The inspector already makes this test and hides itself; the strip was
    /// left describing whichever session happened to be selected, so the foot
    /// of the Agents pane said "Claude Code · Opus 5 · 13% ctx" beside an agent
    /// configured with its own account and model. One line of small type
    /// confidently describing the wrong thing is worse than a blank one.
    var elsewhere: String?
    @ObservedObject private var repo = RepoStatus.shared
    @ObservedObject private var usage = UsageStore.shared

    private var session: Session? { elsewhere == nil ? workspace.selected : nil }

    var body: some View {
        HStack(spacing: 0) {
            if let session {
                leading(session)
                Spacer(minLength: Theme.s5)
                trailing(session)
            } else {
                Text(elsewhere ?? "No session")
                    .font(Theme.caption)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, Theme.s5)
        .frame(height: Theme.statusBarHeight)
        .background(alignment: .top) {
            Rectangle().fill(Theme.rule).frame(height: 1)
        }
        .animation(Motion.reveal, value: session?.isRunning)
    }

    // MARK: Where the work is

    private func leading(_ session: Session) -> some View {
        HStack(spacing: Theme.s4) {
            HStack(spacing: Theme.s3) {
                Circle()
                    .fill(stateColour(session))
                    .frame(width: 5, height: 5)
                Text(stateLabel(session))
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            }
            .help(session.isRunning ? "The agent is working — Esc stops it" : "Idle")

            separator

            item("folder", session.directory.lastPathComponent, help: session.subtitle)

            if let branch = repo.reading(for: session.directory).branch {
                separator
                item("arrow.triangle.branch", branch, help: "On branch \(branch)")
            }

            changed(session)
        }
        // The status strip is the only thing that names the branch when the
        // inspector is closed, so it is the strip's job to keep it current.
        .followsRepo(session.directory)
    }

    /// How many files this session has edited — and a way to look at them.
    ///
    /// A count with nowhere to go is a count you have to act on somewhere else,
    /// which for the whole life of the old modal sheet is exactly what it was.
    /// Clicking lands on the Changes tab, which is where you were going anyway.
    @ViewBuilder
    private func changed(_ session: Session) -> some View {
        let count = Changes.fileCount(session.items)
        separator
        Button {
            withAnimation(Motion.panel) { session.paneTab = .changes }
        } label: {
            HStack(spacing: Theme.s2) {
                Image(systemName: "plusminus")
                    .font(.system(size: 8.5))
                Text(count == 1 ? "1 changed" : "\(count) changed")
                    .font(Theme.caption)
                    .monospacedDigit()
            }
            .foregroundStyle(count > 0 ? AnyShapeStyle(Theme.stateDone)
                                       : AnyShapeStyle(.secondary))
            .padding(.horizontal, Theme.s2)
            .frame(height: 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverCapsule())
        .disabled(count == 0)
        .help(count == 0 ? "Nothing edited in this session yet"
                         : "Show what this session has edited")
        .animation(Motion.reveal, value: count)
    }

    // MARK: What it is running on

    private func trailing(_ session: Session) -> some View {
        HStack(spacing: Theme.s4) {
            item(nil, session.account.agentName, help: session.account.title)
            separator
            Text(session.model.title)
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(session.model.blurb)

            // No context percentage. `ContextRing` in the title bar draws the
            // same number permanently, tinted, and opens the breakdown — so a
            // second copy down here was one fact in two places, differing only
            // in that this one couldn't be clicked.

            // What the account has left, on the ladder `UsageStore.reading`
            // defines — reported first, measured second, nothing third. Only
            // the accounts that report one; the rest say nothing rather than
            // saying zero.
            if let reading = usage.reading(for: session.account),
               let binding = reading.binding {
                separator
                Text("\(binding.percent)% \(binding.short)")
                    .font(Theme.caption)
                    .monospacedDigit()
                    .foregroundStyle(binding.pressure.isAlarming
                                     ? AnyShapeStyle(Theme.stateHeld)
                                     : AnyShapeStyle(.secondary))
                    .help(reading.summary)
            }
        }
        .layoutPriority(-1)
    }

    // MARK: Pieces

    @ViewBuilder
    private func item(_ symbol: String?, _ text: String, help: String) -> some View {
        HStack(spacing: Theme.s2) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
            }
            Text(text)
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help(help)
    }

    private var separator: some View {
        Text("·")
            .font(Theme.caption)
            .foregroundStyle(.quaternary)
    }

    private func stateColour(_ session: Session) -> Color {
        if session.isRunning { return Theme.stateLive }
        if !session.queued.isEmpty { return Theme.stateHeld }
        if session.needsAttention { return session.account.accent }
        return Theme.rule
    }

    private func stateLabel(_ session: Session) -> String {
        if session.isRunning {
            return session.queued.isEmpty ? "Working" : "Working · \(session.queued.count) queued"
        }
        if !session.queued.isEmpty {
            return session.queued.count == 1 ? "1 queued" : "\(session.queued.count) queued"
        }
        return session.needsAttention ? "Replied" : "Idle"
    }
}
