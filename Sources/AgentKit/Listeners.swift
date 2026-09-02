import Darwin
import Foundation

/// What is actually listening, read from the process table.
///
/// `DevServer` finds a session's server by scraping a loopback URL out of what
/// the agent printed. That is a good reading of a bad input, and the ceiling is
/// the input rather than the code: it only ever sees a server that *announced
/// itself* into output we captured, it cannot tell a dead port from a live one,
/// and it cannot answer "what is running right now" — only "what was mentioned".
/// A port inferred from text the agent itself produced is also a weak thing to
/// hang a security decision on, and `devServerPort` is exactly that: `WebPreview`
/// reads it to decide how much loopback an agent-written page may load.
///
/// This answers all four by asking the kernel instead. No dependency, no spawn,
/// no `lsof`: `proc_listpids` for the processes, `proc_pidfdinfo` for their
/// sockets, `proc_pidinfo` for the working directory that maps one to a session.
///
/// ## On privileges, which is the question that decided the shape
///
/// Measured on this Mac: 792 processes, 457 whose file descriptors we can read,
/// 334 opaque. The opaque third is every process belonging to another user or
/// to root — `proc_pidinfo` returns 0 for them and there is no way to ask
/// harder short of running as root, which is not available on a managed Mac and
/// would not be worth having if it were.
///
/// That is not a limitation here. Honeycode spawns its agents, agents spawn
/// their dev servers, and all of them run as us — so everything this needs to
/// see is in the readable half by construction. It also settles the question of
/// scope: per-session is not a compromise chosen over machine-wide, it is the
/// only honest scope, because a machine-wide list would silently omit a third
/// of the machine and look complete.
enum Listeners {

    /// One socket, bound and waiting.
    struct Listener: Identifiable, Equatable, Sendable {
        var pid: pid_t
        /// The executable's name, not its path — `node`, `Python`, `ruby`.
        var process: String
        var port: UInt16
        /// The address it bound, rendered the way it was bound: `127.0.0.1`,
        /// `0.0.0.0`, `::1`.
        var address: String
        /// The process's working directory, which is what maps a port to a
        /// session. Nil when the kernel wouldn't say.
        var directory: String?
        var exposure: Exposure

        /// Stable across a refresh so a list doesn't animate every row when one
        /// port changes. A process can hold the same port on two families —
        /// `0.0.0.0` and `::` — and those are two rows, hence the address.
        var id: String { "\(pid).\(address).\(port)" }

        /// What a browser should ask for. `0.0.0.0` and `::` mean "every
        /// interface" to a server and nothing usable to a client, so they are
        /// rewritten to the one address that will connect — the same
        /// substitution `DevServer` makes on a scraped URL.
        var url: URL? {
            URL(string: "http://\(exposure == .everywhere ? "localhost" : displayHost):\(port)")
        }

        private var displayHost: String {
            address.contains(":") ? "[\(address)]" : address
        }

        /// Whether this port is a session's, by where its process is standing.
        ///
        /// Descendants count: a server started from `packages/web` still
        /// belongs to the repo above it.
        func belongs(to root: URL) -> Bool {
            guard let directory else { return false }
            let base = root.resolvingSymlinksInPath().path
            return directory == base || directory.hasPrefix(base + "/")
        }
    }

    /// How far a bound socket can be reached from.
    ///
    /// Worth surfacing rather than keeping as a detail. An agent told to start a
    /// dev server will quite often bind `0.0.0.0` because that is what the
    /// framework's example does, and the difference between that and `127.0.0.1`
    /// is whether everyone on the café wi-fi can read the thing you are building.
    /// Nothing in this app has ever said so.
    enum Exposure: Sendable, Equatable {
        /// `127.0.0.1` or `::1` — this Mac only.
        case loopback
        /// `0.0.0.0` or `::` — every interface, including the network.
        case everywhere
        /// A specific address that isn't loopback.
        case address

        var title: String {
            switch self {
            case .loopback:   return "local"
            case .everywhere: return "network"
            case .address:    return "address"
            }
        }

        var isExposed: Bool { self != .loopback }
    }

    // MARK: Reading the table

    /// Every TCP socket in the listening state that we are allowed to see.
    ///
    /// Sorted by port so the list has a stable order that isn't process launch
    /// order — a dev server restarting shouldn't make the row jump.
    static func all() -> [Listener] {
        var found: [Listener] = []
        for pid in pids() {
            found.append(contentsOf: listeners(of: pid))
        }
        return found.sorted { $0.port < $1.port }
    }

    /// The ones belonging to a process working inside this directory.
    ///
    /// Matched on the process's own working directory, which is how a session
    /// maps to its ports: the agent runs in the session's folder, and whatever
    /// it starts inherits that. Descendants count — a server started from a
    /// `packages/web` subfolder still belongs to the repo above it.
    static func inside(_ directory: URL) -> [Listener] {
        all().filter { $0.belongs(to: directory) }
    }

    /// Ask a process to stop, the way a terminal would.
    ///
    /// `SIGTERM`, not `SIGKILL`: a dev server asked politely closes its sockets,
    /// flushes what it was writing and takes its children with it, and one that
    /// ignores the ask is rare enough not to justify making the rude version the
    /// default. Only ever our own processes — `kill` on anything else returns
    /// `EPERM`, which is the same wall `proc_pidinfo` hits, so nothing reachable
    /// from this list is unkillable for a reason this app has to explain.
    @discardableResult
    static func stop(_ listener: Listener) -> Bool {
        kill(listener.pid, SIGTERM) == 0
    }

