import SwiftUI
import AppKit

/// The bar across the top of every column.
///
/// This replaces `StatusRail`, which was a stack of pills floating in the
/// window's top-right corner when a session had the pane to itself and a
/// different stack of pills in a 60pt gutter when it didn't. Two positions for
/// one control is a control you have to find rather than one you know where to
/// reach for, and the second position wasn't even describing the same thing —
/// it belonged to the *focused* column while sitting outside all of them.
///
/// A header belongs to its column. There is one per conversation, it is always
/// in the same place relative to the transcript underneath it, and it says the
/// four things you would otherwise have to go looking for:
///
/// - **which conversation this is** — the account, the name, the folder, the
///   branch, and whether it is fenced to that folder;
/// - **what it is doing** — running, queued, or idle, with the stop;
/// - **who else is on the message** — the crew chips, which used to be buried
///   inside the composer card;
/// - **what it has spent** — the usage readouts, likewise.
///
/// What it deliberately does *not* carry is which GitHub or Azure identity you
/// are acting as. That was in the old View menu, and it was the wrong place
/// twice over: an identity is not a view, and a per-column control cannot
/// describe an app-wide fact. It lives at the foot of the sidebar now — see
/// `IdentityMenu` — which is where every application on this platform puts the
/// question "who am I signed in as".
struct HeaderBar: View {
    @ObservedObject var session: Session
    @ObservedObject var workspace: Workspace
    /// How much room the bar has, which decides what it can afford to show.
    ///
    /// A width rather than a flag, because the parts do not go together. A
    /// single boolean shed all three at once, so opening the workbench — which
    /// takes five hundred points off the conversation — took the crew chips
    /// away with the usage readouts, and you could no longer change who was on
    /// the message while looking at what they had made. They shed in order of
    /// how little is lost: the usage numbers first (the Crew page has them),
    /// then the folder and branch (the sidebar and the tooltip have them), and
    /// the crew chips last, because nothing else can edit a team.
    var available: CGFloat = 900
    /// Sharing the pane, so this column needs its own close button.
    var columned = false
    /// Whether to reserve the traffic-light band above the bar. False inside
    /// the pop-out window and the mini chat, which have their own chrome.
    var clearsTitlebar = true
    /// A way back out of this pane, when the pane was reached from somewhere
    /// else. Used by the Agents side, whose run view used to float its own
    /// button over the transcript because there was no bar to put it in.
    var onBack: (() -> Void)?

    @EnvironmentObject private var background: BackgroundStore
    @AppStorage("transcript.mode") private var mode = TranscriptMode.normal
    @AppStorage("transcript.terminal") private var terminal = false
    @State private var showingMenu = false

    private var showsUsage: Bool { available >= 640 }
    private var showsLocation: Bool { available >= 520 }
    /// Width, and then whether a crew is a thing in this app at all. The Team
    /// control's only purpose is naming other accounts to run with; with Crew
    /// switched off there is nothing on the other side of it.
    private var showsTeam: Bool { available >= 420 && Features.isOn(.crew) }

    var body: some View {
        HStack(spacing: Theme.s4) {
            leading
                .padding(.horizontal, background.isGlassy ? Theme.s4 : 0)
                .padding(.vertical, background.isGlassy ? Theme.s2 : 0)
                .modifier(StatusSurface(glass: background.isGlassy))

            Spacer(minLength: Theme.s4)

            trailing
                .padding(.horizontal, background.isGlassy ? Theme.s4 : 0)
                .padding(.vertical, background.isGlassy ? Theme.s2 : 0)
                .modifier(StatusSurface(glass: background.isGlassy))
        }
        .frame(height: Theme.headerHeight)
        .padding(.horizontal, Theme.s6)
        .padding(.top, clearsTitlebar ? Chrome.trafficLightClearance - Theme.s6 : Theme.s3)
        .animation(Motion.reveal, value: session.isRunning)
        .animation(Motion.reveal, value: available)
    }

    // MARK: Which conversation, and how it is going

