import SwiftUI
import AppKit

/// Everything true about the current session that isn't the conversation.
///
/// The window has always known all of this and has never been able to say it in
/// one place. The account and the folder were in a header that shed them below
/// 520 points; the branch was in a chip beside them that shed at the same
/// width; the plan was a card somewhere up the transcript, so "what is it doing
/// next" meant scrolling to find out; the changed files were a number on a
/// button; and the usage figures were three readouts that appeared and vanished
/// on their own thresholds.
///
/// None of those are conversation. They are the state the conversation is
/// happening in, they change slowly, and they are worth a column that doesn't
/// have to fight the transcript for room. That is the whole argument for a
/// panel down this edge: facts that are true between messages belong somewhere
/// that isn't scrolling.
///
/// Sections are disclosure groups because the answer to "how much of this do
/// you want" is different per person and per day, and because a panel of five
/// open sections is a scroll rather than a summary. Which ones are open is
/// remembered — it is a preference about the app, not about a session.
struct Inspector: View {
    @ObservedObject var session: Session
    @ObservedObject var workspace: Workspace

    @ObservedObject private var repo = RepoStatus.shared
    @ObservedObject private var usage = UsageStore.shared
    @EnvironmentObject private var background: BackgroundStore

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.s5) {
                    WorkspaceSection(session: session, reading: repo.reading(for: session.directory))
                    PlanSection(session: session)
                    ChangedFilesSection(session: session)
                    PortsSection(session: session)
                    UsageSection(session: session, usage: usage)
                    ChecksSection(session: session,
                                  reading: repo.reading(for: session.directory))
                }
                .padding(.horizontal, Theme.s5)
                .padding(.vertical, Theme.s5)
            }
            .scrollContentBackground(.hidden)
        }
        .frame(maxHeight: .infinity)
        .background(background.isGlassy ? AnyShapeStyle(Theme.canvas)
                                        : AnyShapeStyle(.background.secondary))
        .followsRepo(session.directory)
    }

    private var header: some View {
        HStack {
            Text("INSPECTOR")
                .font(Theme.captionStrong)
                .kerning(0.6)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.s5)
        .frame(height: Theme.tabStripHeight)
        .background(alignment: .bottom) {
            Rectangle().fill(Theme.rule).frame(height: 1)
        }
    }
}

// MARK: - A section

/// One collapsible block, and the reason there is a type for it.
///
/// Five sections drawn five ways is how a panel stops reading as a panel. This
/// fixes the header, the chevron, the spacing and — the part that is actually
/// easy to get wrong — where the open/closed state is kept. `@AppStorage` keyed
/// on the section's own name means the panel comes back the way you left it,
/// across sessions and across launches, without any of the five knowing that.
private struct InspectorSection<Content: View>: View {
    let title: String
    let symbol: String
    /// A count, a percentage — whatever this section would want you to know
    /// before deciding to open it.
    var trailing: String?
    @ViewBuilder let content: () -> Content

    @AppStorage private var open: Bool

