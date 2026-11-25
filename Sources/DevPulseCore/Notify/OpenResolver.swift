import Foundation

/// Turns an `open` request from a socket client (kind + id) into something the app can open.
public enum OpenResolver {
    /// The `id` is the PR's node id (`pr`, `jiraForPr`), the ticket key or the session pid.
    /// Nil when the snapshot does not know it, or a PR has no linked ticket.
    public static func target(for kind: OpenKind, id: String, in snapshot: Snapshot) -> OpenTarget? {
        switch kind {
        case .pr:
            return pullRequest(id, in: snapshot).flatMap { URL(string: $0.url) }.map { .url($0) }
        case .jiraForPr:
            guard let key = pullRequest(id, in: snapshot)?.jiraKey,
                  let base = snapshot.jiraBaseURL.flatMap({ URL(string: $0) })
            else { return nil }
            return .url(base.appending(path: "browse/\(key)"))
        case .ticket:
            if let ticket = (snapshot.tickets + snapshot.createdTickets).first(where: { $0.key == id }) {
                return URL(string: ticket.url).map { .url($0) }
            }
            // Not one of my tickets (e.g. a Claude session's key): open it by key on the site.
            guard JiraKey.find(in: id) == id,
                  let base = snapshot.jiraBaseURL.flatMap({ URL(string: $0) })
            else { return nil }
            return .url(base.appending(path: "browse/\(id)"))
        case .session:
            guard let pid = Int(id), snapshot.sessions.contains(where: { $0.pid == pid }) else { return nil }
            return .session(pid: pid)
        }
    }

    private static func pullRequest(_ id: String, in snapshot: Snapshot) -> PullRequest? {
        snapshot.myPullRequests.first { $0.id == id } ?? snapshot.reviewRequests.first { $0.id == id }
    }
}

extension OpenTarget {
    /// The form a notification carries in its `userInfo` (plist types only).
    public var userInfo: [String: String] {
        switch self {
        case .url(let url): ["target": "url", "url": url.absoluteString]
        case .session(let pid): ["target": "session", "pid": String(pid)]
        }
    }

    public init?(userInfo: [AnyHashable: Any]) {
        switch userInfo["target"] as? String {
        case "url":
            guard let url = (userInfo["url"] as? String).flatMap({ URL(string: $0) }) else { return nil }
            self = .url(url)
        case "session":
            guard let pid = (userInfo["pid"] as? String).flatMap({ Int($0) }) else { return nil }
            self = .session(pid: pid)
        default:
            return nil
        }
    }
}
