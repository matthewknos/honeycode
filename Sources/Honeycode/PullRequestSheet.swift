import SwiftUI
import AppKit

/// Turning a session into a pull request.
///
/// The whole feature is that `ChangesView` already knows what the agent did —
/// every file, every edit, in order — and until now that knowledge died when you
/// closed the sheet. You went to a terminal and wrote the summary again from
/// memory, which is the one summary that is reliably wrong.
///
/// Three rules this screen is built around:
///
/// - **Nothing leaves without being read.** A transcript holds file contents,
///   commands and diffs, and some of it belongs to a different customer than the
///   pull request does. The body is a draft in an editable field, never a
///   payload sent on your behalf.
/// - **Only the session's files.** The commit names paths explicitly, so
///   whatever else is in your work tree — including anything you had staged —
///   stays exactly where it was.
/// - **No cleverness with history.** Branch, commit, push. Nothing forces,
///   nothing rebases, nothing resets.
struct PullRequestSheet: View {
    @ObservedObject var session: Session
    let changes: [FileChange]
    @Binding var isPresented: Bool

    private enum Stage {
        case checking
        case blocked(Blocked)
        case editing(RepoContext)
        case working(RepoContext, String)
        case done(OpenedPullRequest)
        case failed(RepoContext, CommandFailure)
    }

    @State private var stage: Stage = .checking