    init(_ title: String, symbol: String, trailing: String? = nil,
         openByDefault: Bool = true,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.symbol = symbol
        self.trailing = trailing
        self.content = content
        // Slugged, not just lowercased: "Changed files" was producing a
        // defaults key with a space in it, which is legal and horrible to read
        // in `defaults read`.
        let slug = title.lowercased().replacingOccurrences(of: " ", with: "-")
        _open = AppStorage(wrappedValue: openByDefault, "inspector.open.\(slug)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s4) {
            Button {
                withAnimation(Motion.disclose) { open.toggle() }
            } label: {
                HStack(spacing: Theme.s3) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Image(systemName: symbol)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(Theme.title)
                    Spacer(minLength: Theme.s4)
                    if let trailing {
                        Text(trailing)
                            .font(Theme.caption)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(height: 20)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                content()
                    .padding(.leading, Theme.s5)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(Motion.disclose, value: open)
    }
}

/// The line a section shows when it has nothing to show.
///
/// Written as what will put something here, not as "empty". A panel that says
/// "None" five times has told you nothing about what it is for.
private struct Nothing: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Theme.note)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Workspace

private struct WorkspaceSection: View {
    @ObservedObject var session: Session
    let reading: RepoStatus.Reading

    var body: some View {
        InspectorSection("Workspace", symbol: "square.stack.3d.up") {
            VStack(alignment: .leading, spacing: Theme.s4) {
                state
                StatRow(name: "Folder", value: session.directory.lastPathComponent)
                if let slug = reading.slug {
                    StatRow(name: "Repository", value: slug)
                }
                if let branch = reading.branch {
                    StatRow(name: "Branch", value: branch)
                }
                StatRow(name: "Account", value: session.account.shortTitle)
                StatRow(name: "Agent", value: session.account.agentName)
                StatRow(name: "Model", value: session.model.title)
                if session.account.hasEffort {
                    StatRow(name: "Effort", value: session.effort.title)
                }
            }
        }
    }

    /// The state row, which is the one thing here that changes while you watch.
    private var state: some View {
        HStack(spacing: Theme.s3) {
            Circle()
                .fill(session.isRunning ? Theme.stateLive : Theme.rule)
                .frame(width: 6, height: 6)
            Text(session.isRunning ? "Working" : "Idle")
                .font(Theme.rowStrong)
            Spacer(minLength: Theme.s4)
            if session.isolated {
                HStack(spacing: Theme.s2) {
                    Image(systemName: "lock")
                        .font(.system(size: 8.5))
                    Text("fenced")
                        .font(Theme.caption)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, Theme.s3)
                .padding(.vertical, 1)
                .background(Theme.well, in: Capsule())
                .help("This agent cannot read outside "
                      + session.directory.lastPathComponent)
            }
        }
        .animation(Motion.reveal, value: session.isRunning)
    }
}

// MARK: - Plan

/// The agent's own to-do list, out of the transcript.
///
/// It is already drawn in the conversation as a card, and that is the right
/// place for it *when it arrives* — it is something the agent said. What the
/// card cannot do is stay in view: ten minutes and forty tool calls later the
/// plan is a long way up a scroll view, and "what is it doing, and what is
/// left" becomes a hunt. The card in the transcript is the record; this is the
/// current state of the same list.
private struct PlanSection: View {
    @ObservedObject var session: Session

    private var visible: [Todo] { session.todos.filter { $0.status != .deleted } }
    private var done: Int { visible.filter { $0.status == .completed }.count }

    var body: some View {
        InspectorSection("Plan", symbol: "checklist",
                trailing: visible.isEmpty ? nil : "\(done)/\(visible.count)") {
            if visible.isEmpty {
                Nothing("The agent posts its plan here once it starts one.")
            } else {
                VStack(alignment: .leading, spacing: Theme.s3) {
                    ForEach(visible) { todo in
                        row(todo)
                    }
                }
            }
        }
    }

    private func row(_ todo: Todo) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.s3) {
            Image(systemName: symbol(todo.status))
                .font(.system(size: 9.5))
                .foregroundStyle(tint(todo.status))
                .frame(width: 11)
            Text(todo.label)
                .font(Theme.row)
                .foregroundStyle(todo.status == .completed
                                 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                .strikethrough(todo.status == .completed, color: .secondary.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func symbol(_ status: Todo.Status) -> String {
        switch status {
        case .completed:    return "checkmark.circle.fill"
        case .in_progress:  return "circle.dotted"
        default:            return "circle"
        }
    }

    private func tint(_ status: Todo.Status) -> Color {
        switch status {
        case .completed:    return Theme.stateDone
        case .in_progress:  return Theme.stateLive
        default:            return Theme.rule
        }
    }
}

// MARK: - Changed files

private struct ChangedFilesSection: View {
    @ObservedObject var session: Session

    /// Held, not recomputed.
    ///
    /// `Changes.summarise` copies every diff's rows into fresh structs, and
    /// this panel redraws with the session — thirty times a second while a
    /// reply streams. `ChangesTab` had exactly this problem and `Changes`
    /// already carries the answer: a cheap signature to compare every frame,
    /// and the real summary rebuilt only when it moves. The count in the header
    /// comes from `fileCount`, which copies nothing, so a closed section costs
    /// one scan rather than a rebuild.
    @State private var changes: [FileChange] = []

    private func refresh() { changes = Changes.summarise(session.items) }

    var body: some View {
        let count = Changes.fileCount(session.items)
        return InspectorSection("Changed files", symbol: "plusminus",
                                trailing: count == 0 ? nil : "\(count)") {
            if changes.isEmpty {
                Nothing("No files edited in this session yet.")
            } else {
                VStack(alignment: .leading, spacing: Theme.s3) {
                    ForEach(changes) { change in
                        row(change)
                    }
                }
            }
        }
        .onAppear { refresh() }
        .onChange(of: Changes.signature(session.items)) { _, _ in refresh() }
    }

    /// A row that goes somewhere. The tally used to be a badge on a button and
    /// the list behind a modal; a name you can click is the shortest route from
    /// "twelve files changed" to "which twelve".
    private func row(_ change: FileChange) -> some View {
        Button {
            withAnimation(Motion.panel) { session.paneTab = .changes }
        } label: {
            HStack(spacing: Theme.s3) {
                Text(short(change.file))
                    .font(Theme.row)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(.secondary)
                Spacer(minLength: Theme.s3)
                if change.added > 0 {
                    Text("+\(change.added)")
                        .font(Theme.caption)
                        .monospacedDigit()
                        .foregroundStyle(Color.diffAddText)
                }
                if change.removed > 0 {
                    Text("−\(change.removed)")
                        .font(Theme.caption)
                        .monospacedDigit()
                        .foregroundStyle(Color.diffDelText)
                }
            }
            .frame(height: 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(change.file) — show the diff")
    }

    /// The filename, and nothing else.
    ///
    /// This kept the last two path components, on the theory that a bare name
    /// is ambiguous between two directories. In a 268pt column that is a whole
    /// directory name spent before the filename starts, and the head truncation
    /// meant to eat the directory ate the front of the name as well —
    /// `sources/artefacts/client/internal-people-operations/Responsible-AI-…md`
    /// came out as `…nance-update-2026-08-04.md`, which names nothing. The full
    /// path is a hover away, and the row opens the diff.
    private func short(_ path: String) -> String {
        String(path.split(separator: "/").last ?? "")
    }
}

// MARK: - Ports

/// What this session actually has listening.
///
/// The rest of the inspector reports things the agent told us. This one reports
/// something nobody told us: it reads the process table, so it sees a server
/// that was never announced — started detached, in a background shell, or by a
/// tool that logged somewhere we never captured — and it stops showing one that
/// has died. See `Listeners`, which also explains why per-session is the only
/// scope that can be honest without admin.
///
/// Closed by default, like Checks. Most sessions have nothing listening and a
/// section that is empty four days out of five should not be occupying the
/// panel; the count in the header is the whole story when there is one.
private struct PortsSection: View {
    @ObservedObject var session: Session
    @State private var ports: [Listeners.Listener] = []
    @State private var stopping: Listeners.Listener?

    var body: some View {
        InspectorSection("Ports", symbol: "network",
                         trailing: ports.isEmpty ? nil : "\(ports.count)",
                         openByDefault: false) {
            VStack(alignment: .leading, spacing: Theme.s3) {
                if ports.isEmpty {
                    Text("Nothing listening in this folder.")
                        .font(Theme.note)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(ports) { port in
                        row(port)
                    }
                }
            }
            // A full walk of the process table measured 2ms for 792 processes,
            // which is why this can just re-read rather than cache and
            // invalidate. Only while the section is open — a closed one runs
            // nothing at all, the same bargain the Checks section makes.
            .task(id: session.id) { await watch() }
        }
        // Refreshed on the way out of a turn as well, because that is when a
        // server most often appears or dies, and the count in the collapsed
        // header should be right without opening anything.
        .onChange(of: session.isRunning) { _, _ in ports = Listeners.inside(session.directory) }
        .onAppear { ports = Listeners.inside(session.directory) }
    }

    /// Re-read while the section is on screen. Cancelled with the view.
    private func watch() async {
        while !Task.isCancelled {
            let directory = session.directory
            let found = await Task.detached(priority: .utility) {
                Listeners.inside(directory)
            }.value
            if found != ports { ports = found }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private func row(_ port: Listeners.Listener) -> some View {
        HStack(spacing: Theme.s3) {
            // The exposure, as the state palette already reads elsewhere: a
            // server on loopback is fine, one on every interface is a thing
            // somebody should have decided on purpose.
            Circle()
                .fill(port.exposure.isExposed ? Theme.stateHeld : Theme.stateDone)
                .frame(width: Theme.dot, height: Theme.dot)

            // `String(...)`, not `"\(port.port)"`. An interpolated integer in
            // a `Text` makes a `LocalizedStringKey`, which formats it for the
            // locale — and rendered 8731 as "8,731", a port number nobody has
            // ever typed with a comma in it.
            Text(String(port.port))
                .font(Theme.row)
                .monospacedDigit()

            Text(port.process)
                .font(Theme.label)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: Theme.s3)

            if port.exposure.isExposed {
                Text(port.exposure.title)
                    .font(Theme.label)
                    .foregroundStyle(Theme.stateHeld)
            }

            if let url = port.url {
                Button {
                    session.browserURL = url
                    session.browserURLIsManual = true
                    session.paneTab = .preview
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(HoverCapsule())
                .help("Open \(url.absoluteString) in Preview")
            }

            // Two presses, because this ends somebody's process and there is no
            // undo. The second one is the same button saying what it will do,
            // which is cheaper to understand than a dialog and impossible to
            // dismiss by reflex.
            Button {
                if stopping == port {
                    Listeners.stop(port)
                    stopping = nil
                    ports.removeAll { $0.id == port.id }
                } else {
                    stopping = port
                }
            } label: {
                Image(systemName: stopping == port ? "exclamationmark.octagon.fill" : "stop.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(stopping == port
                                     ? AnyShapeStyle(Theme.stateBad)
                                     : AnyShapeStyle(.secondary))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HoverCapsule())
            .help(stopping == port
                  ? "Press again to stop \(port.process) (pid \(port.pid))"
                  : "Stop \(port.process) (pid \(port.pid))")
        }
        .animation(Motion.reveal, value: stopping)
        .help(port.exposure.isExposed
              ? "\(port.address):\(port.port) — bound to every interface, so anything "
                + "on your network can reach it"
              : "\(port.address):\(port.port) — this Mac only")
    }
}

// MARK: - Usage

private struct UsageSection: View {
    @ObservedObject var session: Session
    @ObservedObject var usage: UsageStore

    var body: some View {
        InspectorSection("Usage", symbol: "gauge.with.needle",
                trailing: session.context.map { "\($0.percent)%" }) {
            // Once, inside the closure. As a computed property read three times
            // it was three walks of the transcript per redraw; declared here it
            // is one, and only when the section is open — the closure isn't
            // called at all while it is shut.
            let tally = SessionTally(session)
            VStack(alignment: .leading, spacing: Theme.s4) {
                if let context = session.context, context.window > 0 {
                    // The same view the ring's popover draws — see
                    // `ContextBreakdown`. It was two copies of these lines, and
                    // a bar that stayed accent-blue at a hundred per cent while
                    // the ring above it went red was two readouts of one fact
                    // disagreeing about how bad it is.
                    ContextBreakdown(context: context)
                    Divider().overlay(Theme.rule).padding(.vertical, Theme.s1)
                }

                StatRow(name: "Turns", value: "\(tally.turns)")
                StatRow(name: "Tool calls", value: "\(tally.toolCalls)")
                if let elapsed = tally.elapsed {
                    StatRow(name: "Time", value: elapsed)
                }
                if session.tokensSent > 0 {
                    StatRow(name: "Sent",
                            value: "≈\(SessionTally.compact(session.tokensSent)) tok")
                }
                // Which figure this is depends on how the account bills, and
                // the three accounts genuinely bill in different ways — see
                // `UsageStore.reading`, which is the one ladder deciding it.
                if let reading = usage.reading(for: session.account),
                   let binding = reading.binding {
                    StatRow(name: binding.title, value: "\(binding.percent)%",
                            alarming: binding.pressure.isAlarming)
                } else if session.costUSD > 0 {
                    StatRow(name: "Cost", value: SessionTally.money(session.costUSD))
                }
                if let units = session.aiUnits, units > 0 {
                    StatRow(name: "AI Units",
                            value: units == units.rounded()
                                ? "\(Int(units))" : String(format: "%.2f", units))
                }
            }
        }
    }
}

// MARK: - Checks

/// Whether this session can actually do the things it looks like it can.
///
/// Deliberately not a placeholder. Three facts, each of which this app already
/// knows and each of which explains a specific failure somebody would otherwise
/// meet at the worst moment: a CLI that isn't signed in fails on send, a folder
/// that isn't a work tree makes Changes and Open PR quietly pointless, and a
/// fence you forgot is on is why the agent says it cannot find a file that is
/// plainly there.
private struct ChecksSection: View {
    @ObservedObject var session: Session
    let reading: RepoStatus.Reading

    @State private var readiness: AccountReadiness?

    var body: some View {
        InspectorSection("Checks", symbol: "checkmark.shield", openByDefault: false) {
            VStack(alignment: .leading, spacing: Theme.s3) {
                if let readiness {
                    check(readiness.isReady,
                          "\(session.account.agentName) — \(readiness.summary)",
                          help: readiness.remedy)
                } else {
                    check(nil, "\(session.account.agentName) — checking…", help: nil)
                }

                if Features.isOn(.git) {
                    check(reading.branch != nil,
                          reading.branch == nil ? "Not a git work tree" : "Git work tree",
                          help: reading.branch == nil
                              ? "Changes still lists what the agent edited, but there is "
                                + "no branch to commit them to and no pull request to open."
                              : nil)
                }

                check(!session.isolated,
                      session.isolated
                          ? "Fenced to \(session.directory.lastPathComponent)"
                          : "Reads outside the folder allowed",
                      help: session.isolated
                          ? "The agent cannot open anything above this folder. Turn it "
                            + "off in the ⋯ menu if it needs a file elsewhere."
                          : "The agent can read anywhere you can. Isolate it from the "
                            + "⋯ menu to hold it to this folder.",
                      // Neutral in *both* directions. A fence is a choice, not
                      // a fault — so it isn't red — and not fencing is not an
                      // achievement, so it isn't a green tick either. This row
                      // states a setting; the two above it are the ones that
                      // pass or fail.
                      neutral: true)
            }
        }
        .task(id: session.account.id) {
            readiness = await Task.detached(priority: .utility) { [account = session.account] in
                Diagnostic.readiness(of: account)
            }.value
        }
    }

    private func check(_ passing: Bool?, _ text: String,
                       help: String?, neutral: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.s3) {
            Image(systemName: symbol(passing, neutral: neutral))
                .font(.system(size: 9.5))
                .foregroundStyle(tint(passing, neutral: neutral))
                .frame(width: 11)
            Text(text)
                .font(Theme.row)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .help(help ?? text)
    }

    private func symbol(_ passing: Bool?, neutral: Bool) -> String {
        guard let passing else { return "circle.dotted" }
        if neutral { return "info.circle" }
        return passing ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private func tint(_ passing: Bool?, neutral: Bool) -> Color {
        guard let passing else { return Theme.rule }
        if neutral { return .secondary }
        return passing ? Theme.stateDone : Theme.stateHeld
    }
}