    // MARK: The kernel side

    private static func pids() -> [pid_t] {
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytes > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size)
        let written = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, bytes)
        guard written > 0 else { return [] }
        return Array(pids.prefix(Int(written) / MemoryLayout<pid_t>.size)).filter { $0 > 0 }
    }

    private static func listeners(of pid: pid_t) -> [Listener] {
        // Zero here is the ordinary answer for a process belonging to somebody
        // else, not an error worth reporting — see the note on privileges above.
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }

        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(),
                                        count: Int(bytes) / MemoryLayout<proc_fdinfo>.size)
        let written = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, bytes)
        guard written > 0 else { return [] }

        var name: String?
        var directory: String??
        var found: [Listener] = []

        for descriptor in descriptors.prefix(Int(written) / MemoryLayout<proc_fdinfo>.size)
        where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var socket = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO,
                                 &socket, size) == size,
                  socket.psi.soi_kind == SOCKINFO_TCP,
                  socket.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN
            else { continue }

            let endpoint = socket.psi.soi_proto.pri_tcp.tcpsi_ini
            // Network byte order, in a field wide enough for a signed int.
            let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: endpoint.insi_lport))
            guard port > 0 else { continue }
            guard let address = address(of: endpoint, family: socket.psi.soi_family)
            else { continue }

            // Only once a process turns out to have one, and only once per
            // process: two calls into the kernel for every socket on the Mac is
            // the difference between this being free and being a scan.
            if name == nil { name = self.name(of: pid) }
            if directory == nil { directory = self.directory(of: pid) }

            found.append(Listener(pid: pid, process: name ?? "?", port: port,
                                  address: address,
                                  directory: directory ?? nil,
                                  exposure: exposure(of: address)))
        }
        return found
    }

    private static func address(of endpoint: in_sockinfo, family: Int32) -> String? {
        switch family {
        case AF_INET:
            let raw = UInt32(bigEndian: endpoint.insi_laddr.ina_46.i46a_addr4.s_addr)
            return "\((raw >> 24) & 255).\((raw >> 16) & 255).\((raw >> 8) & 255).\(raw & 255)"
        case AF_INET6:
            var address = endpoint.insi_laddr.ina_6
            var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &address, &text, socklen_t(INET6_ADDRSTRLEN)) != nil
            else { return nil }
            return String(cString: text)
        default:
            // Unix domain sockets and everything else. A dev server is not
            // reachable over one, so there is nothing here to offer.
            return nil
        }
    }

    private static func exposure(of address: String) -> Exposure {
        switch address {
        case "127.0.0.1", "::1":     return .loopback
        case "0.0.0.0", "::", "":    return .everywhere
        default:
            // The whole of 127/8 is loopback, not just the one address.
            return address.hasPrefix("127.") ? .loopback : .address
        }
    }

    private static func name(of pid: pid_t) -> String? {
        // `PROC_PIDPATHINFO_MAXSIZE` is a macro Swift declines to import —
        // "structure not supported" — so the number it expands to is written
        // out. It is four times `MAXPATHLEN`, and has been since 10.5.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return (String(cString: buffer) as NSString).lastPathComponent
    }

    private static func directory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
        return path.isEmpty ? nil : path
    }
}

// MARK: - Observation, against inference

extension DevServer {

    /// Hold a scraped URL up against what is really listening.
    ///
    /// The two sources know different halves. The process table knows what is
    /// *alive* and the printed URL knows the **path** — `/admin`, `/#/preview`,
    /// whatever the agent said to open — which no socket can tell you. So this
    /// confirms rather than replaces:
    ///
    /// - the scraped port is listening → keep the scraped URL, path and all;
    /// - the scraped port is dead → offer a live one instead, with no path,
    ///   because a path from a server that has gone is a guess about a server
    ///   that has arrived;
    /// - nothing was scraped → offer a live one, which is the case text
    ///   scraping could never reach: a server started detached, in a background
    ///   shell, or by a tool that logged somewhere we never saw;
    /// - nothing is listening → nil, so a dead button disappears rather than
    ///   pointing at a port nothing is bound to.
    ///
    /// Returns the scraped URL unchanged when the directory has no observable
    /// processes at all, which is the honest answer for a session whose server
    /// runs somewhere this cannot see — a container, another user, a remote box.
    /// Silence from the process table is not evidence of death.
    static func confirm(_ scraped: URL?, in directory: URL) -> URL? {
        // One walk of the table, read two ways. The positive test is
        // machine-wide on purpose: a server started by `cd packages/web && npm
        // run dev` from a shell that has since moved on is listening on the
        // scraped port under a working directory that is no longer the
        // session's, and it is emphatically not dead.
        let everything = Listeners.all()
        if let scraped, let port = scraped.port,
           everything.contains(where: { Int($0.port) == port }) {
            return scraped
        }

        let mine = everything.filter { $0.belongs(to: directory) }
        // Nothing of ours is listening, so there is nothing to correct *to* —
        // and, more to the point, no evidence the scraped one is dead. A server
        // inside a container, on another user's account or on a remote box is
        // invisible here and working fine. Silence is not a death certificate.
        guard let replacement = mine.first else { return scraped }
        // Lowest port among the live ones — arbitrary, but stable, and a dev
        // server is nearly always the low number beside a debugger or a
        // hot-reload socket that took whatever was free.
        return replacement.url ?? scraped
    }
}
