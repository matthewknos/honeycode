import Foundation

/// One ACP-speaking CLI, and the handful of ways it differs from the others.
///
/// Both agents speak the same protocol — newline-delimited JSON-RPC 2.0, the
/// same `session/update` discriminators, the same blocking
/// `session/request_permission` — so the adapter is shared. What differs is
/// small and entirely declarative: what to launch, and where the model list
/// lives. Keeping those four facts here rather than as `if account == .kimi`
/// branches inside the adapter is what stops a third agent turning it into a
/// switch statement with a stream parser attached.
/// One ACP-speaking CLI, and the handful of ways it differs from the others.
///
/// Every agent here speaks the same protocol — newline-delimited JSON-RPC 2.0,
/// the same `session/update` discriminators, the same blocking
/// `session/request_permission` — so the adapter is shared. What differs is
/// small and entirely declarative: what to launch, and where the model list
/// lives. Keeping those facts here rather than as `if account == .kimi`
/// branches inside the adapter is what stopped a third agent turning it into a
/// switch statement with a stream parser attached.
///
/// It is a record rather than an enum for exactly that reason, taken one step
/// further: a *fourth* agent — one this app has never heard of, added by
/// whoever is running it — is now the same kind of thing as the two that ship
/// with it. `kimi` and `copilot` are values of this type, not cases of it, and
/// nothing in the adapter can tell the difference.
struct ACPAgent: Equatable, Hashable {

    /// Stable, and the key a custom agent's definition is stored under.
    let id: String
    /// What to call it when something goes wrong — "couldn't start `kimi`".
    let displayName: String
    /// The tool to run. A bare name is looked for in the usual places; anything
    /// containing a slash is taken as the path it is.
    let command: String
    let arguments: [String]
    /// Whether this is a Node program, which brings two problems with it — see
    /// `environment`. Nearly every agent CLI is.
    let isNode: Bool
    let dialect: Dialect
    let usageReports: UsageKind
    /// Handed to the child on top of the app's own environment. Where an API
    /// key goes for a CLI that authenticates with one.
    var extraEnvironment: [String: String] = [:]

    /// Which spelling of ACP this agent actually speaks.
    ///
    /// The protocol has one way to list models and one way to change them;
    /// Kimi has another. Rather than ask whoever adds an agent to describe a
    /// JSON path, they pick which of the two it behaves like — and `standard`
    /// is the right guess for anything written against the spec.
    enum Dialect: String, Codable, CaseIterable {
        /// ACP's own `models.availableModels` and `session/set_model`.
        case standard
        /// The model as one select among several in `configOptions`, changed
        /// with `session/set_config_option`. Kimi's spelling.
        case configOptions

        var title: String {
            self == .standard ? "Standard ACP" : "Config options (Kimi-style)"
        }
    }

    /// What `/usage` reports, if the agent knows the command at all.
    ///
    /// `none` matters more than it looks. A slash command an agent doesn't know
    /// is not an error, it's a prompt: it reaches the model as the literal text
    /// "/usage", costs a request, and comes back as a puzzled paragraph. An
    /// agent nobody has checked should be asked nothing.
    enum UsageKind: String, Codable, CaseIterable {
        case credits, context, none

        var title: String {
            switch self {
            case .credits: return "Credits used"
            case .context: return "Context window"
            case .none:    return "Doesn't report usage"
            }
        }
    }

    /// `/context` exists only where `/usage` reports credits — an agent that
    /// answers `/usage` with the context window has already said it.
    var hasContextCommand: Bool { usageReports == .credits }

    // MARK: The two that ship

    static let copilot = ACPAgent(
        id: "copilot", displayName: "copilot", command: "copilot",
        arguments: ["--acp"], isNode: false,
        dialect: .standard, usageReports: .credits)

    static let kimi = ACPAgent(
        id: "kimi", displayName: "kimi", command: "kimi",
        arguments: ["acp"], isNode: true,
        dialect: .configOptions, usageReports: .context)

