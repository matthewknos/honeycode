import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Files referenced by a message, pulled back out of its text.
///
/// The composer appends attachments as `@/absolute/path` lines — the CLIs
/// resolve those themselves, which is why it was done that way. But it means
/// the transcript showed you a wall of paths where you'd attached a screenshot,
/// which is a strange thing for a GUI to do with an image it has on disk.
enum Attached {

    /// Splits a message into what you wrote and what you attached.
    ///
    /// Only *trailing* `@/…` lines count. A path in the middle of a sentence is
    /// something you were talking about, not something you attached.
    static func split(_ text: String) -> (prose: String, files: [URL]) {
        var lines = text.components(separatedBy: "\n")
        var files: [URL] = []

        while let last = lines.last {
            let trimmed = last.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("@/") || trimmed.hasPrefix("@~/") else { break }
            let path = NSString(string: String(trimmed.dropFirst())).expandingTildeInPath
            files.insert(URL(fileURLWithPath: path), at: 0)
            lines.removeLast()
        }

        return (lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
                files)
    }

    static func isImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }
}

/// Decoded once per path, at display size.
///
/// A pasted screenshot is often several thousand pixels wide; holding that as an
/// `NSImage` per transcript row to draw it at 160pt is a lot of memory for
/// nothing.
@MainActor
final class Thumbnails: ObservableObject {
    static let shared = Thumbnails()

    @Published private(set) var images: [URL: NSImage] = [:]
    private var loading: Set<URL> = []

    func image(for url: URL) -> NSImage? {
        if let hit = images[url] { return hit }
        guard !loading.contains(url) else { return nil }
        loading.insert(url)

        Task.detached(priority: .userInitiated) {
            let decoded = Self.decode(url)
            await MainActor.run {
                self.loading.remove(url)
                if let decoded { self.images[url] = decoded }
            }
        }
        return nil
    }

    nonisolated private static func decode(_ url: URL) -> NSImage? {
        // SVG goes straight to `NSImage`.
        //
        // I checked that `NSImage` reads SVG natively and then sent it through
        // ImageIO anyway — which doesn't support it at all, so
        // `CGImageSourceCreateWithURL` returned nil and the placeholder span
        // forever. Verifying the right API and then calling a different one is
        // its own kind of mistake.
        if url.pathExtension.lowercased() == "svg" {
            return NSImage(contentsOf: url)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 900,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }
}

/// What you attached, shown rather than listed.
struct AttachmentStrip: View {
    let files: [URL]
    var scale: CGFloat = 1

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            ForEach(files.filter(Attached.isImage), id: \.self) { url in
                ImageAttachment(url: url, scale: scale)
            }
            let others = files.filter { !Attached.isImage($0) }
            if !others.isEmpty {
                HStack(spacing: Theme.s3) {
                    ForEach(others, id: \.self) { url in
                        FileChip(url: url)
                    }
                }
            }
        }
    }
}

private struct ImageAttachment: View {
    let url: URL
    var scale: CGFloat = 1

    @ObservedObject private var thumbnails = Thumbnails.shared
    @State private var hovering = false
    @State private var failed = false
    @State private var expanded = false

    var body: some View {
        Group {
            if let image = thumbnails.image(for: url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    // Capped rather than full-width: an image in a transcript
                    // is a reference, and one that fills the column pushes the
                    // conversation off screen.
                    .frame(maxWidth: 320 * scale, maxHeight: 240 * scale, alignment: .leading)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.well)
                    .frame(width: 160 * scale, height: 100 * scale)
                    .overlay {
                        // A spinner that never stops is indistinguishable from
                        // one that's working, so it gives up and says so.
                        if failed {
                            Label("Couldn't read image", systemImage: "photo.badge.exclamationmark")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.rule, lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            HStack(spacing: Theme.s2) {
                // A diagram at 320pt is a thumbnail of a diagram. Vectors
                // especially — they're crisp at any size, so there's no reason
                // to make you open them in another app to read the labels.
                Button { expanded = true } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background(Theme.surface, in: Circle())
                        .overlay(Circle().strokeBorder(Theme.rule, lineWidth: 1))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Expand")

                FileActionButtons(url: url)
            }
            .padding(Theme.s3)
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
        }
        .onTapGesture(count: 2) { expanded = true }
        .sheet(isPresented: $expanded) {
            ExpandedImage(url: url, isPresented: $expanded)
        }
        .onHover { hovering = $0 }
        .animation(Motion.reveal, value: hovering)
        .task(id: url) {
            try? await Task.sleep(for: .seconds(3))
            failed = thumbnails.image(for: url) == nil
        }
        .help(url.lastPathComponent)
    }
}

private struct FileChip: View {
    let url: URL

    var body: some View {
        Button { FileActions.open(url) } label: {
            HStack(spacing: Theme.s3 - 1) {
                Image(systemName: "doc")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                Text(url.lastPathComponent)
                    .font(.system(size: 11.5))
                    .lineLimit(1)
            }
            .padding(.horizontal, Theme.s4)
            .padding(.vertical, Theme.s2)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverCapsule())
        .help(url.path)
    }
}

// MARK: - Opening things

/// Open and Reveal, wherever a file is named.
///
/// A GUI that shows you a change to a file and gives you no way to look at the
/// file is doing half the job — you end up copying the path out and switching
/// to a terminal, which is the thing this app exists to avoid.
enum FileActions {
    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Diff cards carry a display path with `~` already substituted in, so it
    /// has to be expanded again before anything can be opened.
    static func resolve(_ displayPath: String) -> URL {
        URL(fileURLWithPath: NSString(string: displayPath).expandingTildeInPath)
    }
}

struct FileActionButtons: View {
    let url: URL

    var body: some View {
        HStack(spacing: Theme.s2) {
            button("arrow.up.forward.app", "Open") { FileActions.open(url) }
            button("folder", "Reveal in Finder") { FileActions.reveal(url) }
        }
    }

    private func button(_ symbol: String, _ label: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(Theme.surface, in: Circle())
                .overlay(Circle().strokeBorder(Theme.rule, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
    }
}


/// Inline SVG, put on disk so it can go down the same path as any other image.
enum VectorArtifact {
    private static let folder: URL = {
        let url = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Honeycode/Artifacts", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Named by content hash, so re-rendering the same block during streaming
    /// reuses one file instead of littering a new one per keystroke.
    static func write(_ markup: String) -> URL? {
        guard markup.contains("<svg") else { return nil }
        let name = "svg-\(abs(markup.hashValue)).svg"
        let url = folder.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard (try? markup.write(to: url, atomically: true, encoding: .utf8)) != nil
            else { return nil }
        }
        return url
    }
}

/// An image at the size it deserves.
private struct ExpandedImage: View {
    let url: URL
    @Binding var isPresented: Bool

    @ObservedObject private var thumbnails = Thumbnails.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(url.lastPathComponent)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                FileActionButtons(url: url)
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(Theme.s5)

            Divider().overlay(Theme.rule)

            Group {
                if let image = thumbnails.image(for: url) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(Theme.s6)
            // A pale ground behind it: most diagrams are drawn for white, and
            // dropping one onto a dark sheet turns its black strokes invisible.
            .background(Color(nsColor: .white))
        }
        .frame(width: 1000, height: 760)
    }
}
