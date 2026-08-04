import SwiftUI

/// The conversation, floating over a full-width preview.
///
/// Full width hides the transcript, which is right until the moment you want to
/// say "make that button bigger" about the thing you're looking at. Closing the
/// preview to type and reopening it to check loses the very comparison you were
/// making. So the chat comes to the preview instead.
///
/// The real `ComposerView` and the real `TranscriptView` rather than a cut-down
/// pair — streaming, markdown, `@` mentions and slash commands all work here
/// because it *is* the same conversation — but the transcript runs in its plain
/// mode.
///
/// That's the one thing this window shouldn't share. Behind it, at full width,
/// is the document; a 400pt preview of that same document inside the card, and
/// four hundred lines of the source that produced it, are two worse views of
/// what you're already looking at. What the preview can't tell you is what the
/// agent says it did — so that's what's left.
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

    /// Live drag state, separate from what's stored.
    ///
    /// `@AppStorage` writes to `UserDefaults` on every assignment and a drag
    /// assigns sixty times a second, which hammers the defaults system and
    /// stutters visibly — the browser divider was split for exactly this reason
    /// and carries the note. Moving and resizing the card had both kept writing
    /// straight through. Only the final position and size are stored.
    @State private var liveX: Double?
    @State private var liveY: Double?
    @State private var liveWidth: Double?
    @State private var liveHeight: Double?

    private var currentX: Double { liveX ?? offsetX }
    private var currentY: Double { liveY ?? offsetY }

    private var cardWidth: CGFloat {
        min(CGFloat(liveWidth ?? width), max(340, bounds.width - Theme.s7))
    }

    private var cardHeight: CGFloat {
        min(CGFloat(liveHeight ?? height), max(200, bounds.height - Theme.s7))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !collapsed {
                Divider().overlay(Theme.rule)
                TranscriptView(session: session,
                               mode: .summary, width: cardWidth - Theme.s7,
                               panelled: false, plain: true)
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
        .shadow(color: .black.opacity(0.3), radius: 22, y: 8)
        .offset(x: clampedX, y: clampedY)
        .animation(Motion.disclose, value: collapsed)
    }

    // MARK: Moving

    /// Anchored bottom-trailing, so the offsets only ever go negative — and
    /// they're clamped to the page rather than trusted, because a resized
    /// window can otherwise strand the card off-screen with no way back.
    private var clampedX: CGFloat {
        min(0, max(CGFloat(currentX), -(bounds.width - cardWidth - Theme.s7)))
    }

    private var clampedY: CGFloat {
        min(0, max(CGFloat(currentY), -(bounds.height - cardHeight - Theme.s7)))
    }

    private var moveGesture: some Gesture {
        DragGesture(coordinateSpace: .global)
            .onChanged { value in
                let origin = dragOrigin ?? CGSize(width: clampedX, height: clampedY)
                if dragOrigin == nil { dragOrigin = origin }
                liveX = Double(origin.width + value.translation.width)
                liveY = Double(origin.height + value.translation.height)
            }
            .onEnded { _ in
                dragOrigin = nil
                // Store the clamped values, not the raw ones, or the card
                // remembers a position it was never allowed to be in.
                offsetX = Double(clampedX)
                offsetY = Double(clampedY)
                liveX = nil
                liveY = nil
            }
    }

    // MARK: Resizing

    /// The last thing in the title bar.
    ///
    /// It floated in the top-left corner before, as an overlay — which is the
    /// corner where the session's accent dot and its name already live, so the
    /// glyph sat directly on top of the dot. A control in a row of controls
    /// can't collide with anything; an overlay in a corner collides with
    /// whatever is in that corner.
    ///
    /// The card is pinned bottom-trailing, so it grows up and to the left —
    /// which is what the unrotated arrows point at. The old copy was rotated
    /// 90° to suit the left-hand corner it used to sit in.
    private var resizeGrip: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
            .hoverCursor(.crosshair)
            // High priority, because it now sits *inside* the title bar, and
            // the title bar is the drag handle that moves the whole card. Two
            // drag gestures on nested views is exactly the case that needs
            // saying which one wins.
            .highPriorityGesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        let origin = sizeOrigin ?? CGSize(width: cardWidth, height: cardHeight)
                        if sizeOrigin == nil { sizeOrigin = origin }
                        // 340 is where the composer rail stops fitting even
                        // stripped down — below that it isn't a small window,
                        // it's a broken one.
                        liveWidth = Double(min(max(origin.width - value.translation.width, 340),
                                               bounds.width - Theme.s7))
                        liveHeight = Double(min(max(origin.height - value.translation.height, 220),
                                                bounds.height - Theme.s7))
                    }
                    .onEnded { _ in
                        sizeOrigin = nil
                        if let liveWidth { width = liveWidth }
                        if let liveHeight { height = liveHeight }
                        liveWidth = nil
                        liveHeight = nil
                    }
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
            resizeGrip
        }
        .padding(.horizontal, Theme.s5)
        .padding(.vertical, Theme.s4)
        // The title bar is the handle, as it is on every window.
        .contentShape(Rectangle())
        .gesture(moveGesture)
        .hoverCursor(.openHand)
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
