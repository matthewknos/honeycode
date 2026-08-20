import Foundation

// MARK: - Where the code is hosted

/// The service behind `origin`, worked out from the remote URL.
///
/// This is the seam. Everything above it — the sheet, the draft, the git work —
/// is host-agnostic; the only thing that knows what a pull request *is* on a
/// given service is the `PullRequestService` behind each case. Azure DevOps is
/// recognised here but not yet driven, so a repo hosted there gets an accurate
/// "not wired up yet" rather than the wrong answer, "this isn't a GitHub repo".
enum Forge: Equatable, Sendable {
    /// `host` is carried because GitHub Enterprise is still GitHub, and `gh`
    /// works against it — it just isn't github.com.
    case gitHub(host: String, slug: String)
    case azureDevOps(organisation: String, project: String, repo: String)
    case other(host: String)

    /// Parsed rather than pattern-matched loosely, because the two URL shapes
    /// git accepts are genuinely different grammars: `scp`-style
    /// (`git@host:path`) has no scheme and a colon where a slash should be.
    static func detect(remote: String) -> Forge {
        let (host, path) = split(remote)
        let parts = path.split(separator: "/").map(String.init)

        if host == "dev.azure.com" || host == "ssh.dev.azure.com" {
            // https://dev.azure.com/org/project/_git/repo
            // git@ssh.dev.azure.com:v3/org/project/repo
            let trimmed = parts.first == "v3" ? Array(parts.dropFirst()) : parts
            let named = trimmed.filter { $0 != "_git" }
            if named.count >= 3 {
                return .azureDevOps(organisation: named[0], project: named[1], repo: named[2])
            }
            return .other(host: host)
        }
        // The legacy form, still in use across plenty of Microsoft estates.
        if host.hasSuffix(".visualstudio.com") {
            let org = String(host.dropLast(".visualstudio.com".count))
            let named = parts.filter { $0 != "_git" && $0 != "DefaultCollection" }
            if named.count >= 2 {
                return .azureDevOps(organisation: org, project: named[0], repo: named[1])
            }
            return .other(host: host)
        }
        if host == "github.com" || host.hasPrefix("github.") || host.contains(".github.") {
            guard parts.count >= 2 else { return .other(host: host) }
            return .gitHub(host: host, slug: "\(parts[0])/\(parts[1])")
        }
        return .other(host: host)
    }

    /// `(host, path)` from either URL grammar, with `.git` and any credentials
    /// stripped.
    private static func split(_ remote: String) -> (host: String, path: String) {
        var text = remote.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix(".git") { text = String(text.dropLast(4)) }

        if let range = text.range(of: "://") {
            var rest = String(text[range.upperBound...])
            // `https://token@host/…` — the token is not something to keep hold of.
            if let at = rest.firstIndex(of: "@") { rest = String(rest[rest.index(after: at)...]) }
            let slash = rest.firstIndex(of: "/") ?? rest.endIndex
            let host = String(rest[..<slash]).components(separatedBy: ":").first ?? ""
            return (host.lowercased(), String(rest[slash...]).trimmingCharacters(in: ["/"]))
        }
        // scp-style: [user@]host:path
        if let colon = text.firstIndex(of: ":") {
            var host = String(text[..<colon])
            if let at = host.firstIndex(of: "@") { host = String(host[host.index(after: at)...]) }
            let path = String(text[text.index(after: colon)...])
            return (host.lowercased(), path.trimmingCharacters(in: ["/"]))
        }
        return (text.lowercased(), "")
    }

    var displayName: String {
        switch self {
        case .gitHub(_, let slug):                     return slug
        case .azureDevOps(let org, let project, let repo): return "\(org)/\(project)/\(repo)"
        case .other(let host):                         return host
        }
    }

    var service: PullRequestService? {
        switch self {
        case .gitHub:                  return GitHubPullRequests()
        case .azureDevOps, .other:     return nil
        }
    }

