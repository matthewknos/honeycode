import SwiftUI
import AppKit

// Just enough of the app for WebPreview.swift to compile on its own.
enum Theme {
    static let s1: CGFloat = 2
    static let s2: CGFloat = 4
    static let s3: CGFloat = 6
    static let s4: CGFloat = 8
}
extension Color { static var diffDelText: Color { Color(nsColor: .systemRed) } }
enum Motion { static let reveal = Animation.easeOut(duration: 0.16) }
enum Support {
    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask).first!
            .appendingPathComponent("Honeycode", isDirectory: true)
    }
}
struct HoverCapsule: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}
private struct DevServerPortKey: EnvironmentKey { static let defaultValue: Int? = nil }
extension EnvironmentValues {
    var devServerPort: Int? {
        get { self[DevServerPortKey.self] }
        set { self[DevServerPortKey.self] = newValue }
    }
}
