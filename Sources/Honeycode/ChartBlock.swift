import SwiftUI
import AppKit
import Charts

/// A chart the agent asked for, drawn natively.
///
/// The alternative — and what happened before this existed — is the agent
/// writing a self-contained HTML file and opening your browser. That works, but
/// it throws you out of the app for something the transcript should just show,
/// and the chart is then a file on disk you have to tidy up.
///
/// The contract is a fenced block tagged `chart` holding JSON. It's deliberately
/// tiny: a chart type, a title, axis labels, and either `data` or `series`.
/// Anything richer would need a grammar (Vega-Lite is the obvious candidate) and
/// a grammar is only worth it once this proves too small.
struct ChartSpec {
    enum Kind: String {
        case bar, line, area, scatter, pie
    }

    struct Point {
        let x: String
        let y: Double
    }

    struct Series: Identifiable {
        let name: String
        let points: [Point]
        var id: String { name }
    }

    enum Format: String {
        case plain, compact, percent
    }

    let kind: Kind
    let title: String?
    let xLabel: String?
    let yLabel: String?
    let series: [Series]
    /// Multiple bar series sit on top of each other unless told otherwise.
    /// Swift Charts stacks by default, and there was no way to ask for the
    /// side-by-side comparison that's usually what a grouped bar chart means.
    var stacked = true
    /// Bars along the x axis instead. The moment categories are longer than
    /// "2024" a vertical chart turns its labels into confetti.
    var horizontal = false
    var format: Format = .plain

    var isSingleSeries: Bool { series.count <= 1 }

    /// A pie is one series whose *slices* are the categories, so suppressing
    /// the key because "there's only one series" left a coloured ring with
    /// nothing saying what any of it was.
    var showsLegend: Bool { kind == .pie || !isSingleSeries }

    /// Every series' value at one category, for the hover readout.
    ///
    /// Carries each series' index in `series`, because that — not its position
    /// in this filtered list — is what the chart coloured it by. A series with
    /// no point at the hovered category drops out here, and the readout below
    /// then handed every series after it the wrong swatch.
    func values(at x: String) -> [(index: Int, name: String, value: Double)] {
        series.enumerated().compactMap { index, series in
            series.points.first { $0.x == x }.map { (index, series.name, $0.y) }
        }
    }

    /// The format actually used.
    ///
    /// The agent is told the flags exist but frequently won't pass them, and a
    /// y-axis reading 2,000,000,000 is unreadable whether or not anyone asked
    /// for compact. Falling back on the data itself means the chart is right by
    /// default rather than right when prompted carefully.
    var effectiveFormat: Format {
        guard format == .plain else { return format }
        let largest = series.flatMap(\.points).map { abs($0.y) }.max() ?? 0
        return largest >= 100_000 ? .compact : .plain
    }

    /// Long names on a vertical axis overlap into confetti — which is exactly
    /// what ten language names did. Turning the chart on its side is the fix,
    /// and it's a rendering decision rather than an editorial one.
    var effectiveHorizontal: Bool {
        if horizontal { return true }
        guard kind == .bar else { return false }
        let names = series.flatMap(\.points).map(\.x)
        let categories = Set(names).count
        let longest = names.map(\.count).max() ?? 0
        return categories > 6 && longest > 8
    }

    /// Direct labels stop being readable long before the bars do.
    var showsValueLabels: Bool {
        isSingleSeries && !effectiveHorizontal && (series.first?.points.count ?? 0) <= 7
    }

    func formatted(_ value: Double) -> String {
        switch effectiveFormat {
        case .percent:
            return value.formatted(.number.precision(.fractionLength(0...1))) + "%"
        case .compact:
            return value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
        case .plain:
            return value == value.rounded()
                ? value.formatted(.number.precision(.fractionLength(0)))
                : value.formatted(.number.precision(.fractionLength(0...2)))
        }
    }

    /// Categories in the order the agent gave them. Swift Charts sorts a
    /// categorical axis alphabetically unless the domain is stated, which would
    /// silently reorder "Jan, Feb, Mar" into "Feb, Jan, Mar".
    var xDomain: [String] {
        var seen = Set<String>()
        return series.flatMap(\.points).compactMap { seen.insert($0.x).inserted ? $0.x : nil }
    }

    /// `nil` when the block isn't a chart after all — the caller falls back to
    /// rendering it as an ordinary code block, which is the honest thing to do
    /// with JSON that didn't parse.
    static func parse(_ source: String) -> ChartSpec? {
        guard let data = source.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }

        let kind = ChartSpec.Kind(rawValue: (json["type"] as? String ?? "bar").lowercased())
            ?? .bar

        func points(_ raw: Any?) -> [Point] {
            (raw as? [[String: Any]] ?? []).compactMap { entry in
                guard let y = numeric(entry["y"]) else { return nil }
                let x = entry["x"].map { "\($0)" } ?? ""
                return Point(x: x, y: y)
            }
        }

        var series: [Series] = []
        if let raw = json["series"] as? [[String: Any]] {
            for (index, entry) in raw.enumerated() {
                let name = entry["name"] as? String ?? "Series \(index + 1)"
                let values = points(entry["data"])
                if !values.isEmpty { series.append(Series(name: name, points: values)) }
            }
        } else {
            let values = points(json["data"])
            if !values.isEmpty {
                series = [Series(name: json["name"] as? String ?? "", points: values)]
            }
        }
        guard !series.isEmpty else { return nil }

        return ChartSpec(kind: kind,
                         title: json["title"] as? String,
                         xLabel: json["x"] as? String,
                         yLabel: json["y"] as? String,
                         series: series,
                         stacked: json["stacked"] as? Bool ?? true,
                         horizontal: json["horizontal"] as? Bool ?? false,
                         format: Format(rawValue: (json["format"] as? String ?? "").lowercased())
                             ?? .plain)
    }

    /// Numbers arrive as `Double`, `Int`, or a quoted string depending on how
    /// the model felt about it that day.
    private static func numeric(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let string = value as? String { return Double(string) }
        return nil
    }
}

// MARK: - Rendering

struct ChartBlock: View {
    let spec: ChartSpec

    @State private var hovered: String?
    @State private var expanded = false
    @State private var showingActions = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s4) {
            if !heading.isEmpty {
                HStack(spacing: Theme.s4) {
                    Text(heading)
                        .font(Theme.rowStrong)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: Theme.s4)
                    if showingActions { actions }
                }
            }

            ChartCanvas(spec: spec, hovered: $hovered)
                .frame(height: spec.kind == .pie ? 260 : 210)
                .chartLegend(spec.showsLegend ? .visible : .hidden)
        }
        .padding(Theme.s5)
        .modifier(InsetSurface())
        .onHover { showingActions = $0 }
        .animation(Motion.reveal, value: showingActions)
        .sheet(isPresented: $expanded) {
            ExpandedChart(spec: spec, isPresented: $expanded)
        }
    }

    /// Expand, copy, save. A chart you can't get out of the app is a chart you
    /// screenshot, and a 210pt plot inside a reading column is unreadable the
    /// moment there's more than a handful of points.
    private var actions: some View {
        HStack(spacing: Theme.s2) {
            action("arrow.up.left.and.arrow.down.right", "Expand") { expanded = true }
            action("doc.on.doc", "Copy as image") { copy() }
            action("square.and.arrow.down", "Save as PNG…") { save() }
        }
    }

    private func action(_ symbol: String, _ label: String,
                        run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverCapsule())
        .help(label)
    }

    /// Title with the unit folded in when the title doesn't already carry it.
    private var heading: String {
        let title = spec.title ?? ""
        if !title.isEmpty { return title }
        return spec.kind == .pie ? "" : (spec.yLabel ?? "")
    }

    // MARK: Export

    @MainActor
    private func rendered() -> NSImage? {
        // Rasterised at 2× from the same view that's on screen, so what you
        // paste is what you were looking at rather than a re-drawn
        // approximation of it.
        let renderer = ImageRenderer(content:
            ChartCanvas(spec: spec, hovered: .constant(nil))
                .chartLegend(spec.showsLegend ? .visible : .hidden)
                .frame(width: 720, height: 420)
                .padding(Theme.s6)
                .background(Theme.canvas))
        renderer.scale = 2
        return renderer.nsImage
    }

    private func copy() {
        guard let image = rendered() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    private func save() {
        guard let image = rendered(),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue =
            (spec.title?.isEmpty == false ? spec.title! : "chart") + ".png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? png.write(to: url)
    }
}

/// Full-window, for anything with more than a handful of points.
private struct ExpandedChart: View {
    let spec: ChartSpec
    @Binding var isPresented: Bool
    @State private var hovered: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(spec.title ?? "Chart")
                    .font(Theme.heading)
                Spacer()
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(Theme.s6)

            Divider().overlay(Theme.rule)

            ChartCanvas(spec: spec, hovered: $hovered)
                .chartLegend(spec.showsLegend ? .visible : .hidden)
                .padding(Theme.s7)
        }
        .frame(width: 900, height: 620)
    }
}

