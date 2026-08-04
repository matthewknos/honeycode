import AppKit
import SwiftUI

/// Syntax highlighting for code blocks, over the vendored Highlightr.
///
/// Honeycode is a GUI for coding agents that rendered every code block in one
/// colour, which is a strange thing for it to have been doing. Writing a
/// highlighter was never the answer — 192 languages is exactly the problem a
/// library exists for — so this is a thin wrapper with three jobs the library
/// doesn't do: appearance, fonts, and not doing the work twice.
/// Off the main thread, on purpose.
///
/// This was `@MainActor`, and both of its callers reach it from a view's
/// `.task` — which inherits the main actor. So up to twenty thousand characters
/// went through a JavaScriptCore parse, an HTML scan and a per-run
/// re-attribution *on the main thread*, in the middle of a reply arriving. The
/// size cap was papering over the symptom.
///
/// Everything below is confined to one serial queue instead: `engines`, the
/// cache and the eviction order are only ever touched there, and callers `await`
/// a result that arrives back on whatever actor asked for it. Nothing on the
/// main thread ever waits on this queue, which is what keeps Highlightr's own
/// occasional hop to main from deadlocking against it.
final class SyntaxHighlighter: @unchecked Sendable {
    static let shared = SyntaxHighlighter()

    private let queue = DispatchQueue(label: "com.matthewquigley.honeycode.highlighter",
                                      qos: .userInitiated)

    /// One engine per appearance. Each holds a JavaScript context with
    /// highlight.js loaded, so swapping the theme on a single shared engine
    /// would re-parse CSS on every light/dark flip — cheaper to keep both warm.
    private var engines: [Bool: Highlightr] = [:]

    private struct Key: Hashable {
        let code: String
        let language: String
        let dark: Bool
    }

    private var cache: [Key: [AttributedString]] = [:]
    private var order: [Key] = []

    /// Beyond this, highlighting costs more than it's worth — a 20k block is a
    /// file dump, not a snippet, and the JS round trip starts to be felt while a
    /// reply is still streaming.
    ///
    /// Measured in UTF-8 bytes rather than characters: counting graphemes walks
    /// the whole string, which is a linear scan run per delta to decide whether
    /// to do a linear amount of work.
    private static let sizeLimit = 20_000

    private func engine(dark: Bool) -> Highlightr? {
        if let existing = engines[dark] { return existing }
        guard let engine = Highlightr() else { return nil }
        engine.setTheme(to: dark ? "xcode-dark" : "xcode")
        // Highlightr's themes ship their own face and size. Overriding keeps
        // code in the same mono the rest of the app uses, so a highlighted
        // block and a diff still line up.
        engine.theme.setCodeFont(.monospacedSystemFont(ofSize: 12, weight: .regular))
        engines[dark] = engine
        return engine
    }

    /// Highlighted lines, or `nil` to render plain.
    ///
    /// Split per line because the code view draws its own gutter — one
    /// attributed blob would have to be re-measured against line numbers, and
    /// wrapped lines would stop lining up with them.
    func lines(code: String, language: String, dark: Bool) async -> [AttributedString]? {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(
                    returning: self.compute(code: code, language: language, dark: dark))
            }
        }
    }

    /// The work itself. Only ever called on `queue`.
    private func compute(code: String, language: String, dark: Bool) -> [AttributedString]? {
        guard code.utf8.count <= Self.sizeLimit else { return nil }
        let key = Key(code: code, language: language, dark: dark)
        if let hit = cache[key] { return hit }

        // An unlabelled fence gets auto-detection, which highlight.js is good
        // at. Guessing a language ourselves would be worse than asking.
        let name = language.isEmpty ? nil : Self.canonical(language)
        guard let engine = engine(dark: dark),
              let highlighted = engine.highlight(code, as: name) else { return nil }

        let result = Self.split(highlighted)
        // Streaming a block re-highlights it on every delta, so the cache would
        // grow a copy per keystroke without a ceiling. Evict oldest-first: this
        // used to `removeAll()`, which threw away every settled block in the
        // transcript each time a streaming reply filled the cache and turned
        // the memoisation into a re-highlight storm — the same mistake the
        // markdown block cache documents having fixed.
        cache[key] = result
        order.append(key)
        while order.count > 200 {
            cache.removeValue(forKey: order.removeFirst())
        }
        return result
    }

    /// A file's language, for diffs — which carry a path rather than a fence.
    static func language(forPath path: String) -> String {
        canonical((path as NSString).pathExtension)
    }

    /// Fence tags agents actually write, mapped to what highlight.js knows.
    static func canonical(_ language: String) -> String {
        switch language.lowercased() {
        case "sh", "shell", "zsh", "console": return "bash"
        case "yml":                            return "yaml"
        case "jsonc", "json5":                 return "json"
        case "tsx":                            return "typescript"
        case "jsx":                            return "javascript"
        case "objc", "objective-c":            return "objectivec"
        case "c++":                            return "cpp"
        case "py":                             return "python"
        case "rb":                             return "ruby"
        case "rs":                             return "rust"
        case "kt":                             return "kotlin"
        case "text", "txt", "plain":           return "plaintext"
        default:                               return language.lowercased()
        }
    }

    /// Break the attributed result at newlines, keeping each run's attributes.
    private static func split(_ attributed: NSAttributedString) -> [AttributedString] {
        let text = attributed.string as NSString
        var lines: [AttributedString] = []
        var start = 0

        while start <= text.length {
            let searchRange = NSRange(location: start, length: text.length - start)
            let newline = text.range(of: "\n", range: searchRange)
            let end = newline.location == NSNotFound ? text.length : newline.location
            let slice = attributed.attributedSubstring(
                from: NSRange(location: start, length: end - start))
            lines.append(AttributedString(slice))
            if newline.location == NSNotFound { break }
            start = end + 1
        }
        return lines
    }
}