    @State private var title = ""
    @State private var summary = ""
    @State private var branch = ""
    @State private var base = ""
    @State private var isDraft = false
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.rule)
            content
            Divider().overlay(Theme.rule)
            footer
        }
        .frame(width: 720, height: 620)
        .task { await preflight() }
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: Theme.s5) {
            VStack(alignment: .leading, spacing: Theme.s1) {
                Text("Pull Request")
                    .font(.system(size: 15, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, Theme.s6)
        .padding(.vertical, Theme.s5)
    }

    private var subtitle: String {
        switch stage {
        case .checking:
            return "Checking the repository…"
        case .blocked:
            return session.directory.lastPathComponent
        case .editing(let context), .working(let context, _), .failed(let context, _):
            let count = context.stageableNames.count
            let files = context.alreadyCommitted
                ? "already committed"
                : "\(count) file\(count == 1 ? "" : "s")"
            return "\(context.forge.displayName) · \(files) · +\(added) −\(removed)"
        case .done(let opened):
            return opened.alreadyExisted
                ? "This branch already had one"
                : "Opened on \(opened.url.host ?? "the remote")"
        }
    }

    private var added: Int { changes.reduce(0) { $0 + $1.added } }
    private var removed: Int { changes.reduce(0) { $0 + $1.removed } }

    @ViewBuilder
    private var content: some View {
        switch stage {
        case .checking:
            centred {
                ProgressView().controlSize(.small)
                Text("Reading the repository")
                    .font(Theme.body)
                    .foregroundStyle(.secondary)
            }
        case .blocked(let reason):
            centred {
                Image(systemName: reason.symbol)
                    .font(.system(size: 24))
                    .foregroundStyle(.quaternary)
                Text(reason.title)
                    .font(.system(size: 14, weight: .medium))
                Text(reason.detail)
                    .font(Theme.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .lineSpacing(Theme.lineSpacing - 2)
            }
        case .editing(let context):
            form(context)
        case .working(_, let step):
            centred {
                ProgressView().controlSize(.small)
                Text(step)
                    .font(Theme.body)
                    .foregroundStyle(.secondary)
            }
        case .done(let opened):
            success(opened)
        case .failed(_, let failure):
            failureView(failure)
        }
    }

    private var footer: some View {
        HStack(spacing: Theme.s4) {
            Spacer()
            switch stage {
            case .checking:
                Button("Cancel") { isPresented = false }
            case .working:
                // "Close", not "Cancel". By this point the branch switch, the
                // commit and possibly the push are already under way against a
                // real remote, and none of them can be safely unwound from
                // here. Closing stops you watching; it doesn't stop the work,
                // and a button labelled Cancel would be claiming otherwise.
                Button("Close") { isPresented = false }
                    .help("The pull request is still being created. This closes the "
                          + "sheet; it doesn't cancel the work.")
            case .blocked:
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            case .editing:
                Button("Cancel") { isPresented = false }
                Button(isDraft ? "Create Draft" : "Create Pull Request") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isReady)
            case .failed(let context, _):
                Button("Back") { stage = .editing(context) }
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            case .done:
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, Theme.s6)
        .padding(.vertical, Theme.s5)
    }

    private func centred<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: Theme.s4) {
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.s7)
    }

    // MARK: The form

    private func form(_ context: RepoContext) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s6) {
                field("Title") {
                    TextField("", text: $title)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13.5, weight: .medium))
                        .padding(.horizontal, Theme.s5)
                        .padding(.vertical, Theme.s4)
                        .modifier(FormField())
                }

                field("Description") {
                    TextEditor(text: $summary)
                        .font(Theme.body)
                        .scrollContentBackground(.hidden)
                        .lineSpacing(Theme.lineSpacing - 2)
                        .padding(.horizontal, Theme.s4)
                        .padding(.vertical, Theme.s3)
                        .frame(height: 230)
                        .modifier(FormField())
                }

                HStack(alignment: .bottom, spacing: Theme.s5) {
                    field("Branch") {
                        TextField("", text: $branch)
                            .textFieldStyle(.plain)
                            .font(Theme.monoSmall)
                            .padding(.horizontal, Theme.s5)
                            .padding(.vertical, Theme.s4)
                            .modifier(FormField())
                    }
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.bottom, Theme.s5)
                    field("Into") {
                        TextField("", text: $base)
                            .textFieldStyle(.plain)
                            .font(Theme.monoSmall)
                            .padding(.horizontal, Theme.s5)
                            .padding(.vertical, Theme.s4)
                            .modifier(FormField())
                    }
                    Toggle("Draft", isOn: $isDraft)
                        .toggleStyle(.checkbox)
                        .padding(.bottom, Theme.s4)
                }

                notes(context)
            }
            .padding(Theme.s6)
        }
    }

    private func field<Content: View>(_ label: String,
                                      @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            Text(label)
                .font(Theme.label)
                .foregroundStyle(.secondary)
            content()
        }
    }

    /// What this will and won't touch, said before you press the button rather
    /// than discovered afterwards with `git log`.
    @ViewBuilder
    private func notes(_ context: RepoContext) -> some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            if context.alreadyCommitted {
                note("checkmark.circle",
                     "Nothing left to commit — this branch is already ahead of "
                     + "`\(context.defaultBranch)`. Honeycode will push it and open the "
                     + "pull request.")
            } else {
                note("doc.badge.plus",
                     "Commits \(context.stageableNames.count) file"
                     + "\(context.stageableNames.count == 1 ? "" : "s") — "
                     + context.stageableNames.prefix(3).map { "`\($0)`" }.joined(separator: ", ")
                     + (context.stageableNames.count > 3
                        ? " and \(context.stageableNames.count - 3) more." : "."))
            }
            if context.otherDirtyCount > 0 {
                note("exclamationmark.triangle",
                     "\(context.otherDirtyCount) other file"
                     + "\(context.otherDirtyCount == 1 ? "" : "s") in this repository "
                     + "\(context.otherDirtyCount == 1 ? "has" : "have") uncommitted changes. "
                     + "They stay uncommitted.")
            }
            if branch == context.defaultBranch {
                note("exclamationmark.triangle",
                     "`\(branch)` is the default branch. A pull request can't be opened from "
                     + "the branch it would merge into — change the branch name above and "
                     + "Honeycode will create it.")
            }
        }
    }

    private func note(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.s4) {
            Image(systemName: symbol)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .frame(width: 14)
            // Markdown so the backticks in these lines render as code rather
            // than as backticks, which is what they'd otherwise be.
            Text((try? AttributedString(markdown: text)) ?? AttributedString(text))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.s5)
        .padding(.vertical, Theme.s4)
        .modifier(InsetSurface(radius: Theme.cornerCard))
    }

    // MARK: Outcomes

    private func success(_ opened: OpenedPullRequest) -> some View {
        centred {
            Image(systemName: "arrow.triangle.pull")
                .font(.system(size: 26))
                .foregroundStyle(Color.diffAddText)
            Text(opened.alreadyExisted ? "This branch already had a pull request"
                                       : "Pull request opened")
                .font(.system(size: 14, weight: .medium))
            Text(opened.url.absoluteString)
                .font(Theme.monoSmall)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: 460)

            // Deliberately not offered in the browser panel. That panel is a
            // sandbox for agent-written markup — it blocks every request that
            // isn't loopback — so sending github.com to it would produce a
            // blank page and a puzzle. The panel isn't a web browser, and the
            // one time it would be convenient to pretend otherwise is exactly
            // the time the pretence would break.
            HStack(spacing: Theme.s4) {
                Button("Open in Browser") { NSWorkspace.shared.open(opened.url) }
                    .buttonStyle(.borderedProminent)
                Button(copied ? "Copied" : "Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(opened.url.absoluteString, forType: .string)
                    copied = true
                }
                .animation(Motion.reveal, value: copied)
            }
            .padding(.top, Theme.s3)
        }
    }

    private func failureView(_ failure: CommandFailure) -> some View {
        VStack(alignment: .leading, spacing: Theme.s5) {
            HStack(spacing: Theme.s4) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.diffDelText)
                Text(failure.summary)
                    .font(.system(size: 14, weight: .medium))
            }
            // The tool's own words, unedited. Paraphrasing git loses the half
            // of the message that tells you what to do about it.
            ScrollView {
                Text(failure.detail.isEmpty ? "No output." : failure.detail)
                    .font(Theme.monoSmall)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.s5)
            }
            .modifier(InsetSurface(radius: Theme.cornerCard))

            Text("Nothing was pushed past the step that failed. Your working tree is "
                 + "where the last successful step left it.")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(Theme.s6)
    }

    // MARK: Work

    /// Everything that has to be true before a form is worth showing.
    ///
    /// Off the main thread: it spawns half a dozen short-lived processes, one of
    /// which (`gh auth status`) touches the keychain. None of that belongs on
    /// the thread that's drawing.
    private func preflight() async {
        let directory = session.directory
        let files = changes.map(\.file)
        let outcome = await Task.detached(priority: .userInitiated) {
            PullRequestPreflight.check(directory: directory, files: files)
        }.value

        switch outcome {
        case .blocked(let blocked):
            stage = .blocked(blocked)
        case .ready(let context):
            title = PullRequestText.title(for: session)
            summary = PullRequestText.body(for: session, changes: changes,
                                         including: context.stageableNames)
            base = context.defaultBranch
            // Already on a branch of your own? Stay on it. Proposing a new one
            // when you've clearly made one is the app second-guessing a
            // decision you already took.
            branch = context.currentBranch == context.defaultBranch
                ? PullRequestText.branchName(from: title, avoiding: context.root)
                : context.currentBranch
            stage = .editing(context)
        }
    }

    /// Whether the form describes something git and GitHub will both accept.
    ///
    /// The branch-equals-base check is here rather than left to `gh`: a pull
    /// request from a branch into itself is the one mistake this form makes easy
    /// to make, and finding out about it after the push is finding out too late.
    private var isReady: Bool {
        let branch = branch.trimmingCharacters(in: .whitespaces)
        let base = base.trimmingCharacters(in: .whitespaces)
        return !title.trimmingCharacters(in: .whitespaces).isEmpty
            && !branch.isEmpty && !base.isEmpty && branch != base
    }

    private func create() {
        guard case .editing(let context) = stage, isReady else { return }
        let draft = PullRequestDraft(
            title: title.trimmingCharacters(in: .whitespaces),
            body: summary,
            branch: branch.trimmingCharacters(in: .whitespaces),
            base: base.trimmingCharacters(in: .whitespaces),
            isDraft: isDraft)
        let commitBody = PullRequestText.commitBody(for: session)

        Task {
            do {
                // One step at a time, each announced before it runs and each
                // run off the main thread. Written as a sequence of awaits
                // rather than one detached block with a progress callback,
                // because the callback version needs the view to be reachable
                // from another thread and this one doesn't.
                stage = .working(context, "Switching to \(draft.branch)")
                try await offMain { try Git.switchTo(draft.branch, in: context.root) }

                if !context.stageable.isEmpty {
                    let count = context.stageable.count
                    stage = .working(context, "Committing \(count) file\(count == 1 ? "" : "s")")
                    try await offMain {
                        try Git.commit(paths: context.stageable, title: draft.title,
                                       body: commitBody, in: context.root)
                    }
                }

                stage = .working(context, "Pushing to origin")
                try await offMain { try Git.push(draft.branch, in: context.root) }

                stage = .working(context, "Opening the pull request")
                let opened = try await offMain {
                    try context.service.create(draft, in: context.root)
                }
                stage = .done(opened)
            } catch let failure as CommandFailure {
                stage = .failed(context, failure)
            } catch {
                stage = .failed(context, CommandFailure(summary: "Something went wrong",
                                                        detail: error.localizedDescription))
            }
        }
    }

    private func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated, operation: work).value
    }

}

/// A text field that looks like it belongs to this app rather than to 2011.
///
/// `.roundedBorder` is AppKit's bezel, which is a heavier, greyer thing than
/// anything else on screen here — it reads as a control dropped into a document.
/// This is the same fill and hairline every other recessed surface in the app
/// uses, at the corner radius the composer already established for fields.
// `FormField` moved to Theme.swift. It was private here and is what a text
// field looks like in this app, which made every other field either import a
// sheet's private type or invent its own — and one of them did.
