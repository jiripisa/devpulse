import Foundation

/// Reads one `~/.claude/sessions/<pid>.json` file written by Claude Code.
public enum SessionFileParser {

    /// What one session file holds.
    public enum Content: Equatable, Sendable {
        case session(ClaudeSession)
        /// A complete file of a session that is not interactive (`kind` other than
        /// `interactive`, e.g. an SDK run): not shown.
        case notInteractive
        /// Not a complete session file, for example truncated while Claude Code writes it.
        case incomplete
    }

    private struct File: Decodable {
        var pid: Int
        var name: String?
        var cwd: String?
        var status: SessionStatus?
        var waitingFor: String?
        var kind: String?
        /// Epoch milliseconds.
        var updatedAt: Double?
        var statusUpdatedAt: Double?
    }

    /// The interactive session in `data`, or `nil` for anything else (see `read`).
    public static func parse(_ data: Data) -> ClaudeSession? {
        if case .session(let session) = read(data) { session } else { nil }
    }

    /// Unknown fields are ignored; a missing `status` becomes `.unknown`, and a missing `kind`
    /// counts as interactive.
    public static func read(_ data: Data) -> Content {
        guard let file = try? JSONDecoder().decode(File.self, from: data) else { return .incomplete }
        if let kind = file.kind, kind != "interactive" { return .notInteractive }
        let cwd = file.cwd ?? ""
        let milliseconds = file.statusUpdatedAt ?? file.updatedAt ?? 0
        // `URL(filePath: "")` would resolve to the process's own directory.
        let directory = cwd.isEmpty ? "" : URL(filePath: cwd).lastPathComponent
        return .session(ClaudeSession(
            pid: file.pid,
            name: file.name ?? directory,
            cwd: cwd,
            status: file.status ?? .unknown,
            waitingFor: file.waitingFor,
            jiraKey: directory.isEmpty ? nil : JiraKey.find(in: directory),
            updatedAt: Date(timeIntervalSince1970: milliseconds / 1000)
        ))
    }
}
