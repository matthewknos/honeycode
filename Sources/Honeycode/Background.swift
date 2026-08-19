import SwiftUI
import AppKit

/// Background variants the library can hold.
enum BackgroundKind: String, Codable, Hashable {
    case image
    case flux
}

/// One background in the library.
struct BackgroundItem: Identifiable, Codable, Hashable {
    /// Filename inside the library folder. Stable, and doubles as the identity.
    let file: String
    var name: String
    var addedAt: Date
    /// Grouping in the picker. Optional so an older library still decodes;
    /// anything without one falls into `Unsorted`.
    var category: String?
    /// Kind of background. Older libraries decode as `.image`.
    var kind: BackgroundKind?

    var id: String { file }
    var group: String { category ?? BackgroundStore.unsorted }
    var backgroundKind: BackgroundKind { kind ?? .image }
}

/// The background library.
///
/// Images are **copied into Application Support** rather than referenced where
/// they were found. Referencing meant re-reading `~/Downloads` on every launch —
/// so macOS prompted for Downloads access, the grid emptied out if you tidied
/// the folder, and a background silently vanished when its file was moved.
/// Owning the bytes costs a few megabytes and makes all three problems go away.
@MainActor
final class BackgroundStore: ObservableObject {

    @AppStorage("background.file") private var selectedFile = ""
    /// Strength of the frosting, 0…1.
    @AppStorage("background.veil") var veil: Double = 0.55

    @Published private(set) var items: [BackgroundItem] = []
    @Published private(set) var thumbnails: [String: NSImage] = [:]
    @Published private(set) var image: NSImage?

    var selected: BackgroundItem? { items.first { $0.file == selectedFile } }

    /// Whether the current selection is a visual background that content
    /// should render as glass over. True for photos and for the built-in
    /// animated flux background.
    var isGlassy: Bool {
        guard let selected else { return false }
        return selected.backgroundKind == .flux || image != nil
    }

    /// Whether content over this background has to render light, whatever
    /// appearance the app is in.
    ///
    /// Flux is a *light* artwork and only a light one — `flux.html` fixes its
    /// palette at script load, so the theme it's handed afterwards has never
    /// reached the canvas. In Dark the result was white type on a near-white
    /// field: the greeting, the composer placeholder and the permissions line
    /// all effectively invisible.
    ///
    /// Treated as a property of the background rather than fixed in the page,
    /// because the pale version is the one worth looking at. A background this
    /// bright wants dark content on it, and that's true regardless of what the
    /// rest of the system is doing — the same call any light wallpaper would
    /// force if the app let you put text straight onto one.
    ///
    /// Scoped to the content pane. The sidebar keeps your chosen appearance,
    /// because it paints its own opaque surface and never sits over this.
    var forcesLightContent: Bool {
        selected?.backgroundKind == .flux
    }

    // MARK: Built-ins

    /// The animated flux background extracted from the CORTEX homepage.
    /// It is bundled as a resource, not stored in the user library folder,
    /// so it is always available and never persisted to `library.json`.
    static let fluxItem = BackgroundItem(
        file: "flux",
        name: "Flux",
        addedAt: Date(timeIntervalSince1970: 0),
        category: "Animated",
        kind: .flux
    )

    /// Insert built-in items into the library without writing them to disk.
    private func ensureBuiltIns() {
        if !items.contains(where: { $0.file == Self.fluxItem.file }) {
            items.insert(Self.fluxItem, at: 0)
        }
    }

    // MARK: Locations

    nonisolated static let unsorted = "Unsorted"

    private static let folderName = "Backgrounds"

