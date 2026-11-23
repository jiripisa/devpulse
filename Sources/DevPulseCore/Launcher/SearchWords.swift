import Foundation

/// The words of a launcher search: folded (no case, no diacritics), and split at anything that is
/// not a letter, a digit, `-`, `_` or `.`, so no search syntax (quotes, `repo:`, brackets) gets
/// through to Jira or GitHub.
public enum SearchWords {
    public static func words(in text: String) -> [String] {
        fold(text)
            .split { !($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }
            .map(String.init)
    }

    /// Whether every word appears somewhere in the fields.
    public static func matches(_ words: [String], in fields: [String]) -> Bool {
        guard !words.isEmpty else { return false }
        let haystack = fields.map(fold).joined(separator: " ")
        return words.allSatisfy { haystack.contains($0) }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
    }
}

/// A search for words in the summaries of the projects' tickets and the titles of the
/// repositories' PRs.
public struct TextSearch: Hashable, Sendable {
    public var words: [String]
    public var projects: [String]
    public var repos: [String]

    public init(words: [String], projects: [String], repos: [String]) {
        self.words = words
        self.projects = projects
        self.repos = repos
    }
}
