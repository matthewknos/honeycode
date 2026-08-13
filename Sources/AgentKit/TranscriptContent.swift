import Foundation

// The payloads behind two transcript cards. They are what the adapters
// decode and what a client renders, so they belong with the transcript
// rather than with either view.

struct SearchResult: Identifiable, Codable {
    let id = UUID()
    let title: String
    let url: String

    private enum CodingKeys: String, CodingKey { case title, url }
}

struct Todo: Identifiable, Codable, Sendable, Equatable {
    enum Status: String, Codable { case pending, in_progress, completed, deleted }

    let id: String
    var subject: String
    /// Present-continuous form ("Running tests"), shown while in progress.
    var activeForm: String?
    var status: Status

    var label: String {
        status == .in_progress ? (activeForm ?? subject) : subject
    }
}

extension SearchResult {
    /// Pull sources out of the tool result.
    ///
    /// The result is prose with links in it rather than structured data, so
    /// this scrapes URLs and takes the preceding text as a title. Deliberately
    /// lossy: if nothing matches, the card still renders with its query and
    /// state — better than inventing a shape the CLI doesn't promise.
    static func scrape(_ text: String) -> [SearchResult] {
        guard let regex = try? NSRegularExpression(
            pattern: #"https?://[^\s<>\)\]"']+"#) else { return [] }

        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))

        var seen = Set<String>()
        var out: [SearchResult] = []
        for match in matches.prefix(24) {
            let url = ns.substring(with: match.range)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,;"))
            let host = URL(string: url)?.host ?? url
            guard seen.insert(host + url).inserted else { continue }

            // Title: the nearest preceding line with words on it.
            let head = ns.substring(to: match.range.location)
            let title = head.components(separatedBy: .newlines)
                .last(where: { $0.trimmingCharacters(in: .whitespaces).count > 3 })?
                .trimmingCharacters(in: CharacterSet(charactersIn: " -*#[](:"))
                .prefix(90)

            out.append(SearchResult(
                title: title.map(String.init) ?? host,
                url: url.replacingOccurrences(of: "https://", with: "")))
            if out.count >= 8 { break }
        }
        return out
    }
}