    private var libraryURL: URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Honeycode", isDirectory: true)
            .appendingPathComponent(Self.folderName, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: support, withIntermediateDirectories: true)
        return support
    }

    private var manifestURL: URL { libraryURL.appendingPathComponent("library.json") }

    func url(for item: BackgroundItem) -> URL {
        libraryURL.appendingPathComponent(item.file)
    }

    // MARK: Lifecycle

    init() {
        Migration.run()
        load()
        ensureBuiltIns()
        adoptLegacySelection()
        refreshImage()
        Task { await loadThumbnails() }
    }

    private func load() {
        guard let data = try? Data(contentsOf: manifestURL),
              let decoded = try? JSONDecoder().decode([BackgroundItem].self, from: data)
        else {
            items = []
            return
        }
        // Drop entries whose file has gone missing, so a hand-cleaned folder
        // doesn't leave dead thumbnails in the grid. Built-in items have no
        // file on disk and are re-added separately by `ensureBuiltIns`.
        let present = Set((try? FileManager.default.contentsOfDirectory(
            atPath: libraryURL.path)) ?? [])
        items = decoded.filter { $0.backgroundKind == .flux || present.contains($0.file) }
    }

    private func save() {
        // Only persist user-added images; built-ins are recreated on launch.
        let persistable = items.filter { $0.backgroundKind != .flux }
        guard let data = try? JSONEncoder().encode(persistable) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }

    /// Carry over a background chosen before the library existed, which was
    /// stored as an absolute path into Downloads.
    private func adoptLegacySelection() {
        let legacyKey = "background.path"
        guard let path = UserDefaults.standard.string(forKey: legacyKey),
              !path.isEmpty else { return }
        UserDefaults.standard.removeObject(forKey: legacyKey)
        if let item = importImage(at: URL(fileURLWithPath: path)) {
            selectedFile = item.file
        }
    }

    // MARK: Import

    func importImages() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.directoryURL = FileManager.default
            .urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.prompt = "Add"
        panel.message = "Choose images to add to your background library."
        guard panel.runModal() == .OK else { return }

        var last: BackgroundItem?
        for url in panel.urls { last = importImage(at: url) ?? last }
        save()
        if let last, selectedFile.isEmpty { select(last) }
        Task { await loadThumbnails() }
    }

    @discardableResult
    private func importImage(at source: URL) -> BackgroundItem? {
        let destination = uniqueDestination(for: source.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            return nil
        }
        let item = BackgroundItem(
            file: destination.lastPathComponent,
            name: Self.prettyName(from: source.lastPathComponent),
            addedAt: Date(),
            category: nil)
        items.insert(item, at: 0)
        return item
    }

    /// Two files called `photo.jpg` from different folders must not collide.
    private func uniqueDestination(for filename: String) -> URL {
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = libraryURL.appendingPathComponent(filename)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = libraryURL.appendingPathComponent("\(base)-\(n).\(ext)")
            n += 1
        }
        return candidate
    }

    /// Turn `aperture-vintage-CV-BQDcnMCs-unsplash.jpg` into `Aperture Vintage`.
    ///
    /// Stock-photo filenames carry a slug, an opaque ID and a source suffix.
    /// The slug is the only part a person wrote, so this keeps that and drops
    /// the rest — a library labelled with hashes is no more use than one
    /// labelled with nothing.
    static func prettyName(from filename: String) -> String {
        var base = (filename as NSString).deletingPathExtension
        for suffix in ["-unsplash", "-pexels", "-scaled"] {
            base = base.replacingOccurrences(of: suffix, with: "")
        }

        var parts = base
            .split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " })
            .map(String.init)

        // Trailing opaque ID: long, and not a plain lowercase word.
        if let last = parts.last, parts.count > 1, last.count >= 8,
           last.rangeOfCharacter(from: .decimalDigits) != nil
            || last != last.lowercased() {
            parts.removeLast()
        }

        let words = parts
            .filter { !$0.isEmpty }
            .prefix(5)
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }

        return words.isEmpty ? base : words.joined(separator: " ")
    }

    // MARK: Mutation

    func select(_ item: BackgroundItem?) {
        selectedFile = item?.file ?? ""
        refreshImage()
    }

    func rename(_ item: BackgroundItem, to name: String) {
        // Built-in items are recreated on launch; mutating them would appear to
        // work but be silently lost on the next run.
        guard item.backgroundKind != .flux else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = items.firstIndex(of: item) else { return }
        items[index].name = trimmed
        save()
    }

    func categorise(_ item: BackgroundItem, as category: String?) {
        guard item.backgroundKind != .flux else { return }
        guard let index = items.firstIndex(of: item) else { return }
        items[index].category = category
        save()
    }

    /// Categories present, in a stable order, with `Unsorted` always last —
    /// it's a holding pen, not a category, and sorting it alphabetically would
    /// bury real groups behind it.
    var categories: [String] {
        var seen: [String] = []
        for item in items where !seen.contains(item.group) { seen.append(item.group) }
        let named = seen.filter { $0 != Self.unsorted }.sorted()
        return named + (seen.contains(Self.unsorted) ? [Self.unsorted] : [])
    }

    func items(in category: String) -> [BackgroundItem] {
        items.filter { $0.group == category }
    }

    func remove(_ item: BackgroundItem) {
        guard item.backgroundKind != .flux else { return }
        try? FileManager.default.removeItem(at: url(for: item))
        items.removeAll { $0.id == item.id }
        thumbnails[item.file] = nil
        if selectedFile == item.file { select(nil) }
        save()
    }

    private func refreshImage() {
        image = selected.flatMap { item -> NSImage? in
            guard item.backgroundKind == .image else { return nil }
            return NSImage(contentsOf: url(for: item))
        }
    }

    // MARK: Thumbnails

    /// Decoded at grid size. Sixty full-resolution photos held as `NSImage` is
    /// gigabytes of backing store for something rendered at 132pt.
    private func loadThumbnails() async {
        for item in items where thumbnails[item.file] == nil {
            // Capture the file URL on the main actor before hopping to a
            // detached task for decoding.
            let source = item.backgroundKind == .image ? url(for: item) : nil
            let thumb: NSImage? = await Task.detached(priority: .utility) {
                if item.backgroundKind == .flux {
                    return Self.fluxThumbnail()
                }
                guard let source else { return nil }
                return imageThumbnail(at: source, fitting: 480)
            }.value
            if let thumb { thumbnails[item.file] = thumb }
        }
    }

    /// A static green-to-blue gradient thumbnail for the built-in flux item.
    private nonisolated static func fluxThumbnail() -> NSImage? {
        let size = CGSize(width: 240, height: 135)
        guard let cg = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let colors = [
            NSColor(srgbRed: 0.149, green: 0.208, blue: 0.518, alpha: 1).cgColor,
            NSColor(srgbRed: 0.380, green: 0.659, blue: 0.247, alpha: 1).cgColor,
            NSColor(srgbRed: 0.000, green: 0.624, blue: 0.890, alpha: 1).cgColor
        ]
        guard let gradient = CGGradient(colorsSpace: nil, colors: colors as CFArray, locations: [0, 0.55, 1]) else { return nil }
        cg.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: size.height),
            end: CGPoint(x: size.width, y: 0),
            options: []
        )
        guard let image = cg.makeImage() else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }
}

