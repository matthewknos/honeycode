import AppKit
import WebKit

/// The loopback port `test.sh` started a server on. Passed in rather than
/// hardcoded so a port already in use is the harness's problem to solve, not a
/// run that fails three checks and doesn't say why.
let PORT = Int(ProcessInfo.processInfo.environment["HONEYCODE_TEST_PORT"] ?? "") ?? 8749

// Exercises the shipped WebPreview.swift, not a copy of its logic: the rule
// text, the notify plumbing and `Loopback.permits` are the real ones.

var pass = 0, fail = 0
func check(_ name: String, _ ok: Bool) {
    if ok { pass += 1; print("  ok   \(name)") }
    else { fail += 1; print("  FAIL \(name)") }
}
func url(_ s: String) -> URL { URL(string: s)! }

print("Loopback.permits")
let all = WebPreview.Loopback.all
let port = WebPreview.Loopback.port(PORT)
let closed = WebPreview.Loopback.none

check("all permits any loopback port", all.permits(url("http://127.0.0.1:9999/x")))
check("all permits bare localhost", all.permits(url("http://localhost/x")))
check("all refuses the wider web", !all.permits(url("https://unpkg.com/three.js")))
check("all refuses a lookalike host", !all.permits(url("http://localhost.evil.example/x")))
check("all refuses userinfo smuggling",
      !all.permits(url("http://localhost:80@evil.example/x")))
check("port permits its own port", port.permits(url("http://127.0.0.1:\(PORT)/x")))
check("port refuses another port", !port.permits(url("http://127.0.0.1:11434/api")))
check("port refuses the implied port when it isn't ours",
      !port.permits(url("http://localhost/x")))
check("port 80 permits an elided port", WebPreview.Loopback.port(80).permits(url("http://localhost/x")))
check("none permits nothing on loopback", !closed.permits(url("http://127.0.0.1:\(PORT)/x")))
check("file is always permitted", closed.permits(url("file:///tmp/page.html")))

var keep: [AnyObject] = []
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

func view() -> WKWebView {
    let c = WKWebViewConfiguration()
    c.websiteDataStore = .nonPersistent()
    return WKWebView(frame: .init(x: 0, y: 0, width: 400, height: 300), configuration: c)
}

print("\ncompiling the real rule lists")
let modes: [(String, WebPreview.Loopback)] = [("all", .all), ("port", .port(PORT)),
                                              ("none", .none), ("port 80", .port(80))]
var remaining = modes.count
for (name, mode) in modes {
    // On main throughout: `WKWebView` is main-thread-only, and the compile
    // completion arrives wherever WebKit feels like calling it.
    DispatchQueue.main.async {
        WebPreview.installBlocklist(on: view(), loopback: mode) { sandboxed in
            DispatchQueue.main.async {
                check("\(name) compiles and installs", sandboxed)
                remaining -= 1
                if remaining == 0 { live() }
            }
        }
    }
}

@MainActor func live() {
    print("\nlive page, loopback limited to :\(PORT)")
    let web = WebController()
    let coordinator = WebPreview.Coordinator()
    coordinator.loopback = .port(PORT)
    coordinator.controller = web
    keep.append(coordinator)   // navigationDelegate is weak
    let v = view()
    v.navigationDelegate = coordinator
    WebPreview.installBlocklist(on: v, loopback: .port(PORT)) { sandboxed in
        DispatchQueue.main.async {
            guard sandboxed else { check("sandbox installed", false); exit(1) }
            v.load(URLRequest(url: url("http://127.0.0.1:\(PORT)/index.html")))
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                print("  loaded: \(v.url?.absoluteString ?? "nothing")")
                print("  reported: \(web.blocked)")
                check("the page itself loaded", v.url != nil)
                check("blocked <img> host reported", web.blocked.contains("unpkg.com"))
                check("blocked fetch host reported", web.blocked.contains("example.com"))
                check("allowed loopback stays quiet", !web.blocked.contains("127.0.0.1"))
                check("one entry per host", web.blocked.count == Set(web.blocked).count)

                print("\n  a second, allowed navigation")
                v.load(URLRequest(url: url("http://127.0.0.1:\(PORT)/index.html?second")))
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    check("the delegate is still live after a second load",
                          v.url?.query == "second")
                    check("the same page reports the same hosts, not twice as many",
                          web.blocked.count == 2)
                    starved()
                }
            }
        }
    }
}

/// Agent markup with no dev server: loopback itself is off limits, and the
/// panel should say so rather than showing an empty page.
@MainActor func starved() {
    print("\nstring markup, no dev server (loopback closed)")
    let web = WebController()
    let coordinator = WebPreview.Coordinator()
    coordinator.loopback = .none
    coordinator.controller = web
    keep.append(coordinator)
    let v = view()
    v.navigationDelegate = coordinator
    WebPreview.installBlocklist(on: v, loopback: .none) { sandboxed in
        DispatchQueue.main.async {
            v.loadHTMLString("<html><body><img src=\"http://127.0.0.1:\(PORT)/local.png\">"
                             + "<img src=\"https://fonts.googleapis.com/css\"></body></html>",
                             baseURL: nil)
            // A web view with no window never lays out, and images that are
            // never laid out are never fetched — so nothing would be blocked
            // and nothing reported. Touching the DOM forces the pass. The panel
            // is on screen in the app, so this is the harness catching up with
            // reality rather than staging it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                v.evaluateJavaScript("document.images.length") { _, _ in }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                print("  reported: \(web.blocked)")
                check("loopback is reported when it isn't granted",
                      web.blocked.contains("127.0.0.1"))
                check("the wider web is reported too",
                      web.blocked.contains("fonts.googleapis.com"))
                print("\n\(pass) passed, \(fail) failed")
                exit(fail == 0 ? 0 : 1)
            }
        }
    }
}

app.run()
