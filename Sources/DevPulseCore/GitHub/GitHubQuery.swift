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
}