    /// Why there's no service, in words that say what would fix it.
    var unsupported: String {
        switch self {
        case .gitHub:
            return ""
        case .azureDevOps:
            return """
            This repository is hosted on Azure DevOps, which Honeycode can \
            recognise but can't open a pull request against yet. The commit and \
            the push would work; only the last step is missing.
            """
        case .other(let host):
            return """
            Honeycode can open pull requests on GitHub. `origin` points at \
            \(host.isEmpty ? "somewhere it doesn't recognise" : host).
            """
        }
    }
}

// MARK: - Opening the pull request

struct PullRequestDraft: Sendable {
    var title: String
    var body: String
    var branch: String
    var base: String
    var isDraft: Bool
}

struct OpenedPullRequest: Sendable {
    let url: URL
    /// True when the branch already had a pull request and this is that one.
    /// Worth saying out loud — otherwise pressing the button twice looks like
    /// it silently made a second one.
    let alreadyExisted: Bool
}

/// One host's idea of a pull request.
///
/// Everything a new host needs to implement, and nothing about how the button
/// looks or what the branch is called. Adding Azure DevOps means writing one of
/// these against `az repos pr create` and returning it from `Forge.service`.
protocol PullRequestService: Sendable {
    var name: String { get }
    var requirement: ToolRequirement { get }
    var isInstalled: Bool { get }
    func signedIn() -> Bool
    func create(_ draft: PullRequestDraft, in root: URL) throws -> OpenedPullRequest
}

/// The command-line tool a service drives, and what to type when it's missing.
///
/// Carried as data rather than written into the error messages so that the two
/// blocked states — not installed, not signed in — are the service's to answer
/// and the sheet's to render. A second service adds one of these, not a branch
/// in the sheet.
struct ToolRequirement: Sendable {
    let tool: String
    let install: String
    let signIn: String
}

/// GitHub, through `gh`.
///
/// The CLI rather than the REST API on purpose: `gh` is already authenticated
/// on any machine that uses GitHub from a terminal, its token lives in the
/// keychain, and it handles enterprise hosts and SSO without being told. The
/// alternative is asking you to paste a personal access token into a text field
/// and then storing it — which is more code, more risk, and worse.
struct GitHubPullRequests: PullRequestService {
    let name = "GitHub"
    let requirement = ToolRequirement(tool: "gh",
                                      install: "brew install gh",
                                      signIn: "gh auth login")

    private var binary: String? { Shell.locate("gh") }

    var isInstalled: Bool { binary != nil }

    func signedIn() -> Bool {
        guard let binary else { return false }
        return Shell.run(binary, ["auth", "status"]).ok
    }

    func create(_ draft: PullRequestDraft, in root: URL) throws -> OpenedPullRequest {
        guard let binary else {
            throw CommandFailure(summary: "`gh` isn't installed", detail: requirement.install)
        }
        // Both are free-text fields on the sheet, and both land next to flags.
        try Git.check(branch: draft.base)
        try Git.check(branch: draft.branch)
        var arguments = ["pr", "create",
                         "--title", draft.title,
                         // Down stdin rather than as an argument. A body is
                         // paragraphs of prose with newlines and backticks in
                         // it, and the argument list is the wrong place for
                         // that in every shell that has ever existed.
                         "--body-file", "-",
                         "--base", draft.base,
                         "--head", draft.branch]
        if draft.isDraft { arguments.append("--draft") }

        let result = Shell.run(binary, arguments, in: root, stdin: draft.body)
        if result.ok, let url = Self.url(in: result.out) {
            return OpenedPullRequest(url: url, alreadyExisted: false)
        }
        // Pressing the button on a branch that already has one. `gh` treats
        // this as an error; a person doesn't, so show them the pull request
        // rather than the complaint about it.
        if result.message.localizedCaseInsensitiveContains("already exists"),
           let existing = existingPullRequest(for: draft.branch, in: root) {
            return OpenedPullRequest(url: existing, alreadyExisted: true)
        }
        throw CommandFailure(summary: "GitHub wouldn't open the pull request",
                             detail: result.message)
    }

