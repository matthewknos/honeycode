import SwiftUI
import AppKit

// MARK: - What this directory belongs to

/// How far an Azure project has got on *this* machine.
///
/// The distinction is the useful part. A repo with an `azure.yaml` is an Azure
/// project; a repo with a provisioned environment has a resource group with
/// your name on it and a portal page to open. Showing the second as though it
/// were the first would be a link to nothing.
enum AzureProject: Equatable, Sendable {
    case provisioned(AzureEnvironment)
    /// Several provisioned environments, and nothing on disk saying which one
    /// is current.
    ///
    /// Naming one anyway would be a guess about which subscription you're
    /// deploying into, which is the last thing to guess about. But the previous
    /// behaviour — show nothing — was worse in its own way: a repo that plainly
    /// *is* an Azure project rendered identically to one that isn't, so the
    /// only signal you got was the absence of a chip you might not have been
    /// expecting. This says it found them and can't choose.
    case ambiguous([AzureEnvironment])
    /// An `azd` project that has never been provisioned from this checkout.
    case declared(name: String)

    var label: String {
        switch self {
        case .provisioned(let environment): return environment.resourceGroup
        case .ambiguous(let all):           return "\(all.count) environments"
        case .declared(let name):           return name
        }
    }
}

/// One `azd` environment, as `azd` itself recorded it.
struct AzureEnvironment: Equatable, Sendable {
    var name: String
    /// The directory under `.azure` it was read from. Usually the same string
    /// as `name`, but `config.json` keys the default by the folder, and an
    /// environment renamed after creation makes the two diverge — so matching
    /// on one alone would lose the default exactly when it mattered.
    var folder: String = ""
    var resourceGroup: String
    var subscription: String?
    var location: String?
    var tenant: String?

    /// The portal blade for the group.
    ///
    /// Needs the subscription — a resource group name alone doesn't identify
    /// anything, since two subscriptions can both have an `rg-dev`. Without one
    /// the chip stays a readout rather than becoming a dead link.
    var portalURL: URL? {
        guard let subscription, !subscription.isEmpty else { return nil }
        let path = "/resource/subscriptions/\(subscription)"
            + "/resourceGroups/\(resourceGroup)/overview"
        // The `@tenant` form is what `azd` prints, and it matters when you're
        // signed into more than one directory: without it the portal opens in
        // whichever tenant it saw last, which for most people here is not the
        // work one.
        if let tenant, !tenant.isEmpty {
            return URL(string: "https://portal.azure.com/#@\(tenant)" + path)
        }
        return URL(string: "https://portal.azure.com/#" + path)
    }
}

// MARK: - Finding it

enum ProjectDetector {

    /// The nearest `azd` project at or above this directory.
    ///
    /// Walks upwards because a session is very often opened on a service inside
    /// the repo — `./bridge` in your foundry-agents tree — while `azure.yaml`
    /// and `.azure/` sit at the root. Bounded rather than unbounded: without a
    /// stop this would happily walk out of your home directory and find
    /// somebody else's environment.
    static func azure(near directory: URL) -> AzureProject? {
        let stop = Git.root(of: directory)
        var here = directory.resolvingSymlinksInPath()
        for _ in 0..<8 {
            if let found = azureProject(in: here) { return found }
            if let stop, here.path == stop.resolvingSymlinksInPath().path { return nil }
            let parent = here.deletingLastPathComponent()
            if parent.path == here.path || parent.path == "/" { return nil }
            here = parent
        }
        return nil
    }

    /// One directory, no walking.
    private static func azureProject(in directory: URL) -> AzureProject? {
        let manifest = ["azure.yaml", "azure.yml"]
            .map { directory.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }

        let dot = directory.appendingPathComponent(".azure")
        if let environment = environment(inAzureDirectory: dot) {
            return .provisioned(environment)
        }
        // Provisioned more than once with no stated default — one environment
        // per account is the ordinary way to end up here.
        let all = provisionedEnvironments(inAzureDirectory: dot)
        if all.count > 1 { return .ambiguous(all) }
        guard let manifest else { return nil }
        return .declared(name: projectName(inManifest: manifest)
                         ?? directory.lastPathComponent)
    }

