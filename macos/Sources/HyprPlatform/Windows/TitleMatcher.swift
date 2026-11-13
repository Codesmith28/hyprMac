import Foundation

/// Compiled `rules.float_title` / `rules.ignore_title` patterns: case-insensitive regular expressions
/// searched anywhere in the title (anchor with ^ and $). The core already validated the grammar and
/// refused catastrophic shapes; titles are additionally truncated before matching. A pattern the
/// system regex engine cannot compile is skipped (`rejected` lists it).
public struct TitleMatcher: Equatable, @unchecked Sendable {
    /// Longest title (characters) that is matched.
    public static let maxTitleLength = 512

    public let patterns: [String]
    private let regexes: [NSRegularExpression]
    public let rejected: [String]

    public init(_ patterns: [String] = []) {
        var ok: [NSRegularExpression] = []
        var bad: [String] = []
        for p in patterns {
            if let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) { ok.append(re) } else { bad.append(p) }
        }
        self.patterns = patterns
        self.regexes = ok
        self.rejected = bad
    }

    public var isEmpty: Bool { regexes.isEmpty }

    public func matches(_ title: String) -> Bool {
        guard !regexes.isEmpty else { return false }
        let t = title.count > Self.maxTitleLength ? String(title.prefix(Self.maxTitleLength)) : title
        let range = NSRange(t.startIndex..., in: t)
        return regexes.contains { $0.firstMatch(in: t, options: [], range: range) != nil }
    }

    public static func == (a: TitleMatcher, b: TitleMatcher) -> Bool { a.patterns == b.patterns }
}
