import AppKit

/// Writes a PNG of the app's own window when sent `SIGUSR1`.
///
///     kill -USR1 $(pgrep Honeycode)     # -> /tmp/claude-shots/honeycode-latest.png
///
/// This exists because the obvious way to show someone — or something — what
/// the app currently looks like is `screencapture`, and on a managed Mac that
/// route is closed. Screen Recording is a TCC grant that needs an admin to
/// authorise, this account is not one, and `screencapture` doesn't fail loudly
/// when refused — it hands back an empty image.
///
/// An app photographing *itself* is a different question. The window-list
/// capture is gated on Screen Recording only for windows belonging to *other*
/// processes; without the grant it still returns the caller's own windows and
/// blanks everyone else's. So the capture that is refused from outside is
/// allowed from inside, and needs nothing enabled.
///
/// A signal is the trigger rather than a menu item because the caller is
/// usually not a person — one shell line is the whole interface, and it works
/// from a build script or over SSH.
enum SelfCapture {

    /// Kept alive deliberately: a `DispatchSource` stops delivering the moment
    /// it deallocates, so a local in `install()` would unregister itself as
    /// soon as the function returned.
    private static var source: DispatchSourceSignal?

    static func install() {
        guard source == nil else { return }
        // SIGUSR1's default disposition is *terminate*. Without this the first
        // screenshot request would quit the app rather than photograph it — the
        // dispatch source observes the signal, it doesn't suppress the default.
        signal(SIGUSR1, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        src.setEventHandler { capture() }
        src.resume()
        source = src
    }

    /// `/tmp` rather than the project, so a screenshot never shows up in
    /// `git status` as something to explain.
    private static var directory: URL {
        let env = ProcessInfo.processInfo.environment["HONEYCODE_SHOT_DIR"]
        return URL(fileURLWithPath: env ?? "/tmp/claude-shots", isDirectory: true)
    }

    @discardableResult
    static func capture() -> URL? {
        // The key window is what "the app right now" means when a popped-out
        // conversation is in front. The largest-visible fallback covers focus
        // being in another app entirely, which is the normal case when the
        // trigger came from a shell.
        let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows
            .filter { $0.isVisible && $0.contentView != nil }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }

        guard let window else { return log("no visible window") }
        guard let image = composited(window) ?? drawn(window) else {
            return log("could not render window")
        }

        let rep = NSBitmapImageRep(cgImage: image)
        // The capture is at Retina scale, so the bitmap is 2x the window's
        // point size. Stating the point size keeps the PNG honest about what
        // it is a picture of.
        rep.size = window.frame.size
        guard let png = rep.representation(using: .png, properties: [:]) else {
            return log("PNG encoding failed")
        }

        let stamp = DateFormatter()
        stamp.dateFormat = "HHmmss"
        let dir = directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dated = dir.appendingPathComponent("honeycode-\(stamp.string(from: Date())).png")
        // A second copy at a fixed name: the common request is "what does it
        // look like now", which shouldn't require listing a directory to find
        // out what the file ended up being called.
        let latest = dir.appendingPathComponent("honeycode-latest.png")
        do {
            try png.write(to: dated)
            try png.write(to: latest)
        } catch { return log("\(error)") }

        return log("wrote \(dated.path)", value: dated)
    }

    // MARK: - The two ways to get pixels

    private typealias WindowListImage =
        @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// What the screen actually shows: real compositing, so materials, blur,
    /// vibrancy and the title bar all come out right.
    ///
    /// Reached through `dlsym` because `CGWindowListCreateImage` was *obsoleted*
    /// in the macOS 15 SDK — not deprecated, unavailable, so naming it fails the
    /// build. The symbol is still in CoreGraphics and still honours the
    /// own-window exemption; ScreenCaptureKit, the sanctioned replacement,
    /// requires the very grant this file exists to do without. So the old call
    /// stays, behind a fallback, until it genuinely stops answering.
    private static func composited(_ window: NSWindow) -> CGImage? {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
                                  RTLD_NOW),
              let symbol = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        let call = unsafeBitCast(symbol, to: WindowListImage.self)
        // 8 = kCGWindowListOptionIncludingWindow.
        // 9 = kCGWindowImageBoundsIgnoreFraming | kCGWindowImageBestResolution.
        return call(.null, 8, CGWindowID(window.windowNumber), 9)?.takeRetainedValue()
    }

    /// Drawing the view hierarchy by hand — no window server involved, so it
    /// works for a minimised or off-screen window that has no composited form
    /// to copy.
    ///
    /// Lower fidelity, and worth naming so the difference isn't mistaken for a
    /// regression: this path renders the content view only, so there is no
    /// title bar, and materials come out flat rather than translucent.
    private static func drawn(_ window: NSWindow) -> CGImage? {
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }

    @discardableResult
    private static func log(_ message: String, value: URL? = nil) -> URL? {
        FileHandle.standardError.write("SelfCapture: \(message)\n".data(using: .utf8)!)
        return value
    }
}
