import Foundation

/// What was typed into the quick launcher (spec §5.7): `gh …` or `jira …`.
public enum LauncherQuery: Equatable, Sendable {
    case github(repo: String?, number: Int?, text: String)
    case jira(key: String?, number: Int?, text: String)
    case empty

    public static func parse(_ input: String) -> LauncherQuery {
        let words = input.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let command = words.first?.lowercased() else { return .empty }
        let rest = Array(words.dropFirst())
        switch command {
        case "gh": return parseGitHub(rest)
        case "jira": return parseJira(rest)
        default: return .empty
        }
    }

    private static func parseGitHub(_ words: [String]) -> LauncherQuery {
        if words.count == 1, let number = number(words[0]) {
            return .github(repo: nil, number: number, text: "")
        }
        if words.count == 2, let number = number(words[1]) {
            return .github(repo: words[0], number: number, text: "")
        }
        return .github(repo: nil, number: nil, text: words.joined(separator: " "))
    }

    private static func parseJira(_ words: [String]) -> LauncherQuery {
        if words.count == 1 {
            if let number = number(words[0]) { return .jira(key: nil, number: number, text: "") }
            if words[0].wholeMatch(of: /[A-Za-z][A-Za-z0-9]*-\d+/) != nil {
                return .jira(key: words[0].uppercased(), number: nil, text: "")
            }
        }
        return .jira(key: nil, number: nil, text: words.joined(separator: " "))
    }

    private static func number(_ word: String) -> Int? {
        word.wholeMatch(of: /\d+/) != nil ? Int(word) : nil
    }
}
