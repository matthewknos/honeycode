import Foundation

// What is actually listening, and what that does to a scraped dev-server URL.
//
// Tested against a real socket rather than a stub. The whole point of
// `Listeners` is that it reads the kernel instead of trusting text, so a fake
// would test the one thing that isn't in question. This suite binds a port,
// asks whether it can see it, and lets it go.

var failures = 0
func check(_ what: String, _ ok: Bool) {
    print(ok ? "  ok   \(what)" : "  FAIL \(what)")
    if !ok { failures += 1 }
}

// --- a socket we control -----------------------------------------------------

/// Bind a loopback port in this process and hand back its number.
///
/// In-process on purpose. A child would be a second thing to reap and would
/// test whether we can see *another* process's sockets, which is the case the
/// privilege note in `Listeners` already covers — the interesting question here
/// is whether a listening TCP socket in a directory is found at all.
func listen(on address: in_addr_t) -> (fd: Int32, port: UInt16)? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var yes: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = address
    addr.sin_port = 0  // let the kernel choose, so the suite never collides
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0, Darwin.listen(fd, 1) == 0 else { close(fd); return nil }

    var actual = sockaddr_in()
    var size = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &actual) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
    }
    guard named == 0 else { close(fd); return nil }
    return (fd, UInt16(bigEndian: actual.sin_port))
}

let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

print("a bound loopback port")
guard let local = listen(on: inet_addr("127.0.0.1")) else {
    print("  FAIL could not bind a loopback port")
    exit(1)
}

let mine = Listeners.inside(here)
let found = mine.first { $0.port == local.port }
check("it is found under the working directory", found != nil)
check("with this process's pid", found?.pid == getpid())
check("and read as local rather than exposed", found?.exposure == .loopback)
check("which is what the dot is drawn from", found?.exposure.isExposed == false)
check("its url is one a browser can ask for",
      found?.url?.absoluteString == "http://127.0.0.1:\(local.port)")

// A directory nothing is working in has nothing in it. `/` is safe to name:
// this process is not running there, so its socket must not be attributed to it.
let elsewhere = Listeners.inside(URL(fileURLWithPath: "/var/empty"))
check("and not found under an unrelated directory",
      !elsewhere.contains { $0.port == local.port })

// --- exposure ----------------------------------------------------------------
//
// The distinction the app never used to make: a server on every interface is
// readable by everyone on the network, and an agent binds one by accident
// roughly as often as on purpose, because that is what the framework's own
// example does.

print("")
print("a port bound to every interface")
if let any = listen(on: INADDR_ANY.bigEndian) {
    let wide = Listeners.inside(here).first { $0.port == any.port }
    check("is read as exposed", wide?.exposure == .everywhere)
    check("and says so", wide?.exposure.isExposed == true)
    check("but is still offered as localhost, which is the only address that connects",
          wide?.url?.absoluteString == "http://localhost:\(any.port)")
    close(any.fd)
} else {
    check("could bind INADDR_ANY", false)
}

// --- confirming a scraped URL ------------------------------------------------

print("")
print("holding a scraped URL up against what is listening")

let live = URL(string: "http://localhost:\(local.port)/admin")!
check("a live port keeps its url, path and all",
      DevServer.confirm(live, in: here) == live)

// A port nothing is bound to. 1 is privileged and nothing in this suite can
// have taken it, so it stands in for "the server that has gone".
let dead = URL(string: "http://localhost:1/admin")!
let corrected = DevServer.confirm(dead, in: here)
check("a dead port is replaced by one that is real",
      corrected != dead && corrected?.port != 1)
check("and the path goes with it, being a guess about a different server",
      corrected?.path.isEmpty ?? false)

check("nothing scraped still finds a server nobody announced",
      DevServer.confirm(nil, in: here) != nil)

// The conservative half. A directory with no observable processes tells us
// nothing about whether the scraped server is alive — it could be in a
// container, on another account, or on a remote box — so the answer is left
// alone rather than cleared.
let unseen = URL(fileURLWithPath: "/var/empty")
check("a directory we can see nothing in leaves the scraped url alone",
      DevServer.confirm(dead, in: unseen) == dead)
check("and offers nothing when there was nothing",
      DevServer.confirm(nil, in: unseen) == nil)

close(local.fd)

// --- and it lets go ----------------------------------------------------------

print("")
print("after the socket closes")
check("the port stops being listed",
      !Listeners.inside(here).contains { $0.port == local.port })

print(failures == 0 ? "Ports: all ok" : "Ports: \(failures) failed")
exit(failures == 0 ? 0 : 1)
