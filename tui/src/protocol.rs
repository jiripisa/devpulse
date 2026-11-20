//! Serde mirrors of the DevPulse wire protocol (`protocol/fixtures/snapshot-v1.json`).
//!
//! Dates stay ISO 8601 strings. Unknown enum values map to `Unknown` and unknown fields are
//! ignored, so a newer app does not break an older terminal client.

use serde::{Deserialize, Serialize};

/// Version of the newline-delimited JSON protocol.
pub const PROTOCOL_VERSION: u32 = 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CheckState {
    None,
    Pending,
    Success,
    Failure,
    Error,
    #[serde(other)]
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ReviewDecision {
    None,
    ReviewRequired,
    Approved,
    ChangesRequested,
    #[serde(other)]
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SourceState {
    Ok,
    Fetching,
    Error,
    Disabled,
    Unconfigured,
    #[serde(other)]
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum StatusCategory {
    Todo,
    InProgress,
    Done,
    #[serde(other)]
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AuthorKind {
    Human,
    Bot,
    Copilot,
    #[serde(other)]
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SessionStatus {
    Busy,
    Waiting,
    Idle,
    #[serde(other)]
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum UpgradePhase {
    Checking,
    Downloading,
    Installing,
    Restarting,
    UpToDate,
    Failed,
    #[serde(other)]
    Unknown,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceStatus {
    pub state: SourceState,
    pub last_success: Option<String>,
    pub message: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct Sources {
    pub github: SourceStatus,
    pub jira: SourceStatus,
    pub claude: SourceStatus,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Comment {
    pub id: String,
    /// GitHub login (PRs) or Jira accountId (tickets).
    pub author: String,
    pub author_name: Option<String>,
    pub author_kind: AuthorKind,
    pub created_at: String,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PullRequest {
    /// GraphQL node id.
    pub id: String,
    /// `owner/name`.
    pub repo: String,
    /// `owner/name` of the repository the branch lives in (a fork); `None` when unknown.
    pub head_repo: Option<String>,
    pub number: u64,
    pub title: String,
    pub url: String,
    pub head_branch: String,
    pub head_oid: String,
    pub jira_key: Option<String>,
    pub checks: CheckState,
    pub review_decision: ReviewDecision,
    pub approvals: u32,
    pub pending_reviewers: u32,
    pub comment_count: u32,
    pub last_comment_at: Option<String>,
    pub requested_directly: bool,
    pub updated_at: String,
    #[serde(default)]
    pub recent_comments: Vec<Comment>,
}

/// A ticket linked to another one in Jira ("blocks", "relates to", ...).
#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RelatedTicket {
    pub key: String,
    #[serde(default)]
    pub summary: String,
    #[serde(default)]
    pub status: String,
    pub status_category: StatusCategory,
    /// In Jira's words: "blocks", "is blocked by", "relates to".
    pub relation: String,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Ticket {
    pub key: String,
    pub summary: String,
    pub status: String,
    pub status_category: StatusCategory,
    pub priority: Option<String>,
    pub url: String,
    pub updated_at: String,
    pub comment_count: u32,
    pub last_comment_at: Option<String>,
    #[serde(default)]
    pub recent_comments: Vec<Comment>,
    /// Added after v1 shipped; an older app leaves it out.
    #[serde(default)]
    pub related: Vec<RelatedTicket>,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClaudeSession {
    pub pid: u32,
    pub name: String,
    pub cwd: String,
    pub status: SessionStatus,
    pub waiting_for: Option<String>,
    pub jira_key: Option<String>,
    pub updated_at: String,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub app_version: String,
    pub generated_at: String,
    #[serde(rename = "jiraBaseURL")]
    pub jira_base_url: Option<String>,
    pub sources: Sources,
    pub my_pull_requests: Vec<PullRequest>,
    pub review_requests: Vec<PullRequest>,
    pub tickets: Vec<Ticket>,
    /// The tickets of PRs that are not in `tickets` (not assigned to me). Added after v1
    /// shipped; an older app leaves it out.
    #[serde(default)]
    pub linked_tickets: Vec<Ticket>,
    pub sessions: Vec<ClaudeSession>,
}

/// What `open` refers to; the `id` is the PR id, ticket key or session pid.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum OpenKind {
    Pr,
    Ticket,
    Session,
    JiraForPr,
}

/// Client to server.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum ClientMessage {
    Hello { protocol: u32 },
    Refresh,
    OpenSettings,
    Upgrade,
    Open { kind: OpenKind, id: String },
}

/// Server to client. Unknown message types decode to `Unknown`.
#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum ServerMessage {
    Snapshot {
        #[serde(default)]
        protocol: u32,
        data: Box<Snapshot>,
    },
    Upgrade {
        phase: UpgradePhase,
        progress: Option<f64>,
        message: Option<String>,
    },
    #[serde(other)]
    Unknown,
}
