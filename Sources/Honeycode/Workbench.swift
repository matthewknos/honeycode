import SwiftUI
import AppKit

/// The work, beside the conversation about the work.
///
/// One panel down the trailing edge with four tabs, in place of four surfaces
/// that each arrived by a different route and none of which could be on screen
/// at the same time as another:
///
/// - the **browser** was a panel that split the column, and had to grow a
///   full-width mode with a floating chat over it because there was nowhere
///   else for a wide page to go;
/// - **changes** was a 720×560 modal sheet, so reviewing what an agent wrote
///   meant hiding the agent;
/// - **a pull request** was a second modal sheet nested inside that one;
/// - a **crew run** was a block wedged between the transcript and the composer
///   that pushed both around once a second and vanished when the run ended.
///
/// They are all the same kind of thing — the artefact rather than the dialogue
/// — so they share one place, one width, one resizer and one close. Which one
/// you are looking at is a tab, which is a decision you can change in one click
/// instead of a modal you have to dismiss.
///
/// The panel is per-session, because everything in it is: the dev server
/// belongs to a session, so do the edits, the working directory and the run.
struct Workbench: View {
    @ObservedObject var session: Session
    @ObservedObject var workspace: Workspace

    @State private var openingPullRequest = false

    var body: some View {
        VStack(spacing: 0) {
            tabs
            Divider().overlay(Theme.rule)

            Group {
                switch session.workbenchTab {
                case .preview:
                    BrowserPanel(session: session, workspace: workspace, embedded: true)
                case .changes:
                    ChangesTab(session: session, openingPullRequest: $openingPullRequest)
                case .files:
                    FilesTab(session: session)
                case .run:
                    RunTab(session: session)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.canvas)
        .sheet(isPresented: $openingPullRequest) {
            // Still a sheet, and the one thing in here that should be. Opening
            // a pull request is a form with a commit at the end of it — a
            // decision you finish or abandon — which is what a sheet is for.
            // What it is no longer is a sheet *inside another sheet*.
            PullRequestSheet(session: session,
                             changes: Changes.summarise(session.items),
                             isPresented: $openingPullRequest)
        }
    }

    /// Four tabs and a close, on one line.
    ///
    /// Icons with labels rather than icons alone. There are four of them, they
    /// are the panel's whole vocabulary, and a row of unlabelled glyphs is how
    /// the browser and the changes list stayed undiscovered in the first place.
    /// The labels drop below `Theme.workbenchMinWidth`, where the row would
    /// otherwise wrap.
    private var tabs: some View {
        GeometryReader { geometry in
            let labelled = geometry.size.width >= 420
            HStack(spacing: Theme.s2) {
                ForEach(WorkbenchTab.allCases) { tab in
                    tabButton(tab, labelled: labelled)
                }
                Spacer(minLength: Theme.s3)
                Button {
                    withAnimation(Motion.panel) {
                        session.browserVisible = false
                        session.browserFull = false
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(HoverCapsule())
                .help("Close the workbench")
            }
            .padding(.horizontal, Theme.s5)
            .frame(height: Theme.headerHeight)
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(height: Theme.headerHeight + Chrome.trafficLightClearance - Theme.s6)
    }

    private func tabButton(_ tab: WorkbenchTab, labelled: Bool) -> some View {
        let on = session.workbenchTab == tab
        let badge = self.badge(for: tab)
        return Button {
            withAnimation(Motion.hover) { session.workbenchTab = tab }
        } label: {
            HStack(spacing: Theme.s2) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 10.5, weight: .medium))
                if labelled {
                    Text(tab.title)
                        .font(.system(size: 11.5, weight: .medium))
                }
                if let badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(tab == .run ? Theme.stateLive : Theme.stateDone)
                }
            }
            .foregroundStyle(on ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, Theme.s4)
            .frame(height: 24)
            .background(on ? Theme.well : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help(for: tab))
    }

    /// Counts, where a count is the thing you would have gone looking for.
    private func badge(for tab: WorkbenchTab) -> String? {
        switch tab {
        case .changes:
            let count = Changes.fileCount(session.items)
            return count == 0 ? nil : "\(count)"
        case .run:
            guard let run = session.crewRun, run.isBusy else { return nil }
            let live = run.members.filter { $0.state == .working || $0.state == .answering }
            return live.isEmpty ? nil : "\(live.count)"
        default:
            return nil
        }
    }

    private func help(for tab: WorkbenchTab) -> String {
        switch tab {
        case .preview: return "The page, the dev server, or a rendered artifact"
        case .changes: return "Every file this session has edited"
        case .files:   return "The working directory as it stands now"
        case .run:     return "The crew, while it is running"
        }
    }
}

// MARK: - Changes

/// What the agent edited, as a tab rather than as a modal.
///
/// The list itself is unchanged. What changed is that it no longer hides the
/// conversation to show you the diff of what that conversation produced — which
/// was the whole problem with it being a sheet: the two things you want to
/// compare were never on screen together, so reviewing meant memorising.
private struct ChangesTab: View {
    @ObservedObject var session: Session
    @Binding var openingPullRequest: Bool

    @State private var expanded: Set<String> = []
    @State private var changes: [FileChange] = []

    /// Held rather than computed in the body.
    ///
    /// `Changes.summarise` copies every diff's rows into fresh structs, and
    /// while a reply streams this view redraws on every delta — so computing it
    /// in `body` would rebuild the whole edit history of the session thirty
    /// times a second to answer a question whose answer only changes when an
    /// item is appended. That is precisely the cost the old status rail went
    /// out of its way to avoid, and it would have come straight back the moment
    /// the sheet became a tab that can be left open.
    ///
    /// Driven by `Changes.signature`, not by the item count: an edit becomes a
    /// diff card *in place*, so a tool row turning into the second edit of a
    /// file changes this list without changing how many items there are.
    private func refresh() {
        changes = Changes.summarise(session.items)
    }

    var body: some View {
        let added = changes.reduce(0) { $0 + $1.added }
        let removed = changes.reduce(0) { $0 + $1.removed }

        return VStack(spacing: 0) {
            if changes.isEmpty {
                empty
            } else {
                summary(changes.count, added: added, removed: removed)
                Divider().overlay(Theme.rule)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.s4) {
                        ForEach(changes) { change in
                            row(change)
                        }
                    }
                    .padding(Theme.s5)
                }
            }
        }
        .onAppear { refresh() }
        .onChange(of: Changes.signature(session.items)) { _, _ in refresh() }
    }