    private var leading: some View {
        HStack(spacing: Theme.s4) {
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

            // Identity is the dot, and only ever the dot. Everything else in
            // this bar that carries colour carries a *state* colour — see
            // `Theme.stateLive` — so the two can never be confused.
            Circle()
                .fill(session.account.accent)
                .frame(width: 7, height: 7)

            Text(session.name)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)

            if session.isolated {
                Image(systemName: "lock")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .help("Fenced to \(session.directory.lastPathComponent) — this agent "
                          + "cannot read outside it")
            }

            if showsLocation { LocationChip(directory: session.directory) }

            if session.isRunning || !session.queued.isEmpty { runChip }
        }
    }

    /// What the agent is doing, where you can see it without looking down at
    /// the composer.
    ///
    /// The composer's send button changes shape while a turn runs and the
    /// sidebar row grows a spinner, and between them that was the whole of it —
    /// so a column you were not typing in reported its state in a 5pt dot two
    /// hundred points away. A crew run makes that worse rather than better:
    /// four columns, four states, four spinners the size of a full stop.
    private var runChip: some View {
        HStack(spacing: Theme.s3) {
            if session.isRunning {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.55)
                    .frame(width: 12, height: 12)
            }
            Text(runLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.stateLive)
                .lineLimit(1)
            if session.isRunning {
                Button { session.interrupt() } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 7.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(HoverCapsule())
                .help("Stop this turn (Esc)")
            }
        }
        .padding(.leading, Theme.s2)
        .transition(.opacity)
    }

    private var runLabel: String {
        let queued = session.queued.count
        if session.isRunning {
            return queued == 0 ? "working" : "working · \(queued) queued"
        }
        return queued == 1 ? "1 queued" : "\(queued) queued"
    }

    // MARK: Who else, what it costs, and where the work is

    private var trailing: some View {
        HStack(spacing: Theme.s4) {
            // Out of the composer card and into the bar.
            //
            // The crew belongs to the *session*, not to the draft — it survives
            // switching away and coming back, which the draft does not — so a
            // control for it inside the message box was describing the wrong
            // scope. It also cost the composer a whole row it could not spare.
            if showsTeam {
                TeamBar(session: session, leader: session.account, inline: true)
            }

            if showsUsage { UsageMeter(session: session) }

            workbenchButton
            menuButton

            if columned {
                Button {
                    withAnimation(Motion.panel) { workspace.closeColumn(session.id) }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(HoverCapsule())
                .help("Close this column (\(Shortcuts.closeColumn.display))")
            }
        }
    }

    /// The workbench toggle, with the one number the window never used to say.
    ///
    /// A run can rewrite a dozen files and, before this, nothing on screen
    /// counted them: the tally lived behind a menu, inside a row, in a modal
    /// sheet you had to already suspect was worth opening. The badge is the
    /// whole fix — see `Changes.fileCount` for why it can afford to be drawn
    /// on every frame.
    private var workbenchButton: some View {
        let changed = Changes.fileCount(session.items)
        return Button {
            withAnimation(Motion.panel) {
                session.browserVisible.toggle()
                if session.browserVisible {
                    // Opening lands on the tab with something in it. A panel
                    // that opens on an empty preview when twelve files are
                    // waiting in the next tab is a panel that taught you it has
                    // nothing to show.
                    session.workbenchTab = openingTab(changed: changed)
                    if session.workbenchTab == .preview, session.browserHTML == nil,
                       session.browserFile == nil {
                        session.browserURL = session.preferredBrowserURL
                    }
                }
            }
        } label: {
            HStack(spacing: Theme.s2) {
                Image(systemName: "sidebar.trailing")
                    .font(.system(size: 11, weight: .medium))
                if changed > 0 {
                    Text("\(changed)")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.stateDone)
                }
            }
            .foregroundStyle(session.browserVisible
                             ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, changed > 0 ? Theme.s3 : 0)
            .frame(minWidth: 24, minHeight: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverCapsule())
        .help(changed == 0
              ? "Workbench — preview, changes, files, the run"
              : "Workbench — \(changed) file\(changed == 1 ? "" : "s") edited")
    }

    /// Which tab the panel opens on.
    ///
    /// Every answer here is checked against the tabs that are actually in the
    /// row. Naming one that isn't lands on `Workbench.shownTab`'s clamp, which
    /// drops you on Changes — so "opening lands on the tab with something in
    /// it" became "opening lands on Changes with nothing in it" for anyone with
    /// Preview switched off. The clamp is right; asking it to catch this was
    /// not. Run is the one exception, and the same one `Workbench.available`
    /// makes: a crew run in flight brings its tab back whatever the switch says.
    private func openingTab(changed: Int) -> WorkbenchTab {
        let available = WorkbenchTab.available
        if session.crewRun != nil { return .run }
        if available.contains(.preview),
           session.browserHTML != nil || session.browserFile != nil
            || session.devServer != nil { return .preview }
        if changed > 0 { return .changes }
        return available.contains(session.workbenchTab) ? session.workbenchTab : .changes
    }

    // MARK: Everything else about this conversation

    /// One overflow menu, holding what is genuinely occasional.
    ///
    /// The old View menu mixed four unrelated kinds of thing: which panel to
    /// show, how the transcript is rendered, where the window is, and who you
    /// are signed in to GitHub as. The first has a button of its own now, the
    /// last has moved to the sidebar, and what is left is a coherent list —
    /// presentation, and the actions that act on this session.
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
                PopoverRow(title: "Open beside",
                           blurb: "A second column, alongside this one") {
                    showingMenu = false
                    workspace.openBeside(session.id)
                }
                .disabled(workspace.columns.count >= Workspace.maxColumns)
                .opacity(workspace.columns.count >= Workspace.maxColumns ? 0.5 : 1)
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

// MARK: - Where the work is

/// The folder and the branch, as one chip.
///
/// The branch is the half that was missing, and it is the half that decides
/// whether a pull request is going to be a surprise. Read off the main thread
/// and only when the directory changes or the app comes back to the front — a
/// `git` invocation per redraw would be a subprocess per streamed token.
private struct LocationChip: View {
    let directory: URL

    @State private var branch: String?

    var body: some View {
        HStack(spacing: Theme.s2 + 1) {
            Text(directory.lastPathComponent)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)

            if let branch, !branch.isEmpty, Features.isOn(.git) {
                Text("·")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.quaternary)
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text(branch)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .layoutPriority(-1)
        .help(directory.path + (branch.map { "\non \($0)" } ?? ""))
        .task(id: directory) { await refresh() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    private func refresh() async {
        // With Git switched off this is the folder's name and nothing else, so
        // don't spend two subprocesses per window activation working out
        // something that will not be drawn.
        guard Features.isOn(.git) else { return branch = nil }
        let directory = directory
        branch = await Task.detached(priority: .utility) {
            guard let root = Git.root(of: directory) else { return nil }
            let name = Git.currentBranch(in: root)
            return name.isEmpty ? nil : name
        }.value
    }
}

// MARK: - What it has spent

/// Context, quota and cost — the three consequences of pressing send.
///
/// These lived on the composer's bottom rail, which was the right instinct
/// (beside the button that spends them) and the wrong place: that rail was
/// already carrying seven concerns, and usage was the first thing it shed
/// whenever the column got narrow — so the readouts disappeared exactly when
/// several agents were running, which is the only time anybody reads them.
///
/// Lifted verbatim otherwise. Which figure is shown still depends on how the
/// account bills, because the three accounts genuinely bill in different ways
/// and one number cannot serve all of them.
struct UsageMeter: View {
    @ObservedObject var session: Session
    @ObservedObject private var usage = UsageStore.shared

    var body: some View {
        HStack(spacing: Theme.s4) {
            // From 60%, when it starts to matter. A permanent "12% ctx" is
            // furniture.
            if let context = session.context, context.percent >= 60 {
                readout("\(context.percent)% ctx",
                        alarming: context.percent >= 90,
                        help: context.summary)
            }

            if let limit = session.rateLimit, limit.isConstrained {
                readout(limit.resetsAt.map { "resets \(RateLimit.clock.string(from: $0))" }
                        ?? limit.windowName,
                        alarming: limit.status == "rejected",
                        help: limit.summary)
            }

            allowance
        }
    }

    /// What this account has left, not what it has spent.
    @ViewBuilder
    private var allowance: some View {
        if !session.account.reportsCost {
            if session.tokensSent > 0 {
                readout("≈\(Self.compact(session.tokensSent)) tok",
                        alarming: false,
                        help: "Roughly \(Self.compact(session.tokensSent)) input tokens "
                            + "sent in this conversation.\nCounted once per turn from the "
                            + "context window, so a turn that ran several tools sent more "
                            + "than this shows.")
            }
            if let units = session.aiUnits, units > 0 {
                readout(units == units.rounded()
                        ? "\(Int(units)) AIC" : String(format: "%.2f AIC", units),
                        alarming: false,
                        help: "AI Units consumed by this conversation")
            }
        } else if let account = usage.usage[session.account], let binding = account.binding {
            readout("\(binding.percent)% \(binding.label)",
                    alarming: binding.percent >= 90,
                    help: account.summary)
        } else if let cap = usage.capUsage(session.account) {
            readout("\(cap.percent)% month",
                    alarming: cap.percent >= 90,
                    help: String(format: "$%.2f of $%.0f this month.", cap.spent, cap.cap)
                        + "\nCounts turns run in Honeycode only.")
        } else if session.costUSD > 0 {
            readout(String(format: "$%.3f", session.costUSD),
                    alarming: false, help: "Session cost so far")
        }
    }

    private func readout(_ text: String, alarming: Bool, help: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(alarming ? AnyShapeStyle(Theme.stateBad)
                                      : AnyShapeStyle(.tertiary))
            .help(help)
    }

    /// 28,400 → "28k", 1,240,000 → "1.2M". A token count is an order of
    /// magnitude, not a figure you'd reconcile.
    static func compact(_ count: Int) -> String {
        switch count {
        case 1_000_000...:
            return String(format: "%.1fM", Double(count) / 1_000_000)
        case 1_000...:
            return "\(Int((Double(count) / 1_000).rounded()))k"
        default:
            return "\(count)"
        }
    }
}
