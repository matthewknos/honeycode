import SwiftUI
import AppKit

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
        // The chip is entirely about Azure — it names a resource group and
        // links to the portal — so with Azure switched off there is nothing
        // here to draw and no reason to walk the directory looking for an
        // `azure.yaml` that would not be shown.
        guard Features.isOn(.azure) else { return project = nil }
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
                        .font(Theme.label)
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
