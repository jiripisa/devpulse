import Foundation

// The shared data model. Its JSON form is the contract with the Rust TUI,
// see `protocol/fixtures/snapshot-v1.json`.

public enum CheckState: String, Codable, Sendable, Equatable {
    case none, pending, success, failure, error

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CheckState(rawValue: raw) ?? .none
    }
}

public enum ReviewDecision: String, Codable, Sendable, Equatable {
    case none, reviewRequired, approved, changesRequested

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ReviewDecision(rawValue: raw) ?? .none
    }
}

public enum SourceState: String, Codable, Sendable, Equatable {
    case ok, fetching, error, disabled, unconfigured
}

public enum StatusCategory: String, Codable, Sendable, Equatable {
    case todo, inProgress, done
}

public enum AuthorKind: String, Codable, Sendable, Equatable {
    case human, bot, copilot
}

public enum SessionStatus: String, Codable, Sendable, Equatable {
    case busy, waiting, idle, unknown

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SessionStatus(rawValue: raw) ?? .unknown
    }
}

public struct SourceStatus: Codable, Sendable, Equatable {
    public var state: SourceState
    public var lastSuccess: Date?
    public var message: String?

    public init(state: SourceState, lastSuccess: Date? = nil, message: String? = nil) {
        self.state = state
        self.lastSuccess = lastSuccess
        self.message = message
    }
}

public struct Sources: Codable, Sendable, Equatable {
    public var github: SourceStatus
    public var jira: SourceStatus
    public var claude: SourceStatus

    public init(github: SourceStatus, jira: SourceStatus, claude: SourceStatus) {
        self.github = github
        self.jira = jira
        self.claude = claude
    }
}

public struct Comment: Codable, Sendable, Equatable {
    public var id: String
    /// GitHub login (PRs) or Jira accountId (tickets), so the app can recognise its own comments.
    public var author: String
    /// Display name, when the source provides one.
    public var authorName: String?
    public var authorKind: AuthorKind
    public var createdAt: Date

    public init(id: String, author: String, authorName: String? = nil, authorKind: AuthorKind, createdAt: Date) {
        self.id = id
        self.author = author
        self.authorName = authorName
        self.authorKind = authorKind
        self.createdAt = createdAt
    }
}

public struct PullRequest: Codable, Sendable, Equatable {
    /// GraphQL node id.
    public var id: String
    /// `owner/name`.
    public var repo: String
    /// `owner/name` of the repository the branch lives in: another one for a PR from a fork. Nil
    /// when GitHub does not say (a deleted fork); the branch is then looked up in `repo`.
    public var headRepo: String?
    public var number: Int
    public var title: String
    public var url: String
    public var headBranch: String
    public var headOid: String
    public var jiraKey: String?
    public var checks: CheckState
    public var reviewDecision: ReviewDecision
    public var approvals: Int
    public var pendingReviewers: Int
    public var commentCount: Int
    public var lastCommentAt: Date?
    public var requestedDirectly: Bool
    public var updatedAt: Date
    public var recentComments: [Comment]

    public init(
        id: String, repo: String, headRepo: String? = nil, number: Int, title: String, url: String,
        headBranch: String, headOid: String, jiraKey: String? = nil,
        checks: CheckState, reviewDecision: ReviewDecision,
        approvals: Int, pendingReviewers: Int, commentCount: Int,
        lastCommentAt: Date? = nil, requestedDirectly: Bool, updatedAt: Date,
        recentComments: [Comment]
    ) {
        self.id = id
        self.repo = repo
        self.headRepo = headRepo
        self.number = number
        self.title = title
        self.url = url
        self.headBranch = headBranch
        self.headOid = headOid
        self.jiraKey = jiraKey
        self.checks = checks
        self.reviewDecision = reviewDecision
        self.approvals = approvals
        self.pendingReviewers = pendingReviewers
        self.commentCount = commentCount
        self.lastCommentAt = lastCommentAt
        self.requestedDirectly = requestedDirectly
        self.updatedAt = updatedAt
        self.recentComments = recentComments
    }
}

/// A ticket linked to another one in Jira ("blocks", "relates to", ...), as the other ticket's
/// `issuelinks` field describes it.
public struct RelatedTicket: Codable, Sendable, Equatable {
    public var key: String
    /// Empty when Jira leaves it out.
    public var summary: String
    /// The status name; empty, with the category `todo`, when Jira leaves it out.
    public var status: String
    public var statusCategory: StatusCategory
    /// How the other ticket relates to this one, in Jira's words: "blocks", "is blocked by",
    /// "relates to".
    public var relation: String

