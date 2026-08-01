import SwiftUI

/// Reasoning, live and after the fact.
///
/// While the model is thinking this is an open, self-scrolling window onto the
/// stream, capped in height and faded at both edges so it reads as a view onto
/// something ongoing rather than a growing block that shoves the transcript
/// down. Once the turn ends it folds into a single line — "Thought for 5s" —
/// which you can open again.
///
/// The fade is only applied when the content actually overflows. Masking a
/// short block dims text for no reason and looks like a rendering fault.
struct ThinkingView: View {
    let text: String
    /// `nil` while the model is still thinking.
    let elapsed: TimeInterval?

    @State private var expanded = false
    @State private var contentHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isActive: Bool { elapsed == nil }
    private var isOpen: Bool { isActive || expanded }
    private static let maxHeight: CGFloat = 168
    private static let fade: CGFloat = 18

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            if isOpen && !text.isEmpty { reasoning }
        }
        .animation(Motion.disclose, value: isOpen)
    }

    // MARK: Header

    @ViewBuilder
    private var header: some View {
        if isActive {
            ShimmerLabel(text: "Thinking…", enabled: !reduceMotion)
        } else {
            Button { withAnimation(Motion.disclose) { expanded.toggle() } } label: {
                HStack(spacing: 5) {
                    Text("Thought for \(Self.format(elapsed ?? 0))")
                        .font(Theme.label)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                }
                .foregroundStyle(.tertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Hide reasoning" : "Show reasoning")
        }
    }

    // MARK: Reasoning

    private var reasoning: some View {
        ScrollView(.vertical) {
            Text(text)
                .font(.system(size: 12.5))
                .lineSpacing(3.5)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    GeometryReader { geometry in
                        Color.clear.preference(key: HeightKey.self, value: geometry.size.height)
                    }
                )
        }
        .scrollDisabled(isActive)
        // Follow the stream while it's live; let the user drive once it's done.
        .defaultScrollAnchor(isActive ? .bottom : .top)
        .onPreferenceChange(HeightKey.self) { contentHeight = $0 }
        .frame(height: min(max(contentHeight, 1), Self.maxHeight))
        .mask(mask)
        .padding(.leading, 1)
    }

    @ViewBuilder
    private var mask: some View {
        if contentHeight > Self.maxHeight {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: Self.fade / Self.maxHeight),
                    .init(color: .black, location: 1 - Self.fade / Self.maxHeight),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top, endPoint: .bottom)
        } else {
            Color.black
        }
    }

    private static func format(_ seconds: TimeInterval) -> String {
        seconds < 60
            ? "\(max(1, Int(seconds.rounded())))s"
            : "\(Int(seconds) / 60)m \(Int(seconds) % 60)s"
    }

    private struct HeightKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }
}

/// A highlight sweeping across the label while work is in flight.
///
/// Preferred over a spinner here: a spinner says "blocked", a shimmer says
/// "producing". It's also silent — no spinning geometry competing with the
/// text arriving underneath it.
struct ShimmerLabel: View {
    let text: String
    let enabled: Bool

    @State private var phase: CGFloat = -1

    var body: some View {
        Text(text)
            .font(Theme.label)
            .foregroundStyle(.tertiary)
            .overlay {
                if enabled {
                    GeometryReader { geometry in
                        LinearGradient(
                            colors: [.clear, .primary.opacity(0.85), .clear],
                            startPoint: .leading, endPoint: .trailing)
                            .frame(width: geometry.size.width * 0.55)
                            .offset(x: phase * geometry.size.width * 1.6)
                    }
                    .mask(Text(text).font(Theme.label))
                    .allowsHitTesting(false)
                }
            }
            .onAppear {
                guard enabled else { return }
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}
