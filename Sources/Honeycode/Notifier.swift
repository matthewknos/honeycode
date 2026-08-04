import AppKit
import UserNotifications

/// Turn-completion notifications.
///
/// This is the one thing a window full of sessions can do that three terminal
/// windows can't. A long run on work while you're reading something on personal
/// currently announces itself with a five-point dot in the sidebar, which is
/// exactly as easy to miss as it sounds.
///
/// Deliberately quiet: nothing is posted for the session you're already looking
/// at, because a banner telling you about text appearing in front of you is how
/// an app teaches you to turn its notifications off.
enum Notifier {

    /// Broadcast when a notification is clicked, carrying the session's id.
    static let activated = Notification.Name("honeycode.notificationActivated")
    static let sessionKey = "session"

    static func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = Delegate.shared
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// No local "am I authorized" flag. Caching the grant meant a static `Bool`
    /// written from the authorization callback and read from the main thread —
    /// a real data race — and it would have swallowed any turn that finished
    /// before the callback landed. The system drops unauthorized requests
    /// silently anyway, so asking it every time is both simpler and correct.
    static func post(sessionID: UUID, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = [sessionKey: sessionID.uuidString]

        // Identifier is the session, so a second finished turn *replaces* the
        // first rather than stacking. Three sessions shouldn't be able to bury
        // Notification Centre.
        let request = UNNotificationRequest(identifier: sessionID.uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        static let shared = Delegate()

        /// Show a banner even when Honeycode is frontmost. The decision about
        /// whether it's wanted has already been made at the call site — by this
        /// point the session is known not to be the one on screen.
        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            willPresent notification: UNNotification
        ) async -> UNNotificationPresentationOptions {
            [.banner, .sound]
        }

        /// Clicking takes you to the session that finished, which is the only
        /// reason to click it.
        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            didReceive response: UNNotificationResponse
        ) async {
            let info = response.notification.request.content.userInfo
            guard let raw = info[Notifier.sessionKey] as? String,
                  let id = UUID(uuidString: raw) else { return }
            await MainActor.run {
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(
                    name: Notifier.activated, object: nil,
                    userInfo: [Notifier.sessionKey: id])
            }
        }
    }
}