    private func existingPullRequest(for branch: String, in root: URL) -> URL? {
        guard let binary else { return nil }
        let result = Shell.run(binary, ["pr", "view", branch, "--json", "url", "-q", ".url"],
                               in: root)
        return result.ok ? Self.url(in: result.out) : nil
    }

    /// `gh` prints the URL on its own line, but it also prints notices — about
    /// forks, about the base branch — so the URL is picked out rather than
    /// assumed to be the whole of stdout.
    private static func url(in output: String) -> URL? {
        output.split(whereSeparator: \.isWhitespace)
            .last { $0.hasPrefix("https://") }
            .flatMap { URL(string: String($0)) }
    }
}

// MARK: - What we're going to open

/// Everything known before the sheet can show a form.
struct RepoContext: Sendable {
    var root: URL
    var currentBranch: String
    var defaultBranch: String
    var forge: Forge
    var service: PullRequestService

    /// Session-edited files that git agrees still differ from HEAD, absolute.
    var stageable: [String]
    /// The same list, repo-relative, for the body and the summary line.
    var stageableNames: [String]
    /// How many *other* files in the repo have uncommitted changes. They stay
    /// uncommitted, and saying so is the difference between a feature you can
    /// trust and one you check afterwards with `git log`.
    var otherDirtyCount: Int
    /// The agent committed as it went: nothing to commit, but a branch worth
    /// opening a pull request from.
    var alreadyCommitted: Bool
}

/// The outcome of the checks, which is either a form or a reason there isn't one.
///
/// A two-case enum rather than a `Result`: none of these are errors. "This
/// session isn't in a git repository" is a perfectly ordinary state for two of
/// the three sessions this app runs, and modelling it as a failure would put it
/// in the same box as a push that got rejected.
enum Preflight: Sendable {
    case ready(RepoContext)
    case blocked(Blocked)
}

/// Why the sheet can't offer a form.
struct Blocked: Sendable {
    let symbol: String
    let title: String
    let detail: String
}

enum PullRequestPreflight {