    private func summary(_ files: Int, added: Int, removed: Int) -> some View {
        HStack(spacing: Theme.s4) {
            Text("\(files) file\(files == 1 ? "" : "s")")
                .font(Theme.label)
                .foregroundStyle(.secondary)
            HStack(spacing: Theme.s3) {
                if added > 0 {
                    Text("+\(added)").foregroundStyle(Color.diffAddText)
                }
                if removed > 0 {
                    Text("−\(removed)").foregroundStyle(Color.diffDelText)
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .monospacedDigit()

            Spacer(minLength: Theme.s4)

            // This list is already the answer to "what does this change do",
            // which is the question a pull request description exists to
            // answer. Everything downstream of the button is a form you edit
            // before anything is pushed.
            Button("Pull Request…") { openingPullRequest = true }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, Theme.s5)
        .padding(.vertical, Theme.s4)
    }

    private var empty: some View {
        WorkbenchEmpty(symbol: "plusminus",
                       title: "Nothing edited yet",
                       blurb: "Files this session writes show up here, with their "
                            + "diffs and a way to open a pull request.")
    }

    private func row(_ change: FileChange) -> some View {
        let isOpen = expanded.contains(change.file)

        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Motion.disclose) {
                    if isOpen { expanded.remove(change.file) } else { expanded.insert(change.file) }
                }
            } label: {
                HStack(spacing: Theme.s4) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 0 : -90))
                    Text(change.file)
                        .font(Theme.monoSmall)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    if change.refused {
                        Text("declined")
                            .font(Theme.label)
                            .foregroundStyle(Theme.stateBad)
                    }
                    if change.edits.count > 1 {
                        Text("\(change.edits.count) edits")
                            .font(Theme.label)
                            .foregroundStyle(.quaternary)
                    }
                    Spacer(minLength: Theme.s4)
                    HStack(spacing: Theme.s3) {
                        if change.added > 0 {
                            Text("+\(change.added)").foregroundStyle(Color.diffAddText)
                        }
                        if change.removed > 0 {
                            Text("−\(change.removed)").foregroundStyle(Color.diffDelText)
                        }
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .monospacedDigit()

                    FileActionButtons(url: FileActions.resolve(change.file), style: .bare)
                }
                .padding(.horizontal, Theme.s5)
                .padding(.vertical, Theme.s4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                VStack(alignment: .leading, spacing: Theme.s4) {
                    ForEach(Array(change.edits.enumerated()), id: \.offset) { _, rows in
                        FileDiffView(file: change.file, rows: rows, state: .applied)
                    }
                }
                .padding(.horizontal, Theme.s5)
                .padding(.bottom, Theme.s5)
            }
        }
        .modifier(InsetSurface(radius: Theme.cornerField))
    }
}

// MARK: - Files