    /// The current environment's values, from `.azure/<name>/.env`.
    ///
    /// `nil` when it can't be known rather than when there's nothing there —
    /// see `provisionedEnvironments`, which is what the caller shows instead.
    static func environment(inAzureDirectory dot: URL) -> AzureEnvironment? {
        let all = provisionedEnvironments(inAzureDirectory: dot)
        if let data = try? Data(contentsOf: dot.appendingPathComponent("config.json")),
           let name = defaultEnvironment(inConfig: data),
           let stated = all.first(where: { $0.folder == name || $0.name == name }) {
            return stated
        }
        // No config, or a config naming an environment that has since been
        // deleted or was never provisioned: one on disk is unambiguous, several
        // without a stated default is not, so nothing is guessed.
        return all.count == 1 ? all[0] : nil
    }

    /// Every environment under `.azure` that has actually been provisioned, in
    /// folder order.
    ///
    /// The resource group is the test. An environment that has been created but
    /// never provisioned has a `.env` with a name and a subscription in it and
    /// no group, and treating that as provisioned would put a link to a 404 in
    /// the corner of the window.
    static func provisionedEnvironments(inAzureDirectory dot: URL) -> [AzureEnvironment] {
        let files = FileManager.default
        guard files.fileExists(atPath: dot.path) else { return [] }

        return ((try? files.contentsOfDirectory(atPath: dot.path)) ?? [])
            .sorted()
            .compactMap { folder in
                let file = dot.appendingPathComponent(folder)
                    .appendingPathComponent(".env")
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
                let values = parse(env: text)
                guard let group = values["AZURE_RESOURCE_GROUP"], !group.isEmpty
                else { return nil }
                return AzureEnvironment(name: values["AZURE_ENV_NAME"] ?? folder,
                                        folder: folder,
                                        resourceGroup: group,
                                        subscription: values["AZURE_SUBSCRIPTION_ID"],
                                        location: values["AZURE_LOCATION"],
                                        tenant: values["AZURE_TENANT_ID"])
            }
    }

    // MARK: The two file formats

    static func defaultEnvironment(inConfig data: Data) -> String? {
        let json = try? JSONSerialization.jsonObject(with: data)
        let name = (json as? [String: Any])?["defaultEnvironment"] as? String
        return (name?.isEmpty ?? true) ? nil : name
    }

    /// `KEY=value`, as `azd` writes it.
    ///
    /// Quoted more often than not, because half these values contain characters
    /// a shell would otherwise eat. Values can also contain `=` — a connection
    /// string routinely does — so the split is at the *first* one only.
    static func parse(env text: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                  let split = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<split]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: split)...])
                .trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, let last = value.last,
               first == last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty { values[key] = value }
        }
        return values
    }

    /// `name:` from `azure.yaml`.
    ///
    /// Read with a line scan rather than a YAML parser. The whole of what's
    /// wanted is one top-level scalar at the top of a file with a fixed schema,
    /// and adding a dependency to this app so it can read one string would be a
    /// poor trade.
    static func projectName(inManifest file: URL) -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("name:") else { continue }
            let value = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !value.isEmpty { return value }
        }
        return nil
    }
}

// MARK: - Showing it

/// Where this session deploys to.
///
/// Sits under the View pill, in the corner that answers "what am I looking at".
/// The chip is a link, because the two things you do with a resource group are
/// read its name and go to it.
///
/// It used to have a sibling naming the repository, which went: `owner/repo`
/// restates the folder you can already see in the sidebar and the title bar,
/// and the one genuinely useful thing about the repository — *which GitHub
/// account you're about to push as* — was the one thing it couldn't tell you.
/// That question moved into the View pill above, where it's answerable rather
/// than merely displayable.
struct ProjectBadge: View {
    let directory: URL
    let glass: Bool
    /// Symbol only, for the gutter beside a split pane. The label moves into
    /// the tooltip, which already carried the detail anyway.
    var compact = false

    @State private var project: AzureProject?