    /// Everything that has to be true before a pull request is even offered.
    ///
    /// Runs off the main thread — it spawns half a dozen short-lived processes,
    /// and one of them (`gh auth status`) touches the keychain, which is not
    /// something to do on the thread that's drawing.
    nonisolated static func check(directory: URL, files: [String]) -> Preflight {
        guard Git.binary != nil else {
            return .blocked(Blocked(
                symbol: "wrench.and.screwdriver",
                title: "git isn't installed",
                detail: "Install the Xcode Command Line Tools with `xcode-select --install`."))
        }
        guard let root = Git.root(of: directory) else {
            return .blocked(Blocked(
                symbol: "folder.badge.questionmark",
                title: "This session isn't in a git repository",
                detail: "\(directory.path) isn't inside a work tree, so there's nothing to "
                        + "branch from."))
        }
        guard let remote = Git.remote(in: root) else {
            return .blocked(Blocked(
                symbol: "point.3.connected.trianglepath.dotted",
                title: "This repository has no `origin`",
                detail: "A pull request needs somewhere to push to. Add a remote and try again."))
        }

        let forge = Forge.detect(remote: remote)
        guard let service = forge.service else {
            return .blocked(Blocked(
                symbol: "questionmark.folder",
                title: "\(forge.displayName) isn't supported yet",
                detail: forge.unsupported))
        }
        guard service.isInstalled else {
            return .blocked(Blocked(
                symbol: "terminal",
                title: "`\(service.requirement.tool)` isn't installed",
                detail: "Honeycode opens \(service.name) pull requests through its own "
                        + "command-line tool, so your credentials stay in the keychain and "
                        + "never come near this app.\n\n"
                        + "\(service.requirement.install)\n\(service.requirement.signIn)"))
        }
        guard service.signedIn() else {
            return .blocked(Blocked(
                symbol: "person.badge.key",
                title: "`\(service.requirement.tool)` isn't signed in",
                detail: "Run `\(service.requirement.signIn)` in a terminal, then try again."))
        }

        let currentBranch = Git.currentBranch(in: root)
        let defaultBranch = Git.defaultBranch(in: root)
        let dirty = Git.dirtyPaths(in: root)

        // Only files the session actually touched, and only where git agrees
        // something changed. An edit the agent later reverted leaves a diff in
        // the transcript and nothing on disk, and committing it would produce
        // an empty change with a confident description attached.
        var stageable: [String] = [], names: [String] = []
        for path in files {
            guard let name = relative(path, to: root), dirty.contains(name) else { continue }
            names.append(name)
            stageable.append(root.appendingPathComponent(name).path)
        }
        let ours = Set(names)
        let alreadyCommitted = stageable.isEmpty
            && Git.hasCommits(on: currentBranch, beyond: defaultBranch, in: root)

        if stageable.isEmpty && !alreadyCommitted {
            return .blocked(Blocked(
                symbol: "checkmark.circle",
                title: "Nothing to open a pull request with",
                detail: "None of the files this session edited still differ from the last "
                        + "commit, and this branch has nothing the base branch doesn't."))
        }

        return .ready(RepoContext(
            root: root,
            currentBranch: currentBranch,
            defaultBranch: defaultBranch,
            forge: forge,
            service: service,
            stageable: stageable,
            stageableNames: names,
            otherDirtyCount: dirty.subtracting(ours).count,
            alreadyCommitted: alreadyCommitted))
    }

    /// A display path from the transcript, as a path relative to the work tree.
    ///
    /// Transcript paths arrive in three shapes — absolute, `~`-abbreviated, and
    /// occasionally relative — and symlinks have to come out of both sides
    /// before they can be compared, or a repo under `/tmp` never matches
    /// anything. Returns nil for a file outside the tree, which is how an
    /// agent's edit to something in your home directory stays out of the commit.
    static func relative(_ displayPath: String, to root: URL) -> String? {
        let expanded = NSString(string: displayPath).expandingTildeInPath
        let url = expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded)
            : root.appendingPathComponent(expanded)

        let file = url.resolvingSymlinksInPath().standardizedFileURL.path
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard file.hasPrefix(base + "/") else { return nil }
        return String(file.dropFirst(base.count + 1))
    }
}

// MARK: - Writing the thing

enum PullRequestText {

    /// A branch name from the first thing you asked for.
    ///
    /// No vendor prefix. It's your repository and your branch naming
    /// convention, and an app that stamped `honeycode/` onto every branch would
    /// be advertising itself in your team's branch list forever.
    static func branchName(from text: String, avoiding root: URL?) -> String {
        var slug = text.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.count > 42, let cut = slug.prefix(42).lastIndex(of: "-") {
            slug = String(slug[..<cut])
        }
        if slug.isEmpty { slug = "session-changes" }

        guard let root else { return slug }
        var candidate = slug, suffix = 2
        while Git.branchExists(candidate, in: root) {
            candidate = "\(slug)-\(suffix)"
            suffix += 1
        }
        return candidate
    }