// MARK: - The plot itself

/// Shared by the inline card, the expanded sheet and the image export, so all
/// three are literally the same chart rather than three that drift apart.
private struct ChartCanvas: View {
    let spec: ChartSpec
    @Binding var hovered: String?

    var body: some View {
        if spec.kind == .pie {
            pie
        } else {
            plot
        }
    }

    /// A pie's slices *are* its categories, so it can only show one series —
    /// there's no second ring to put the rest in. The first is drawn, and when
    /// there are others it says so rather than quietly discarding them, which
    /// is the difference between a chart with a caveat and a chart that lies.
    private var pie: some View {
        VStack(spacing: Theme.s3) {
            Chart(indexed, id: \.offset) { entry in
                SectorMark(angle: .value(spec.yLabel ?? "Value", entry.point.y),
                           innerRadius: .ratio(0.58),
                           angularInset: 1.5)
                    .foregroundStyle(by: .value("Category", entry.point.x))
                    .cornerRadius(3)
            }
            .chartForegroundStyleScale(range: ChartPalette.colours(spec.xDomain.count))

            if spec.series.count > 1, let shown = spec.series.first?.name {
                Text("Showing “\(shown)” only — a pie chart can show one series.")
                    .font(Theme.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var plot: some View {
        Chart {
            ForEach(spec.series) { series in
                ForEach(Array(series.points.enumerated()), id: \.offset) { _, point in
                    mark(point, series: series)
                }
            }

            // The hover rule and readout are marks, not an overlay, so they
            // land in the plot's own coordinate space and can't drift out of
            // alignment with the bars they're describing.
            if let hovered, !spec.effectiveHorizontal {
                RuleMark(x: .value(spec.xLabel ?? "", hovered))
                    .foregroundStyle(Self.ink.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, spacing: 4,
                                overflowResolution: .init(x: .fit(to: .chart),
                                                          y: .disabled)) {
                        readout(hovered)
                    }
            }
        }
        .chartForegroundStyleScale(range: ChartPalette.colours(spec.series.count))
        // The categorical axis swaps sides in horizontal mode, so pinning the
        // domain to x would have been pinning it to the *value* axis — the
        // orientation flag would have produced a broken chart the first time
        // anyone used it. Applied conditionally rather than with a ternary
        // inside one call, because the two domain types aren't interchangeable.
        .modifier(CategoryDomain(values: spec.xDomain,
                                 horizontal: spec.effectiveHorizontal))
        .chartXAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(Self.grid)
                AxisValueLabel(centered: spec.kind == .bar) {
                    if let name = value.as(String.self) { Text(name) }
                    else if let number = value.as(Double.self) {
                        Text(spec.formatted(number))
                    }
                }
                .font(Theme.caption)
                .foregroundStyle(Self.ink)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(Self.grid)
                AxisValueLabel {
                    if let number = value.as(Double.self) { Text(spec.formatted(number)) }
                    else if let name = value.as(String.self) { Text(name) }
                }
                .font(Theme.caption)
                .foregroundStyle(Self.ink)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    // `onContinuousHover`, not a drag.
                    //
                    // Every published Swift Charts recipe uses
                    // `DragGesture(minimumDistance: 0)` because they're written
                    // for touch. On a Mac that means holding the button down to
                    // read a value, which is not how any native chart behaves.
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let plotFrame = proxy.plotFrame else { return }
                            let x = location.x - geometry[plotFrame].origin.x
                            hovered = proxy.value(atX: x, as: String.self)
                        case .ended:
                            hovered = nil
                        }
                    }
            }
        }
    }

