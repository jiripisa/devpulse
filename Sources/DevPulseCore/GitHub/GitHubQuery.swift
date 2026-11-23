import Foundation

/// The single GraphQL request that feeds the GitHub source. One page of 50 per search, no
/// pagination (spec §7).
enum GitHubQuery {
    static let endpoint = URL(string: "https://api.github.com/graphql")!

    private static let pullRequestFields = """
        id number title url headRefName headRefOid updatedAt
        repository { nameWithOwner }
        headRepository { nameWithOwner }
        reviewDecision
        commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
        latestOpinionatedReviews(first: 50) { nodes { state } }
        reviewRequests(first: 1) { totalCount }
        comments(last: 10) { totalCount nodes { id createdAt author { login __typename ... on User { name } } } }
        reviews(last: 10) { totalCount nodes { id submittedAt createdAt author { login __typename ... on User { name } } } }
        """

    private static func search(alias: String, terms: String) -> String {
        """
        \(alias): search(query: "\(terms)", type: ISSUE, first: 50) {
          nodes { ... on PullRequest { \(pullRequestFields) } }
        }
        """
    }

    static func text(includeTeamRequests: Bool) -> String {
        var searches = [
            search(alias: "mine", terms: "is:open is:pr author:@me archived:false"),
            search(alias: "direct", terms: "is:open is:pr user-review-requested:@me"),
        ]
        if includeTeamRequests {
            searches.append(search(alias: "team", terms: "is:open is:pr review-requested:@me"))
        }
        return "query { viewer { login } \(searches.joined(separator: "\n")) }"
    }

    static func body(includeTeamRequests: Bool) throws -> Data {
        try JSONEncoder().encode(["query": text(includeTeamRequests: includeTeamRequests)])
    }

    /// The launcher's lookup of PRs by number: one aliased `repository { pullRequest }` per ref
    /// (`p0`, `p1`, …), with owner, name and number as variables, so nothing typed ends up in
    /// the query text.
    static func lookupBody(_ refs: [PullRequestRef]) throws -> Data {
        var declarations: [String] = []
        var fields: [String] = []
        var variables: [String: Any] = [:]
        for (i, ref) in refs.enumerated() {
            let parts = ref.repo.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            declarations.append("$o\(i): String!, $n\(i): String!, $k\(i): Int!")
            fields.append(
                "p\(i): repository(owner: $o\(i), name: $n\(i)) { pullRequest(number: $k\(i)) { number title state isDraft url headRefName } }")
            variables["o\(i)"] = parts[0]
            variables["n\(i)"] = parts[1]
            variables["k\(i)"] = ref.number
        }
        let query = "query(\(declarations.joined(separator: ", "))) { \(fields.joined(separator: " ")) }"
        return try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
    }

    /// The search for the PRs that name a Jira key in these repositories; the search text is a
    /// variable, like the lookup's values.
    static func searchBody(key: String, repos: [String]) throws -> Data {
        // Title and description only: a key someone mentioned in a comment does not make it the
        // ticket's PR.
        try searchBody(terms: "\"\(key)\" in:title,body", repos: repos)
    }

    /// The search for PRs with these words in the title.
    static func searchBody(words: [String], repos: [String]) throws -> Data {
        try searchBody(terms: "\(words.joined(separator: " ")) in:title", repos: repos)
    }

    private static func searchBody(terms: String, repos: [String]) throws -> Data {
        let text = (["\(terms) is:pr"] + repos.map { "repo:\($0)" }).joined(separator: " ")
        let query = """
            query($q: String!) { search(query: $q, type: ISSUE, first: \(maxSearchResults)) { nodes { \
            ... on PullRequest { number title state isDraft url headRefName repository { nameWithOwner } } } } }
            """
        return try JSONSerialization.data(withJSONObject: ["query": query, "variables": ["q": text]])
    }

    static let maxSearchResults = 20
}