    var body: some View {
        VStack(alignment: .trailing, spacing: Theme.s3) {
            if let azure = project {
                chip(symbol: "square.stack.3d.up",
                     text: azure.label,
                     help: azureHelp(azure),
                     url: portalURL(azure))
            }
        }
        .animation(Motion.panel, value: project)
        // Re-read when the session changes, and again whenever you come back to
        // the window — `azd up` happens in a terminal, and the interesting
        // moment is the one where a declared project becomes a provisioned one.
        .task(id: directory) { await refresh() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    private func refresh() async {
        project = await Task.detached(priority: .utility) {
            ProjectDetector.azure(near: directory)
        }.value
    }

    /// Built to the same recipe as the View pill above it — same type sizes,
    /// same padding, same surface — because these are siblings in one corner and
    /// anything that isn't identical reads as a mistake rather than a variation.
    private func chip(symbol: String, text: String, help: String, url: URL?) -> some View {
        Button { if let url { NSWorkspace.shared.open(url) } } label: {
            HStack(spacing: Theme.s2 - 1) {
                Image(systemName: symbol)
                    .font(.system(size: compact ? 13 : 10, weight: .medium))
                if !compact {
                    Text(Self.shorten(text))
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, compact ? 0 : Theme.s4)
            .padding(.vertical, Theme.s2)
            .frame(width: compact ? 28 : nil, height: compact ? 24 : nil)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverCapsule())
        .disabled(url == nil)
        // Compact, the name is only in here — so it leads.
        .help(compact ? text + "\n" + help : help)
        .padding(.horizontal, glass && !compact ? Theme.s4 : 0)
        .padding(.vertical, glass && !compact ? Theme.s3 : 0)
        .modifier(StatusSurface(glass: glass && !compact))
    }

    /// Shortened as a *string*, not as a frame.
    ///
    /// A width cap on the view makes every pill that wide, so a nine-character
    /// resource group got the same pill as a forty-character one and the corner
    /// grew a slab. Ellipsising the text instead lets each pill hug what it
    /// holds, which is what makes them look like the one above them.
    ///
    /// The middle goes rather than the end: `owner/repository` is identified by
    /// both halves, and `rg-wdcoe-…` could be any environment of the four.
    static func shorten(_ text: String, to limit: Int = 34) -> String {
        guard text.count > limit else { return text }
        let head = (limit - 1) / 2
        return text.prefix(head) + "…" + text.suffix(limit - 1 - head)
    }

    private func azureHelp(_ azure: AzureProject) -> String {
        switch azure {
        case .provisioned(let environment):
            var lines = ["Resource group \(environment.resourceGroup)",
                         "Environment \(environment.name)"]
            if let location = environment.location { lines.append("Region \(location)") }
            // Which account this belongs to, not just which group. The chip
            // can't say — it's one line — but the group name alone doesn't
            // identify anything when you work across more than one
            // subscription, and this is the question you're asking when you
            // hover it.
            lines += Self.accountLines(environment)
            lines.append(environment.portalURL == nil
                         ? "No subscription recorded, so there's nothing to open"
                         : "Open in the Azure portal")
            return lines.joined(separator: "\n")

        case .ambiguous(let all):
            var lines = ["\(all.count) provisioned environments here, "
                         + "and nothing recording which is current:"]
            lines += all.map { environment in
                var line = "· \(environment.name) — \(environment.resourceGroup)"
                if let subscription = environment.subscription, !subscription.isEmpty {
                    line += " (\(Self.shortID(subscription)))"
                }
                return line
            }
            lines.append("Run `azd env select <name>` to choose one.")
            return lines.joined(separator: "\n")

        case .declared(let name):
            return "\(name) is an Azure Developer CLI project\n"
                + "Nothing has been provisioned from this checkout yet, "
                + "so there's no resource group to open."
        }
    }

    private func portalURL(_ azure: AzureProject) -> URL? {
        if case .provisioned(let environment) = azure { return environment.portalURL }
        return nil
    }

    /// Subscription and tenant, when they're recorded.
    ///
    /// Both are GUIDs, which nobody reads as a whole — the first segment is
    /// enough to tell two accounts apart, and that's all this is for. The full
    /// value stays out: a tooltip is for recognising something, not copying it.
    private static func accountLines(_ environment: AzureEnvironment) -> [String] {
        var lines: [String] = []
        if let subscription = environment.subscription, !subscription.isEmpty {
            lines.append("Subscription \(shortID(subscription))")
        }
        if let tenant = environment.tenant, !tenant.isEmpty {
            lines.append("Tenant \(shortID(tenant))")
        }
        return lines
    }

    private static func shortID(_ id: String) -> String {
        id.split(separator: "-").first.map(String.init) ?? id
    }
}