    // MARK: Finding it

    /// Where the binary usually is, best first.
    ///
    /// Absolute paths rather than a `PATH` search: an app launched from Finder
    /// inherits launchd's `PATH`, which is `/usr/bin:/bin:/usr/sbin:/sbin` and
    /// contains neither Homebrew nor nvm.
    var binaryCandidates: [String] {
        // Somebody who has given a path means that path. Searching for the
        // basename of it in three other directories would be second-guessing
        // the one piece of information they were most sure about.
        guard !command.contains("/") else {
            return [(command as NSString).expandingTildeInPath]
        }
        let home = NSHomeDirectory()
        let fixed = [home + "/.local/bin/" + command,
                     "/opt/homebrew/bin/" + command,
                     "/usr/local/bin/" + command]
        // nvm installs per Node version, so the path carries a version number
        // that will change under us. The fixed locations are tried first and
        // the nvm tree is searched only if none of them hit.
        return isNode ? fixed + Self.nvmCandidates(for: command) : fixed
    }

    /// Every nvm-installed copy of a tool, newest version first.
    ///
    /// Sorted rather than taken in directory order, because `readdir` returns
    /// v18 before v24 as often as not and the shim in an old Node version may
    /// not even run.
    private static func nvmCandidates(for tool: String) -> [String] {
        let root = NSHomeDirectory() + "/.nvm/versions/node"
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        return versions
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { "\(root)/\($0)/bin/\(tool)" }
    }

    /// Environment the child needs beyond the app's own.
    func environment(binary: URL) -> [String: String] {
        var extra = extraEnvironment
        // Every agent here runs shell commands on your behalf and would
        // otherwise inherit this app's PATH, which launched from Finder is
        // launchd's four directories — see `Shell.toolPath` for what that costs.
        extra["PATH"] = Shell.toolPath
        guard isNode else { return extra }

        // Two problems, both peculiar to a Node CLI launched from a GUI app.
        //
        // First, the tool is usually a shim with `#!/usr/bin/env node` at the
        // top, so `node` itself has to be findable — and on a machine using nvm
        // the only copy lives beside the shim in a version directory that isn't
        // on launchd's PATH.
        let nodeDirectory = binary.deletingLastPathComponent().path
        extra["PATH"] = nodeDirectory + ":" + Shell.toolPath

        // Second, Node ships its own CA list and ignores the system keychain.
        // Behind a TLS-inspecting proxy — Zscaler, on this machine — every
        // request it makes fails with "unable to get local issuer certificate".
        // The failure is silent in ACP: the OAuth refresh fails, the turn ends
        // with `stopReason: end_turn` and no content, and the agent looks like
        // it simply had nothing to say.
        //
        // Only ever *adds* roots the operating system already trusts, and never
        // overrides a value set here or inherited.
        if extra["NODE_EXTRA_CA_CERTS"] == nil,
           ProcessInfo.processInfo.environment["NODE_EXTRA_CA_CERTS"] == nil,
           let bundle = SystemTrust.caBundle() {
            extra["NODE_EXTRA_CA_CERTS"] = bundle.path
        }
        return extra
    }

    // MARK: The model list

    /// Pull the available models out of a `session/new` reply.
    ///
    /// The account comes in because the answer is worth remembering and only
    /// the caller knows whose list this is — it used to be written against
    /// `.kimi` by name, which was true of the only agent that took this branch
    /// and would have been silently wrong for the next one.
    func models(fromSessionReply result: [String: Any], for account: Account) -> [AgentModel] {
        switch dialect {
        case .standard:
            guard let models = result["models"] as? [String: Any],
                  let list = models["availableModels"] as? [[String: Any]] else { return [] }
            return ModelCatalog.copilotModels(list)
        case .configOptions:
            guard let option = Self.configOption("model", in: result),
                  let list = option["options"] as? [[String: Any]] else { return [] }
            let models = list.compactMap { entry -> AgentModel? in
                guard let value = entry["value"] as? String else { return nil }
                return AgentModel(id: value,
                                  title: entry["name"] as? String ?? value,
                                  blurb: "",
                                  family: displayName.capitalized)
            }
            ModelCatalog.remember(models, for: account)
            return models
        }
    }