    private func readout(_ category: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(category)
                .font(Theme.captionStrong)
                .foregroundStyle(.secondary)
            ForEach(spec.values(at: category), id: \.index) { entry in
                HStack(spacing: Theme.s3 - 2) {
                    if !spec.isSingleSeries {
                        // Not an `AccountDot`: this is a series swatch keyed to
                        // `ChartPalette`, and it is smaller than `Theme.dot`
                        // on purpose — a legend inside a plot should not draw
                        // the eye the way an identity dot in chrome does.
                        Circle()
                            .fill(ChartPalette.colour(at: entry.index))
                            .frame(width: 5, height: 5)
                        Text(entry.name)
                            .font(Theme.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(spec.formatted(entry.value))
                        .font(.system(size: Theme.t1, weight: .medium, design: .monospaced))
                        .monospacedDigit()
                }
            }
        }
        .padding(.horizontal, Theme.s4)
        .padding(.vertical, Theme.s3 - 1)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerChip))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerChip)
            .strokeBorder(Theme.rule, lineWidth: 1))
        .modifier(Elevated(depth: .high))
    }

    @ChartContentBuilder
    private func mark(_ point: ChartSpec.Point, series: ChartSpec.Series) -> some ChartContent {
        let category = PlottableValue.value(spec.xLabel ?? "", point.x)
        let amount = PlottableValue.value(spec.yLabel ?? "", point.y)
        let dimmed = hovered != nil && hovered != point.x

        switch spec.kind {
        case .bar:
            // Horizontal swaps the axes outright rather than rotating the
            // chart, so the value axis keeps its numeric formatting.
            if spec.effectiveHorizontal {
                BarMark(x: amount, y: category)
                    .foregroundStyle(by: .value("Series", series.name))
                    .position(by: .value("Series", spec.stacked ? "" : series.name))
                    .cornerRadius(3)
            } else {
                BarMark(x: category, y: amount)
                    .foregroundStyle(by: .value("Series", series.name))
                    .position(by: .value("Series", spec.stacked ? "" : series.name))
                    .cornerRadius(3)
                    .opacity(dimmed ? 0.45 : 1)
                    .annotation(position: .top, spacing: 3) {
                        if spec.showsValueLabels && hovered == nil {
                            Text(spec.formatted(point.y))
                                .font(Theme.monoCaption)
                                .foregroundStyle(.tertiary)
                        }
                    }
            }
        case .line:
            LineMark(x: category, y: amount)
                .foregroundStyle(by: .value("Series", series.name))
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
            if hovered == point.x {
                PointMark(x: category, y: amount)
                    .foregroundStyle(by: .value("Series", series.name))
                    .symbolSize(60)
            }
        case .area:
            AreaMark(x: category, y: amount)
                .foregroundStyle(by: .value("Series", series.name))
                .opacity(0.55)
                .interpolationMethod(.catmullRom)
        case .scatter, .pie:
            PointMark(x: category, y: amount)
                .foregroundStyle(by: .value("Series", series.name))
                .symbolSize(hovered == point.x ? 90 : 48)
        }
    }

    private var indexed: [(offset: Int, point: ChartSpec.Point)] {
        Array((spec.series.first?.points ?? []).enumerated())
            .map { (offset: $0.offset, point: $0.element) }
    }

    /// Explicit, appearance-tracking, and outside the chart's colour scale —
    /// a hierarchical style resolves against `chartForegroundStyleScale` and
    /// comes out rendered in series-blue.
    private static var ink: Color { Color(nsColor: .tertiaryLabelColor) }
    private static var grid: Color { Color(nsColor: .separatorColor).opacity(0.7) }
}

/// Pins the categorical axis, whichever side it's on.
private struct CategoryDomain: ViewModifier {
    let values: [String]
    let horizontal: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if horizontal {
            content.chartYScale(domain: values)
        } else {
            content.chartXScale(domain: values)
        }
    }
}

// MARK: - Palette

/// The categorical palette from the `dataviz` skill, slot for slot.
///
/// Borrowed rather than invented on purpose: it's already the palette the agent
/// uses when it writes an HTML chart, so a chart drawn here and a chart it
/// exports are the same chart. It's also been validated for colour-vision
/// deficiency in both appearances, which a hand-picked set of `systemBlue`,
/// `systemOrange`… would not have been.
enum ChartPalette {
    private static let slots: [(light: String, dark: String)] = [
        ("#2a78d6", "#3987e5"),   // blue
        ("#eb6834", "#d95926"),   // orange
        ("#1baf7a", "#199e70"),   // aqua
        ("#eda100", "#c98500"),   // yellow
        ("#e87ba4", "#d55181"),   // magenta
        ("#008300", "#008300"),   // green
        ("#4a3aa7", "#9085e9"),   // violet
        ("#e34948", "#e66767"),   // red
    ]

    static func colours(_ count: Int) -> [Color] {
        (0..<max(count, 1)).map { colour(at: $0) }
    }

    static func colour(at index: Int) -> Color {
        let slot = slots[index % slots.count]
        return Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? slot.dark : slot.light
            return NSColor(hex: hex) ?? .systemBlue
        })
    }
}

extension NSColor {
    /// `#rrggbb`.
    convenience init?(hex: String) {
        var value: UInt64 = 0
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, Scanner(string: digits).scanHexInt64(&value) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                  green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255,
                  alpha: 1)
    }
}
