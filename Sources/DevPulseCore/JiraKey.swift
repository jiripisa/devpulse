import Foundation

/// Finds Jira issue keys (e.g. `STORE-2474`) in free text such as PR titles and branch names.
public enum JiraKey {

    /// Standard names written like keys (`UTF-8`, `SHA-256`, `ISO-8601`): skipped unless their
    /// project is a known one.
    static let denylist: Set<String> = ["UTF", "SHA", "ISO", "RFC", "HTTP"]

    /// The Jira key in `text`, or `nil` when there is none. A key is a project key of at least
    /// 2 characters, a dash and the issue number, not glued to other letters or digits;
    /// matching is case-sensitive. Of several candidates, the first whose project is in
    /// `knownProjects` wins; otherwise the first not on the denylist.
    public static func find(in text: String, knownProjects: Set<String> = []) -> String? {
        find(inAny: [text], knownProjects: knownProjects)
    }

    /// The same over several texts in order, e.g. a PR's title, then its branch: a known
    /// project's key in a later text beats an unknown one in an earlier text.
    public static func find(inAny texts: [String], knownProjects: Set<String> = []) -> String? {
        let candidates = texts.flatMap { text in
            text.matches(of: /(?:^|[^A-Za-z0-9])([A-Z][A-Z0-9]+-\d+)(?![A-Za-z0-9])/).map { String($0.output.1) }
        }
        if let known = candidates.first(where: { knownProjects.contains(project(of: $0)) }) { return known }
        return candidates.first { !denylist.contains(project(of: $0)) }
    }

    /// `STORE` of `STORE-2474`.
    static func project(of key: String) -> String {
        key.lastIndex(of: "-").map { String(key[..<$0]) } ?? key
    }
}
