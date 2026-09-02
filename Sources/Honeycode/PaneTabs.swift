import SwiftUI
import AppKit

/// The strip across the top of the pane: which of this session's five faces
/// you are looking at.
///
/// This is the tab row that used to live *inside* the workbench, moved up one
/// level and given a fifth tab. Both halves of that matter. Inside the panel it
/// could only be read once the panel was already open, which made it a
/// navigation control you had to navigate to; and it could not name the
/// conversation, because the conversation was the thing on the other side of
/// the panel's edge. A row whose whole job is saying where you are, that cannot
/// say where you are half the time, is decoration.
///
/// So the conversation is `PaneTab.agent`, the strip is always up, and the
/// split — the arrangement this app already had, transcript and artefact side
/// by side — becomes one toggle at the end of the row instead of the implicit
/// meaning of a panel being open.
struct PaneTabs: View {
    @ObservedObject var session: Session
    @ObservedObject var workspace: Workspace
    @Binding var openingPullRequest: Bool
    /// How much room the strip has, which decides what it can afford to spell
    /// out. The same measurement discipline the old header used, for the same
    /// reason: things shed in a chosen order or they get pushed off the edge.
    var available: CGFloat = 900
    /// A way back out of this pane, when it was reached from somewhere other
    /// than the session list. The Agents side passes one.
    var onBack: (() -> Void)?

    @State private var showingMenu = false
    @AppStorage("transcript.mode") private var mode = TranscriptMode.normal
    @AppStorage("transcript.terminal") private var terminal = false

    /// Labels go first, then the session's name, then Open PR. The tabs
    /// themselves never shed — they are the navigation, and an unlabelled row
    /// of five glyphs is exactly how the browser and the changes list stayed
    /// undiscovered when this was inside the panel.
    private var labelled: Bool { available >= 620 }
    private var showsName: Bool { available >= 560 }
    private var showsPullRequest: Bool { available >= 820 && Features.isOn(.gitHub) }
    /// The one control here that sheds *last*, because nothing else can edit a
    /// team — the same rule the old header bar made, and for the same reason.
    /// Below this the name goes first, then Open PR, and the chips stay.
    private var showsTeam: Bool { available >= 440 && Features.isOn(.crew) }

    /// The tabs this session is offering.
    ///
    /// `PaneTab.available` plus one exception: a crew run that is actually in
    /// flight brings Run back even with Crew switched off. The switch hides the
    /// Team control; it does not refuse a message naming three accounts, and a
    /// run nobody can watch is a worse outcome than a tab nobody asked for.
    private var tabs: [PaneTab] {
        var out = PaneTab.available
        if session.crewRun != nil, !out.contains(.run) { out.append(.run) }
        return out
    }

