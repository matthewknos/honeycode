import SwiftUI

/// Finding a dev server in command output.
enum DevServer {

    /// Loopback URLs, in the shapes the common tools print them.
    ///
    /// Anchored to loopback deliberately. Matching any URL would turn a link in
    /// a README, or a docs URL an agent happened to `curl`, into a "preview"
    /// button pointing at the open internet — and the sandbox exists precisely
    /// to keep the web view off it.
    private static let pattern = try? NSRegularExpression(
        pattern: #"https?://(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\])(?::(\d{2,5}))?(?:/\S*)?"#,
        options: .caseInsensitive)

    static func find(in output: String) -> URL? {
        guard let pattern else { return nil }
        let range = NSRange(output.startIndex..., in: output)
        // Last match wins: a server that restarts on a new port prints both,
        // and the newest line is the live one.
        guard let match = pattern.matches(in: output, range: range).last,
              let found = Range(match.range, in: output) else { return nil }

        var text = String(output[found])
        // `0.0.0.0` means "every interface" to a server and nothing usable to a
        // browser, so it's rewritten to the one address that will connect.
        text = text.replacingOccurrences(of: "0.0.0.0", with: "localhost")
        // Trailing punctuation from prose around the URL.
        while let last = text.last, ".,;)]".contains(last) { text.removeLast() }
        return URL(string: text)
    }
}
