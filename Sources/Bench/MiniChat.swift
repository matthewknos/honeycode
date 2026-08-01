import SwiftUI

/// The conversation, floating over a full-width preview.
///
/// Full width hides the transcript, which is right until the moment you want to
/// say "make that button bigger" about the thing you're looking at. Closing the
/// preview to type and reopening it to check loses the very comparison you were
/// making. So the chat comes to the preview instead.
///
/// Deliberately the real `TranscriptView` and `ComposerView` rather than a
/// cut-down pair: streaming, markdown, charts, `@` mentions and slash commands
/// all work here because it *is* the same conversation, not a summary of one.
struct MiniChat: View {
    @ObservedObject var session: Session
    @ObservedObject var workspace: Workspace
    /// The area it's floating over, so it can't be dragged off the edge.
    let bounds: CGSize

    @State private var draft = ""
    @State private var collapsed = false

    // Remembered across launches — a window you have to re-place every time is
    // a window you stop moving.
    @AppStorage("minichat.width") private var width: Double = 400
    @AppStorage("minichat.height") private var height: Double = 520
    @AppStorage("minichat.x") private var offsetX: Double = 0
    @AppStorage("minichat.y") private var offsetY: Double = 0

    @State private var dragOrigin: CGSize?
    @State private var sizeOrigin: CGSize?

    private var cardWidth: CGFloat { min(CGFloat(width), max(340, bounds.width - Theme.s7)) }
    private var cardHeight: CGFloat { min(CGFloat(height), max(200, bounds.height - Theme.s7)) }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !collapsed {
                Divider().overlay(Theme.rule)
                TranscriptView(session: session, workspace: workspace,
                               mode: .summary, width: cardWidth - Theme.s7,
                               panelled: false)
                ComposerView(draft: $draft, session: session,
                             width: cardWidth - Theme.s6, compact: true) { text in
                    session.send(text)
                    draft = ""
                }
            }
        }
        .frame(width: cardWidth)
        .frame(height: collapsed ? nil : cardHeight)
        // Translucent, but blurred rather than merely faded.
        //
        // Plain opacity over a live page leaves the page's own text showing
        // through the card's, which is unreadable at any level. A material
        // blurs what's behind first, so the page reads as texture and the
        // conversation stays crisp.
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.rule, lineWidth: 1))
        .overlay(alignment: .topLeading) { resizeGrip }
        .shadow(color: .black.opacity(0.3), radius: 22, y: 8)
        .offset(x: clampedX, y: clampedY)
        .animation(Motion.disclose, value: collapsed)
    }

    // MARK: Moving

    /// Anchored bottom-trailing, so the offsets only ever go negative — and
    /// they're clamped to the page rather than trusted, because a resized
    /// window can otherwise strand the card off-screen with no way back.
    private var clampedX: CGFloat {
        min(0, max(CGFloat(offsetX), -(bounds.width - cardWidth - Theme.s7)))
    }

    private var clampedY: CGFloat {
        min(0, max(CGFloat(offsetY), -(bounds.height - cardHeight - Theme.s7)))
    }

    private var moveGesture: some Gesture {
        DragGesture(coordinateSpace: .global)
            .onChanged { value in
                let origin = dragOrigin ?? CGSize(width: clampedX, height: clampedY)
                if dragOrigin == nil { dragOrigin = origin }
                offsetX = Double(origin.width + value.translation.width)
                offsetY = Double(origin.height + value.translation.height)
            }
            .onEnded { _ in
                dragOrigin = nil
                // Store the clamped values, not the raw ones, or the card
                // remembers a position it was never allowed to be in.
                offsetX = Double(clampedX)
                offsetY = Double(clampedY)
            }
    }

    // MARK: Resizing

    /// Top-leading, because the card is pinned bottom-trailing — dragging away
    /// from the anchor is the direction that grows it.
    private var resizeGrip: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
            .rotationEffect(.degrees(90))
            .padding(Theme.s2)
            .onHover { $0 ? NSCursor.crosshair.push() : NSCursor.pop() }
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        let origin = sizeOrigin ?? CGSize(width: cardWidth, height: cardHeight)
                        if sizeOrigin == nil { sizeOrigin = origin }
                        // 340 is where the composer rail stops fitting even
                        // stripped down — below that it isn't a small window,
                        // it's a broken one.
                        width = Double(min(max(origin.width - value.translation.width, 340),
                                           bounds.width - Theme.s7))
                        height = Double(min(max(origin.height - value.translation.height, 220),
                                            bounds.height - Theme.s7))
                    }
                    .onEnded { _ in sizeOrigin = nil }
            )
            .opacity(collapsed ? 0 : 1)
    }

    private var header: some View {
        HStack(spacing: Theme.s3) {
            Circle()
                .fill(session.account.accent)
                .frame(width: 6, height: 6)
            Text(session.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)

            if session.isRunning {
                ProgressView().controlSize(.small).scaleEffect(0.5).frame(width: 12)
            }

            Spacer(minLength: Theme.s4)

            // Collapsed to its title bar rather than closed, so a long answer
            // can keep arriving while you look at the page it's about.
            button(collapsed ? "chevron.up" : "chevron.down",
                   collapsed ? "Expand" : "Collapse") {
                collapsed.toggle()
            }
            button("xmark", "Close") {
                withAnimation(Motion.reveal) { session.miniChatVisible = false }
            }
        }
        .padding(.horizontal, Theme.s5)
        .padding(.vertical, Theme.s4)
        // The title bar is the handle, as it is on every window.
        .contentShape(Rectangle())
        .gesture(moveGesture)
        .onHover { $0 ? NSCursor.openHand.push() : NSCursor.pop() }
    }

    private func button(_ symbol: String, _ label: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverCapsule())
        .help(label)
    }
}