    var body: some View {
        HStack(spacing: Theme.s2) {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(HoverCapsule())
                .help("Back")
            }

            ForEach(tabs) { tab in
                tabButton(tab)
            }

            Spacer(minLength: Theme.s4)

            trailing
        }
        .padding(.horizontal, Theme.s5)
        .frame(height: Theme.tabStripHeight)
        .background(alignment: .bottom) {
            Rectangle().fill(Theme.rule).frame(height: 1)
        }
        // On the shed decisions, not on the width. `available` changes on
        // every frame of a live resize, and animating that started a fresh
        // curve sixty times a second for a row whose layout only moves at four
        // thresholds.
        .animation(Motion.reveal, value: labelled)
        // A tab whose feature was switched off since it was last open has no
        // button in this row, so leaving the pane on it would be a view you
        // cannot navigate out of.
        .onChange(of: tabs) { _, current in
            if !current.contains(session.paneTab) { session.paneTab = .agent }
        }
    }

    // MARK: The tabs

    private func tabButton(_ tab: PaneTab) -> some View {
        let on = session.paneTab == tab
        let badge = self.badge(for: tab)
        return Button {
            withAnimation(Motion.hover) { session.paneTab = tab }
        } label: {
            HStack(spacing: Theme.s2) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 10.5, weight: .medium))
                if labelled {
                    Text(tab.title)
                        .font(Theme.label)
                }
                if let badge {
                    Text(badge)
                        .font(.system(size: Theme.t1, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(tab == .run ? Theme.stateLive : Theme.stateDone)
                }
            }
            .foregroundStyle(on ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, Theme.s4)
            .frame(height: 24)
            .background(on ? Theme.surface : .clear,
                        in: RoundedRectangle(cornerRadius: Theme.cornerChip))
            // The same "slightly raised" the sidebar's segmented pill uses, so
            // the two rows of tabs in this window read as the same control.
            .shadow(color: on ? Theme.shadowLow.colour : .clear,
                    radius: Theme.shadowLow.radius, y: Theme.shadowLow.y)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help(for: tab))
    }

    /// Counts, where a count is the thing you would have gone looking for.
    private func badge(for tab: PaneTab) -> String? {
        switch tab {
        case .changes:
            let count = Changes.fileCount(session.items)
            return count == 0 ? nil : "\(count)"
        case .run:
            guard let run = session.crewRun, run.isBusy else { return nil }
            let live = run.members.filter { $0.state == .working || $0.state == .answering }
            return live.isEmpty ? nil : "\(live.count)"
        case .agent:
            let queued = session.queued.count
            return queued == 0 ? nil : "\(queued)"
        default:
            return nil
        }
    }

    private func help(for tab: PaneTab) -> String {
        switch tab {
        case .agent:   return "The conversation"
        case .preview: return "The page, the dev server, or a rendered artifact"
        case .changes: return "Every file this session has edited"
        case .files:   return "The working directory as it stands now"
        case .run:     return "The crew, while it is running"
        }
    }

    // MARK: What this conversation is

    private var trailing: some View {
        // One scan, not two. `badge(for:)` already asks this of every redraw;
        // asking again for the Open PR test was doubling it for nothing.
        let changed = Changes.fileCount(session.items)
        return HStack(spacing: Theme.s3) {
            // Who else is on the message.
            //
            // This is the whole idea of the application — name several accounts
            // and the first one leads — so it is on screen wherever the
            // conversation is, and it is the last thing this row gives up. It
            // moved here from the header bar the strip replaced; before that it
            // was a row inside the composer card, which described the wrong
            // scope (a team belongs to the session, not to the draft) and cost
            // the composer a line it could not spare.
            if showsTeam {
                TeamBar(session: session, leader: session.account, inline: true)
                Divider().frame(height: 14).overlay(Theme.rule)
            }

            if showsName { name }

            if showsPullRequest, changed > 0 {
                Button { openingPullRequest = true } label: {
                    HStack(spacing: Theme.s2) {
                        Image(systemName: "arrow.up.forward")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Open PR")
                            .font(Theme.label)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Theme.s4)
                    .frame(height: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(HoverCapsule())
                .help("Branch, commit and open a pull request for what this session edited")
                .transition(.opacity)
            }

            splitButton
            menuButton
        }
        .animation(Motion.reveal, value: showsPullRequest)
        .animation(Motion.reveal, value: showsTeam)
        .animation(Motion.reveal, value: showsName)
    }

    /// Which conversation this is.
    ///
    /// The pane needs to say it somewhere: the title bar's breadcrumb names the
    /// account and the folder, which is what you need to know before you send a
    /// message, and the sidebar names the session — but the sidebar can be
    /// collapsed, and then nothing on screen distinguished two sessions in the
    /// same folder on the same account.
    private var name: some View {
        HStack(spacing: Theme.s2) {
            if session.isolated {
                Image(systemName: "lock")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            Text(session.name)
                .font(Theme.note)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .layoutPriority(-1)
        .help(session.isolated
              ? "\(session.name)\nFenced to \(session.directory.lastPathComponent) — "
                + "this agent cannot read outside it"
              : session.name)
    }

    /// Keep the conversation beside the artefact, or give the artefact the pane.
    ///
    /// Disabled on the Agent tab and deliberately not hidden: a control that
    /// vanishes on four of five tabs is one you stop looking for. On Agent
    /// there is nothing to split *from*, which the tooltip says.
    private var splitButton: some View {
        Button {
            withAnimation(Motion.panel) { session.splitOpen.toggle() }
        } label: {
            Image(systemName: session.splitOpen
                  ? "rectangle.righthalf.inset.filled" : "rectangle")
                .font(.system(size: 11.5))
                .foregroundStyle(session.paneTab.isAgent
                                 ? AnyShapeStyle(.quaternary)
                                 : (session.splitOpen ? AnyShapeStyle(.primary)
                                                      : AnyShapeStyle(.secondary)))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverCapsule())
        .disabled(session.paneTab.isAgent)
        .help(session.paneTab.isAgent
              ? "Split — keeps the conversation beside a tab that isn't the conversation"
              : (session.splitOpen ? "Give this tab the whole pane"
                                   : "Bring the conversation back beside it"))
    }

    // MARK: Everything else about this conversation

    /// One overflow menu, holding what is genuinely occasional.
    ///
    /// Lifted from `HeaderBar` unchanged apart from what has moved out from
    /// under it: Open Beside is gone with the columns, and the workbench toggle
    /// it used to sit beside is now the tab strip this menu hangs off the end of.
    private var menuButton: some View {
        Button { showingMenu.toggle() } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverCapsule())
        .help("This conversation")
        .popover(isPresented: $showingMenu, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                PopoverHeader("Presentation")
                PopoverRow(title: "Coding mode",
                           blurb: "A terminal instead of cards. "
                               + Shortcuts.codingMode.display,
                           selected: terminal) {
                    terminal.toggle()
                    showingMenu = false
                }
                ForEach(TranscriptMode.allCases) { option in
                    PopoverRow(title: option.title, blurb: option.blurb,
                               selected: mode == option) {
                        mode = option
                        showingMenu = false
                    }
                }

                Divider().overlay(Theme.rule).padding(.vertical, Theme.s2)
                PopoverHeader("This session")
                PopoverRow(title: workspace.poppedOut == session.id
                               ? "Bring back from pop-out" : "Pop out",
                           blurb: "A small window that stays above other apps",
                           selected: workspace.poppedOut == session.id) {
                    showingMenu = false
                    if workspace.poppedOut == session.id {
                        workspace.popIn()
                    } else {
                        workspace.popOut(session.id)
                    }
                }
                PopoverRow(title: "Rename") {
                    showingMenu = false
                    workspace.renaming = session.id
                }
                PopoverRow(title: session.isolated
                               ? "Stop isolating" : "Isolate to this folder",
                           blurb: "An isolated agent cannot read outside "
                               + session.directory.lastPathComponent,
                           selected: session.isolated) {
                    session.isolated.toggle()
                    showingMenu = false
                }
                PopoverRow(title: "Reveal in Finder") {
                    showingMenu = false
                    NSWorkspace.shared.activateFileViewerSelecting([session.directory])
                }

                Divider().overlay(Theme.rule).padding(.vertical, Theme.s2)
                PopoverRow(title: "Delete session…", destructive: true) {
                    showingMenu = false
                    workspace.requestDelete(session)
                }
            }
            .padding(.vertical, Theme.s3)
            .frame(width: 268)
        }
    }
}
