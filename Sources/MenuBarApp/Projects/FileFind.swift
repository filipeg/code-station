import Foundation

struct FileFindResult: Equatable, Sendable {
    var matches: [NSRange] = []
    var hasMore = false
}

// Search over the whole document rather than line by line. Ranges are UTF-16 offsets into
// the text, which is what the text view wants back when a match has to be coloured in or
// scrolled to, including when the text before it uses emoji.
enum FileFind {
    static let matchLimit = 10_000

    static func search(_ query: String, in text: String) -> FileFindResult {
        guard !query.isEmpty else { return FileFindResult() }

        let document = text as NSString
        var matches: [NSRange] = []
        var remaining = NSRange(location: 0, length: document.length)
        while remaining.length > 0 {
            let range = document.range(of: query, options: .caseInsensitive, range: remaining)
            guard range.location != NSNotFound, range.length > 0 else { break }
            if matches.count == matchLimit {
                return FileFindResult(matches: matches, hasMore: true)
            }
            matches.append(range)
            let next = NSMaxRange(range)
            remaining = NSRange(location: next, length: document.length - next)
        }
        return FileFindResult(matches: matches)
    }
}