    /// Which model the agent is currently on, if it says.
    func currentModel(fromSessionReply result: [String: Any]) -> String? {
        switch dialect {
        case .standard:
            return (result["models"] as? [String: Any])?["currentModelId"] as? String
        case .configOptions:
            return Self.configOption("model", in: result)?["currentValue"] as? String
        }
    }

    private static func configOption(_ id: String,
                                     in result: [String: Any]) -> [String: Any]? {
        (result["configOptions"] as? [[String: Any]])?
            .first { $0["id"] as? String == id }
    }

    /// The request that changes the model, which is not the same call on both.
    ///
    /// Standard ACP has a dedicated `session/set_model`. Kimi treats the model
    /// as one config option among several and takes `session/set_config_option`
    /// with a `configId` — spelled that way, not `configOptionId`, which fails
    /// with a bare "Invalid params".
    func setModelRequest(sessionID: String, modelID: String)
    -> (method: String, params: [String: Any]) {
        switch dialect {
        case .standard:
            return ("session/set_model", ["sessionId": sessionID, "modelId": modelID])
        case .configOptions:
            return ("session/set_config_option",
                    ["sessionId": sessionID, "configId": "model", "value": modelID])
        }
    }
}

/// The machine's trusted roots, as a PEM file.
///
/// Exists for tools that carry their own certificate authority list instead of
/// asking the operating system — which is every Node program. On a machine
/// behind a TLS-inspecting proxy those tools fail on every HTTPS request while
/// `curl` and Safari work fine, and the error they give ("unable to get local
/// issuer certificate") points at the tool rather than at the proxy.
enum SystemTrust {

    /// Regenerated once per launch, and never trusted because it looks recent.
    ///
    /// This file is a trust store: it's handed to Node through
    /// `NODE_EXTRA_CA_CERTS`, so every root in it is a root the agent's HTTPS
    /// traffic will accept — its OAuth refresh included. Two things followed
    /// from the old version, which wrote it at default permissions and reused
    /// it for a week based on mtime. Any process running as you could append a
    /// root of its own; and `touch` on the file bought that root another week,
    /// because the freshness check was the mtime and nothing else.
    ///
    /// So: rebuilt from the keychains on every launch (a couple of `security`
    /// calls, once), and written 0600 so only you can write it. Neither is a
    /// real boundary against something already running as you — nothing in an
    /// unsandboxed app is — but it stops the file being a *quiet* one-way door,
    /// where poisoning it once outlives the poisoning.
    private nonisolated(unsafe) static var generated: URL?
    private static let lock = NSLock()

    static func caBundle() -> URL? {
        lock.lock()
        let done = generated
        lock.unlock()
        if let done { return done }

        let folder = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Honeycode", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("system-roots.pem")

        // Both keychains: the first holds Apple's shipped roots, the second the
        // ones an administrator installed — which is where a corporate proxy's
        // root lands, and the only one that actually matters here.
        let pem = ["/System/Library/Keychains/SystemRootCertificates.keychain",
                   "/Library/Keychains/System.keychain"]
            .compactMap { keychain -> String? in
                guard let security = Shell.locate("security") else { return nil }
                let result = Shell.run(security, ["find-certificate", "-a", "-p", keychain])
                return result.ok ? result.out : nil
            }
            .joined(separator: "\n")

        guard pem.contains("BEGIN CERTIFICATE"),
              (try? pem.write(to: url, atomically: true, encoding: .utf8)) != nil
        else { return nil }
        // After the write, not before: `write(atomically:)` replaces the file
        // by rename, so anything set on the old one is gone.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: url.path)
        lock.lock()
        generated = url
        lock.unlock()
        return url
    }
}
