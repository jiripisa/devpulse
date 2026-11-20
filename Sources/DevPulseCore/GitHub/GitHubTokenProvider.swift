import Foundation
import Synchronization

public enum GitHubError: Error, Equatable {
    case ghMissing, ghTimedOut, notLoggedIn, unauthorized, http(Int), decoding(String), graphQL([String])
}

public protocol GitHubTokenProviding: Sendable {
    /// The GitHub token; `forceRefresh` asks for a new read after the previous one was rejected.
    func token(forceRefresh: Bool) async throws -> String
}

/// Reads the token of the existing `gh` CLI login (`gh auth token`) once and keeps it in memory;
/// only a forced refresh (after a 401) runs `gh` again.
public final class GhCLITokenProvider: GitHubTokenProviding {
    private static let searchDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]

    private let executable: URL?
    private let timeout: TimeInterval
    private let cached = Mutex<String?>(nil)

    /// `executable` overrides the `gh` lookup (tests); `timeout` is the deadline for one `gh` run.
    public init(executable: URL? = nil, timeout: TimeInterval = 8) {
        self.executable = executable
        self.timeout = timeout
    }

    public func token(forceRefresh: Bool) async throws -> String {
        if !forceRefresh, let token = cached.withLock({ $0 }) { return token }
        // A failed read caches nothing, so the next fetch asks `gh` again.
        cached.withLock { $0 = nil }
        guard let gh = executable ?? Self.findGh() else { throw GitHubError.ghMissing }
        let output = try await Self.run(gh, arguments: ["auth", "token"], timeout: timeout)
        guard let token = output, !token.isEmpty else { throw GitHubError.notLoggedIn }
        cached.withLock { $0 = token }
        return token
    }

    static func findGh() -> URL? {
        let pathDirectories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        for directory in searchDirectories + pathDirectories {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("gh")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Trimmed stdout, or `nil` when the command exits non-zero. A run that outlives `timeout`
    /// (e.g. a keychain prompt) is terminated and throws `ghTimedOut`.
    private static func run(_ executable: URL, arguments: [String], timeout: TimeInterval) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            let finished = Mutex(false)
            // Resumes the continuation exactly once, whichever of exit and deadline comes first.
            let finish: @Sendable (Result<String?, GitHubError>) -> Void = { result in
                let first = finished.withLock { done in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(with: result) }
            }
            process.terminationHandler = { process in
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                guard process.terminationStatus == 0 else { return finish(.success(nil)) }
                let text = String(decoding: data, as: UTF8.self)
                finish(.success(text.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            do {
                try process.run()
            } catch {
                return finish(.failure(.ghMissing))
            }
            let running = process
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard running.isRunning else { return }
                finish(.failure(.ghTimedOut))
                running.terminate()
            }
        }
    }
}
