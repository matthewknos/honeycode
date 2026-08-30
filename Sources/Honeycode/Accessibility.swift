import SwiftUI
import AppKit
import Combine

/// The system settings this app has to actually honour.
///
/// SwiftUI hands out `accessibilityReduceMotion` as an environment value and
/// nothing equivalent for transparency, which is the one that matters most
/// here: every translucent surface in this window is an offscreen compositing
/// pass per frame, and the Macs where that is felt are exactly the Macs where
/// somebody is most likely to have turned the setting on.
///
/// So it is read from `NSWorkspace` and republished. An `ObservableObject`
/// rather than an environment value because the reading is process-wide and
/// the notification is a single subscription — thirty views each installing an
/// observer for one boolean is thirty observers.
///
/// Two settings, one object, because they arrive on the same notification:
/// macOS posts `accessibilityDisplayOptionsDidChangeNotification` for the lot.
@MainActor
final class Accessibility: ObservableObject {

    static let shared = Accessibility()

    /// Whether to draw translucent surfaces at all.
    ///
    /// What the system does with its own chrome when this is on is exactly
    /// this: the material becomes an opaque fill. Following it is not a
    /// concession — a card that samples what is behind it is unreadable to the
    /// person who turned this on, which is why they turned it on.
    @Published private(set) var reduceTransparency: Bool

    /// The same reading SwiftUI's environment value gives, for the places that
    /// aren't in a view — and so the two can't disagree about which is live.
    @Published private(set) var reduceMotion: Bool

    private var observer: NSObjectProtocol?

    private init() {
        let workspace = NSWorkspace.shared
        reduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency
        reduceMotion = workspace.accessibilityDisplayShouldReduceMotion
        observer = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                // `MainActor.assumeIsolated` rather than a `Task`: the queue is
                // `.main` and a hop would let a redraw happen against the old
                // value first, which is a visible flicker for a setting people
                // toggle to stop things moving.
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let now = NSWorkspace.shared
                    self.reduceTransparency = now.accessibilityDisplayShouldReduceTransparency
                    self.reduceMotion = now.accessibilityDisplayShouldReduceMotion
                }
            }
    }

    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}
