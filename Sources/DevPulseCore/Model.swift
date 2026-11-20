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
        id: String, repo: String, number: Int, title: String, url: String,
        headBranch: String, headOid: String, jiraKey: String? = nil,
        checks: CheckState, reviewDecision: ReviewDecision,
        approvals: Int, pendingReviewers: Int, commentCount: Int,
        lastCommentAt: Date? = nil, requestedDirectly: Bool, updatedAt: Date,
        recentComments: [Comment]
    ) {
        self.id = id
        self.repo = repo
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

    public init(
        key: String, summary: String, status: String, statusCategory: StatusCategory,
        priority: String? = nil, url: String, updatedAt: Date, commentCount: Int,
        lastCommentAt: Date? = nil, recentComments: [Comment]
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
    public var sessions: [ClaudeSession]

    public init(
        appVersion: String, generatedAt: Date, jiraBaseURL: String? = nil, sources: Sources,
        myPullRequests: [PullRequest], reviewRequests: [PullRequest],
        tickets: [Ticket], sessions: [ClaudeSession]
    ) {
        self.appVersion = appVersion
        self.generatedAt = generatedAt
        self.jiraBaseURL = jiraBaseURL
        self.sources = sources
        self.myPullRequests = myPullRequests
        self.reviewRequests = reviewRequests
        self.tickets = tickets
        self.sessions = sessions
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
