import SwiftUI
import AppKit
import Quartz

/// What's actually in that file.
///
/// Quick Look rather than a renderer of our own. It reads every format the
/// system knows — text, images, PDFs, video, archives — and it's the preview
/// this person has already seen a thousand times in the Finder, so there's
/// nothing to learn.
///
/// `QLPreviewView`, not the shared `QLPreviewPanel`. The panel is a singleton
/// driven through the responder chain, which means a SwiftUI view has to become
/// first responder and implement two informal protocols to feed it — and it
/// opens as a window of its own, floating over the app, for something that
/// belongs beside the chip you clicked. The view embeds.
private struct QuickLook: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        // `.compact` leaves out the Open-with button and the toolbar, which are
        // Finder furniture and would be the two largest things in a popover.
        let view = QLPreviewView(frame: .zero, style: .compact) ?? QLPreviewView()
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        // Only on a real change. Reassigning the same item reloads the preview,
        // which for a video means starting it again from the top on every
        // unrelated redraw.
        guard (view.previewItem as? NSURL) as URL? != url else { return }
        view.previewItem = url as NSURL
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        // Quick Look holds resources — a decoded image, a media session — until
        // it's told not to. A popover that's been opened and shut forty times
        // in a session shouldn't leave forty of those behind.
        view.close()
    }
}

/// A file the transcript has offered to show you.
///
/// Wrapped because `URL` isn't `Identifiable`, and `.sheet(item:)` wants
/// something that is.
struct PreviewTarget: Identifiable {
    let id = UUID()
    let url: URL
}

/// The preview, with the file's name and size above it.
struct FilePreview: View {
    let url: URL

    // MARK: Links out of the transcript

    /// The scheme the transcript's file links use.
    ///
    /// A scheme of our own rather than plain `file:` — SwiftUI would hand a
    /// `file:` URL to `NSWorkspace` and open the thing in whatever app owns
    /// it, which is a bigger action than "let me look at that" and one you
    /// can't undo by pressing Escape.
    static let scheme = "honeycode-preview"

    /// A link for a code span, if it names a file that's really there.
    ///
    /// Three filters, in cost order: it has to look like an absolute path
    /// before anything touches the disk, since a transcript is full of code
    /// spans and most of them are `--flags` and function names; then a `~` is
    /// expanded; then the file has to exist. A path the agent *intends* to
    /// write isn't a link until it does.
    static func link(for text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") || trimmed.hasPrefix("~/"),
              !trimmed.contains("\n"), trimmed.utf8.count < 4096 else { return nil }

        let path = NSString(string: trimmed).expandingTildeInPath
        guard isReadableFile(path) else { return nil }

        var components = URLComponents()
        components.scheme = scheme
        components.host = "file"
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        return components.url
    }

    /// Whether that path is a file, answered from a short-lived memo.
    ///
    /// The stat itself is cheap; doing it on the main thread sixty times a
    /// second for the same path is not. An agent announcing its work — "Done —
    /// `/Users/you/Desktop/Deck.pptx`" — puts a path-shaped code span in the
    /// block that is still streaming, and every tick re-renders that block and
    /// re-stats every span in it. On a network or sleeping volume a single stat
    /// can block a frame outright.
    ///
    /// Memoised with a deadline rather than permanently, and the deadline is
    /// the whole design. A path the agent is *about to* write answers false
    /// now and true in a moment, and the transcript is supposed to turn it into
    /// a link when that happens — a permanent negative would mean a file the
    /// agent just made never becomes clickable for the life of the window. Two
    /// seconds collapses a streaming burst into one syscall while keeping that
    /// promise on a human timescale.
    private nonisolated(unsafe) static var known: [String: (exists: Bool, at: Double)] = [:]
    private static let knownLock = NSLock()
    private static let memo: Double = 2

    private static func isReadableFile(_ path: String) -> Bool {
        let now = Date.timeIntervalSinceReferenceDate
        knownLock.lock()
        if let seen = known[path], now - seen.at < memo {
            knownLock.unlock()
            return seen.exists
        }
        knownLock.unlock()

        var isDirectory: ObjCBool = false
        let there = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue

        knownLock.lock()
        // A transcript names a bounded set of files; this is a guard against a
        // pathological reply rather than a working eviction policy, so it drops
        // everything stale rather than keeping an order alongside.
        if known.count > 512 { known = known.filter { now - $0.value.at < memo } }
        known[path] = (there, now)
        knownLock.unlock()
        return there
    }

    /// The file behind one of those links.
    static func target(of url: URL) -> URL? {
        guard url.scheme == scheme,
              let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                  .queryItems?.first(where: { $0.name == "path" })?.value
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    private var missing: Bool { !FileManager.default.fileExists(atPath: url.path) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            header
            if missing {
                // Attachments outlive the thing they point at: a relayed file is
                // swept after a month, and a screenshot can be moved. Saying so
                // beats a blank rectangle.
                Text("This file is no longer there.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 420, height: 120, alignment: .topLeading)
            } else {
                QuickLook(url: url)
                    .frame(width: 480, height: 360)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerCard))
            }
        }
        .padding(Theme.s5)
    }

    private var header: some View {
        HStack(spacing: Theme.s4) {
            VStack(alignment: .leading, spacing: Theme.s1) {
                Text(url.lastPathComponent)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(Theme.monoSmall)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: Theme.s5)
            // The way out to the real thing, for the cases a preview can't
            // serve — editing it, or finding out where it actually lives.
            Button("Reveal") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            .controlSize(.small)
            .disabled(missing)
        }
        .frame(maxWidth: 480, alignment: .leading)
    }

    /// Size and location, on one line. The location matters more than it looks
    /// — two attachments can share a filename, and a relayed file lives
    /// somewhere you didn't put it.
    private var subtitle: String {
        let folder = url.deletingLastPathComponent().path
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        else { return folder }
        return Self.bytes.string(fromByteCount: Int64(size)) + " · " + folder
    }

    private static let bytes: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}