/// The working directory, as it stands.
///
/// Distinct from Changes, which is only what *this session* wrote. A project
/// has files the agent didn't touch and files it touched before you were
/// watching, and until now the only way to see any of them from inside the app
/// was to ask an agent to read one out.
///
/// Read lazily, one directory per disclosure, and capped — a `node_modules`
/// expanded eagerly is tens of thousands of rows built to be scrolled past.
private struct FilesTab: View {
    @ObservedObject var session: Session

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                DirectoryRows(url: session.directory, depth: 0, session: session)
            }
            .padding(.vertical, Theme.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One directory's children, loaded when it is first shown.
private struct DirectoryRows: View {
    let url: URL
    let depth: Int
    @ObservedObject var session: Session

    @State private var entries: [Entry] = []
    @State private var loaded = false
    @State private var open: Set<URL> = []
    @State private var truncated = 0

    /// Deliberately a value rather than a `URL` alone: `isDirectory` is a stat
    /// call, and doing it per row per redraw is how a file list starts hitting
    /// the disk sixty times a second.
    private struct Entry: Identifiable, Hashable, Sendable {
        let url: URL
        let isDirectory: Bool
        var id: URL { url }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(entries) { entry in
                row(entry)
                if entry.isDirectory, open.contains(entry.url) {
                    DirectoryRows(url: entry.url, depth: depth + 1, session: session)
                }
            }
            if truncated > 0 {
                Text("+\(truncated) more")
                    .font(Theme.label)
                    .foregroundStyle(.quaternary)
                    .padding(.leading, indent(for: depth) + Theme.s6)
                    .padding(.vertical, Theme.s2)
            }
            if loaded && entries.isEmpty && depth == 0 {
                WorkbenchEmpty(symbol: "folder",
                               title: "Nothing here",
                               blurb: "This session's folder is empty.")
                    .frame(height: 220)
            }
        }
        // On the directory, not on a row. Attached to the rows it would never
        // run for a directory that has none — which is every directory before
        // it has been read, so nothing would ever load.
        .task(id: url) { await load() }
    }

    private func row(_ entry: Entry) -> some View {
        Button {
            if entry.isDirectory {
                withAnimation(Motion.disclose) {
                    if open.contains(entry.url) { open.remove(entry.url) }
                    else { open.insert(entry.url) }
                }
            } else {
                // A file opens in Preview, which is the tab that already knows
                // how to render one safely — and is why the two are in the same
                // panel rather than in two places that don't know about each
                // other.
                session.open(file: entry.url)
                session.workbenchTab = .preview
            }
        } label: {
            HStack(spacing: Theme.s3) {
                Image(systemName: entry.isDirectory
                      ? "chevron.right" : "doc")
                    .font(.system(size: entry.isDirectory ? 8 : 9.5,
                                  weight: entry.isDirectory ? .semibold : .regular))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(entry.isDirectory && open.contains(entry.url)
                                             ? 90 : 0))
                    .frame(width: 12)
                Text(entry.url.lastPathComponent)
                    .font(Theme.monoSmall)
                    .foregroundStyle(entry.isDirectory ? AnyShapeStyle(.primary)
                                                       : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.leading, indent(for: depth) + Theme.s5)
            .padding(.trailing, Theme.s5)
            .padding(.vertical, Theme.s2 - 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRow())
        .contextMenu {
            Button("Open") { FileActions.open(entry.url) }
            Button("Reveal in Finder") { FileActions.reveal(entry.url) }
        }
    }

    private func indent(for depth: Int) -> CGFloat { CGFloat(depth) * Theme.s5 }

    /// Off the main thread, and capped. Directories first, then files, both
    /// case-insensitively — the order Finder uses, because this is a file list
    /// and a file list that sorts differently from the Finder is one you have
    /// to read rather than scan.
    private func load() async {
        let url = url
        let result: ([Entry], Int) = await Task.detached(priority: .userInitiated) {
            let manager = FileManager.default
            guard let contents = try? manager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]) else { return ([], 0) }

            let mapped = contents.map { child -> Entry in
                let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?
                    .isDirectory ?? false
                return Entry(url: child, isDirectory: isDirectory)
            }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.url.lastPathComponent
                    .localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
            }

            let cap = 400
            return mapped.count > cap
                ? (Array(mapped.prefix(cap)), mapped.count - cap)
                : (mapped, 0)
        }.value

        entries = result.0
        truncated = result.1
        loaded = true
    }
}

// MARK: - Run

/// The crew, while it is running — and what it did once it isn't.
///
/// `CrewRunPanel` is unchanged and does the work. What is new is that the run
/// has a *place*: before this it appeared between the transcript and the
/// composer while busy and then disappeared, so the answer to "what did those
/// four agents actually do" was gone the moment it became a question you could
/// answer calmly.
private struct RunTab: View {
    @ObservedObject var session: Session

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s5) {
                if let run = session.crewRun {
                    CrewRunPanel(run: run, session: session)
                } else {
                    WorkbenchEmpty(
                        symbol: "person.2",
                        title: "No crew running",
                        blurb: "Add agents to the team in the bar above, then send a "
                             + "message. The lead plans, the others work in parallel, "
                             + "and this is where you watch it happen.")
                        .frame(height: 260)
                }
            }
            .padding(Theme.s5)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Nothing to show

/// One empty state, so all four tabs say nothing the same way.
///
/// Each of these surfaces had its own — or, in two cases, didn't: the run block
/// simply wasn't drawn when there was no run, and a directory listing had never
/// needed one because there had never been a directory listing. A panel whose
/// tabs are empty in four different visual styles reads as four panels.
struct WorkbenchEmpty: View {
    let symbol: String
    let title: String
    let blurb: String

    var body: some View {
        VStack(spacing: Theme.s4) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(.quaternary)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text(blurb)
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.s6)
    }
}
