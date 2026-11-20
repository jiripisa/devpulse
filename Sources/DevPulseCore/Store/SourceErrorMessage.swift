import Foundation

/// Short user-facing text for a source failure, shown in `SourceStatus.message`.
public enum SourceErrorMessage {
    public static func text(for error: any Error) -> String {
        switch error {
        case let error as GitHubError:
            switch error {
            case .ghMissing: "GitHub CLI (gh) not found — install it with Homebrew"
            case .notLoggedIn: "Not logged in — run “gh auth login”"
            case .ghTimedOut: "gh did not respond"
            case .unauthorized: "GitHub token rejected"
            case .graphQL(let messages): messages.first ?? "GitHub returned an error"
            case .http(let code): "HTTP \(code)"
            case .decoding: "Unexpected response"
            }
        case let error as JiraError:
            switch error {
            case .unauthorized: "Jira credentials rejected"
            case .http(let code): "HTTP \(code)"
            case .decoding: "Unexpected response"
            }
        case let error as URLError:
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                 .cannotConnectToHost, .dataNotAllowed, .dnsLookupFailed:
                "Offline"
            case .timedOut: "Request timed out"
            default: error.localizedDescription
            }
        default:
            error.localizedDescription
        }
    }
}