    public init(key: String, summary: String, status: String, statusCategory: StatusCategory, relation: String) {
        self.key = key
        self.summary = summary
        self.status = status
        self.statusCategory = statusCategory
        self.relation = relation
    }
}

public struct Ticket: Codable, Sendable, Equatable {
    public var key: String
    public var summary: String
    public var status: String
    public var statusCategory: StatusCategory
    public var priority: String?
    public var url: String
    public var updatedAt: Date
    public var commentCount: Int
    public var lastCommentAt: Date?
    public var recentComments: [Comment]
    /// Its issue links. Added after protocol v1 shipped: missing in older JSON, read as empty.
    public var related: [RelatedTicket]

    public init(
        key: String, summary: String, status: String, statusCategory: StatusCategory,
        priority: String? = nil, url: String, updatedAt: Date, commentCount: Int,
        lastCommentAt: Date? = nil, recentComments: [Comment], related: [RelatedTicket] = []
    ) {
        self.key = key
        self.summary = summary
        self.status = status
        self.statusCategory = statusCategory
        self.priority = priority
        self.url = url
        self.updatedAt = updatedAt
        self.commentCount = commentCount
        self.lastCommentAt = lastCommentAt
        self.recentComments = recentComments
        self.related = related
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        summary = try c.decode(String.self, forKey: .summary)
        status = try c.decode(String.self, forKey: .status)
        statusCategory = try c.decode(StatusCategory.self, forKey: .statusCategory)
        priority = try c.decodeIfPresent(String.self, forKey: .priority)
        url = try c.decode(String.self, forKey: .url)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        commentCount = try c.decode(Int.self, forKey: .commentCount)
        lastCommentAt = try c.decodeIfPresent(Date.self, forKey: .lastCommentAt)
        recentComments = try c.decode([Comment].self, forKey: .recentComments)
        related = try c.decodeIfPresent([RelatedTicket].self, forKey: .related) ?? []
    }
}

public struct ClaudeSession: Codable, Sendable, Equatable {
    public var pid: Int
    public var name: String
    public var cwd: String
    public var status: SessionStatus
    public var waitingFor: String?
    public var jiraKey: String?
    public var updatedAt: Date

    public init(
        pid: Int, name: String, cwd: String, status: SessionStatus,
        waitingFor: String? = nil, jiraKey: String? = nil, updatedAt: Date
    ) {
        self.pid = pid
        self.name = name
        self.cwd = cwd
        self.status = status
        self.waitingFor = waitingFor
        self.jiraKey = jiraKey
        self.updatedAt = updatedAt
    }
}

public struct Snapshot: Codable, Sendable, Equatable {
    public var appVersion: String
    public var generatedAt: Date
    public var jiraBaseURL: String?
    public var sources: Sources
    public var myPullRequests: [PullRequest]
    public var reviewRequests: [PullRequest]
    public var tickets: [Ticket]
    /// The Jira tickets of PRs that are not in `tickets` (not assigned to me), for the PR
    /// detail. Never a reason for a notification. Added after protocol v1 shipped: missing in
    /// older JSON, read as empty.
    public var linkedTickets: [Ticket]
    public var sessions: [ClaudeSession]

    public init(
        appVersion: String, generatedAt: Date, jiraBaseURL: String? = nil, sources: Sources,
        myPullRequests: [PullRequest], reviewRequests: [PullRequest],
        tickets: [Ticket], linkedTickets: [Ticket] = [], sessions: [ClaudeSession]
    ) {
        self.appVersion = appVersion
        self.generatedAt = generatedAt
        self.jiraBaseURL = jiraBaseURL
        self.sources = sources
        self.myPullRequests = myPullRequests
        self.reviewRequests = reviewRequests
        self.tickets = tickets
        self.linkedTickets = linkedTickets
        self.sessions = sessions
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appVersion = try c.decode(String.self, forKey: .appVersion)
        generatedAt = try c.decode(Date.self, forKey: .generatedAt)
        jiraBaseURL = try c.decodeIfPresent(String.self, forKey: .jiraBaseURL)
        sources = try c.decode(Sources.self, forKey: .sources)
        myPullRequests = try c.decode([PullRequest].self, forKey: .myPullRequests)
        reviewRequests = try c.decode([PullRequest].self, forKey: .reviewRequests)
        tickets = try c.decode([Ticket].self, forKey: .tickets)
        linkedTickets = try c.decodeIfPresent([Ticket].self, forKey: .linkedTickets) ?? []
        sessions = try c.decode([ClaudeSession].self, forKey: .sessions)
    }

    /// Encoder for the wire format: ISO 8601 dates, stable key order.
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    /// Decoder for the wire format: ISO 8601 dates.
    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