    /// One line, from the first thing asked rather than the last thing said.
    ///
    /// The opening request is what the change is *for*; the closing summary is
    /// what it turned out to be. A title wants the former, and a body wants both.
    static func title(for session: Session) -> String {
        let ask = firstAsk(session.items).map { Attached.split($0).prose } ?? ""
        let line = ask
            .split(separator: "\n")
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { String($0).trimmingCharacters(in: .whitespaces) } ?? session.name

        // Stripped in a loop, because they stack. "please can you fix X" is one
        // of the most common ways to open a session, and taking off only the
        // first word leaves a pull request titled "Can you fix X" — which reads
        // like the branch is asking rather than answering.
        var text = line
        while true {
            let stripped = text.replacingOccurrences(
                of: "^(please|can you|could you|would you|i need you to|"
                    + "i'd like you to|lets|let's|hey,?|ok,?|so,?)\\s+",
                with: "", options: [.regularExpression, .caseInsensitive])
            if stripped == text { break }
            text = stripped
        }
        if let first = text.first { text = first.uppercased() + text.dropFirst() }
        while let last = text.last, ".?!,".contains(last) { text.removeLast() }
        if text.count > 72, let cut = text.prefix(72).lastIndex(of: " ") {
            text = String(text[..<cut]) + "…"
        }
        return text.isEmpty ? session.name : text
    }

    /// The body, from what was asked, what the agent said it did, and what git
    /// will actually commit.
    ///
    /// Every line of this is editable before it's sent, and that's not a
    /// courtesy — a transcript holds file contents, commands and diffs, and
    /// some of it belongs to a different customer than the pull request does.
    /// Nothing here goes to a remote without being read first.
    static func body(for session: Session, changes: [FileChange],
                     including names: [String]) -> String {
        var parts: [String] = []

        if let ask = firstAsk(session.items).map({ Attached.split($0).prose }),
           !ask.isEmpty {
            parts.append("**The ask**\n\n" + quote(clip(ask, to: 600)))
        }
        if let summary = lastSummary(session.items) {
            parts.append(clip(summary, to: 2_000))
        }

        let included = Set(names)
        let listed = changes.filter { change in
            PullRequestPreflight.relative(change.file, to: session.directory)
                .map(included.contains) ?? included.contains(change.file)
        }
        if !listed.isEmpty {
            let rows = listed.map { change -> String in
                let name = PullRequestPreflight
                    .relative(change.file, to: session.directory) ?? change.file
                return "- `\(name)` +\(change.added) −\(change.removed)"
            }
            parts.append("**Files**\n\n" + rows.joined(separator: "\n"))
        }

        parts.append("---\n\n<sub>Drafted from a Honeycode session — "
                     + "\(session.account.title), \(session.model.title). "
                     + "Reviewed and edited before opening.</sub>")

        // GitHub's own limit is 65,536; well short of it is where a readable
        // pull request lives anyway.
        return clip(parts.joined(separator: "\n\n"), to: 20_000)
    }

    /// The commit message's body, which is not the pull request's.
    ///
    /// A commit message is read in `git log` at 80 columns by someone bisecting,
    /// so it gets the plain request and none of the markdown. The pull request
    /// body is read on a web page by a reviewer, so it gets the headings, the
    /// file list and the provenance line. Using one for both makes the log noisy
    /// or the review thin, depending which way you pick.
    static func commitBody(for session: Session) -> String {
        guard let ask = firstAsk(session.items).map({ Attached.split($0).prose }),
              !ask.isEmpty else { return "" }
        return clip(ask, to: 500)
    }

    // MARK: Pulling text back out of the transcript

    private static func firstAsk(_ items: [TranscriptItem]) -> String? {
        for item in items {
            if case .user(_, let text) = item,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        return nil
    }

    /// The agent's closing summary.
    ///
    /// Searched backwards, and short replies are skipped: the last assistant
    /// turn is very often "Done." or "Fixed — the build passes", which is a
    /// fine thing to say to you and a useless pull request description.
    private static func lastSummary(_ items: [TranscriptItem]) -> String? {
        for item in items.reversed() {
            if case .assistant(_, let text) = item {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count >= 120 { return trimmed }
            }
        }
        return nil
    }

    private static func quote(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> " + $0 }
            .joined(separator: "\n")
    }

    private static func clip(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        let end = cut.lastIndex(of: "\n") ?? cut.endIndex
        return String(cut[..<end]) + "\n\n…"
    }
}