/// The content pane's backdrop: the image, frosted by the glass slider.
///
/// The slider drives **blur radius on the image itself**, nothing else. At 0
/// the photograph is untouched; at 1 it's frosted down to shapes of colour.
///
/// Two earlier versions got this wrong in the same way — they layered a
/// `canvas` wash over the top and scaled its opacity, so turning the control up
/// didn't frost the image, it whitewashed it. Glass diffuses what's behind it;
/// it doesn't paint over it. Blurring the source is the honest expression of
/// that, and it keeps the image's own colour all the way to maximum instead of
/// fading everything toward white.
///
/// `opaque: true` is load-bearing: without it the blur samples transparency
/// past the image's edges and leaves a pale halo around the pane, which reads
/// as exactly the whitening this was meant to remove.
struct PaneBackground: View {
    @ObservedObject var store: BackgroundStore
    /// Settings previews its own swatch and must show the artwork whatever the
    /// pane behind it is currently doing.
    var honoursCodingMode = true

    /// Coding mode turns the artwork off outright.
    ///
    /// Not for taste — the pane is opaque above it either way — but because
    /// `flux` is a `WKWebView` running a canvas animation continuously, and a
    /// photograph is a full-window blur pass. Both are spending the frame
    /// budget of the mode you switched into *because* you wanted the frames.
    /// Leaving the view out of the hierarchy is what tears the web process
    /// down; hiding it would keep it drawing.
    @AppStorage("transcript.terminal") private var terminal = false

    /// Enough at full strength to reduce any photograph to colour fields,
    /// without being so large that mid-slider positions all look identical.
    private static let maxBlur: CGFloat = 60

    var body: some View {
        ZStack {
            Theme.canvas

            switch (honoursCodingMode && terminal) ? nil : store.selected?.backgroundKind {
            case .flux:
                // The veil goes *into* the animation rather than over it.
                //
                // A SwiftUI `.blur` here wrapped a continuously-redrawing
                // WKWebView in an offscreen render pass, so every frame the
                // canvas produced was composited twice — once by the web
                // process and again by us — across the full window. The page
                // applies the same radius as a CSS filter on the layer it is
                // already drawing into, which the compositor does for free.
                Color.clear
                    .overlay(FluxBackground(blur: store.veil * Self.maxBlur))
                    .clipped()
                    .allowsHitTesting(false)
            case .image:
                if let image = store.image {
                    // `Color.clear.overlay(…).clipped()` keeps a fill-scaled image
                    // inside the pane. Clipping the Image directly doesn't: it
                    // clips to the image's own oversized layout frame, so the
                    // overflow still paints.
                    Color.clear
                        .overlay(
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .blur(radius: store.veil * Self.maxBlur, opaque: true)
                        )
                        .clipped()
                        .allowsHitTesting(false)
                }
            case .none:
                EmptyView()
            }
        }
        .clipped()
    }
}
