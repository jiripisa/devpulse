import Darwin
import Foundation

/// Tells whether a PID still belongs to a Claude Code process.
public protocol ProcessInspector: Sendable {
    func isClaudeProcess(pid: Int32) -> Bool
}

/// Asks the kernel for the executable path of the PID. The installed `claude` is a symlink
/// into `~/.local/share/claude/versions/<version>`, so the kernel reports a path (and a
/// process name) such as `.../claude/versions/2.1.328`, not `claude`.
public struct SystemProcessInspector: ProcessInspector {
    public init() {}

    public func isClaudeProcess(pid: Int32) -> Bool {
        var path = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &path, UInt32(path.count))
        guard length > 0 else { return false }
        return Self.isClaudeExecutable(path: String(decoding: path.prefix(Int(length)), as: UTF8.self))
    }

    static func isClaudeExecutable(path: String) -> Bool {
        let components = URL(filePath: path).pathComponents
        if components.last == "claude" { return true }
        return components.dropLast().suffix(2) == ["claude", "versions"]
    }
}

/// The running Claude Code sessions, read from `~/.claude/sessions/<pid>.json`.
public final class ClaudeSessionSource: @unchecked Sendable {
    private static let debounce: DispatchTimeInterval = .milliseconds(150)
    private static let livenessInterval: DispatchTimeInterval = .seconds(30)
    /// The liveness check is no hurry; the leeway lets the system batch its wakes.
    private static let livenessLeeway: DispatchTimeInterval = .seconds(5)

    private let directory: URL
    private let inspector: any ProcessInspector
    private let queue = DispatchQueue(label: "io.jp4.devpulse.claude-sessions")

    // Everything below is touched only on `queue`.
    private var directoryWatcher: DispatchSourceFileSystemObject?
    private var fileWatchers: [URL: DispatchSourceFileSystemObject] = [:]
    private var onChange: (@Sendable ([ClaudeSession]) -> Void)?
    private var livenessTimer: DispatchSourceTimer?
    private var pendingRefresh: DispatchWorkItem?
    private var lastSent: [ClaudeSession]?
    private var lastParsed: [URL: ClaudeSession] = [:]

    public init(
        directory: URL = URL.homeDirectory.appending(path: ".claude/sessions"),
        inspector: any ProcessInspector = SystemProcessInspector()
    ) {
        self.directory = directory
        self.inspector = inspector
    }

    /// Sessions whose process is alive, waiting first, then busy, idle, unknown; by name within a status.
    public func currentSessions() -> [ClaudeSession] {
        load(keeping: [:]).sessions
    }

    /// Reads the session files. A file that exists but does not parse (Claude Code is rewriting
    /// it) keeps its entry from `previous`, so the session does not vanish and reappear.
    private func load(keeping previous: [URL: ClaudeSession]) -> (sessions: [ClaudeSession], parsed: [URL: ClaudeSession]) {
        var parsed: [URL: ClaudeSession] = [:]
        for file in sessionFiles() {
            guard let data = try? Data(contentsOf: file) else { continue }
            switch SessionFileParser.read(data) {
            case .session(let session): parsed[file] = session
            case .notInteractive: break
            case .incomplete: parsed[file] = previous[file]
            }
        }
        let sessions = parsed.values
            .filter { Int32(exactly: $0.pid).map(inspector.isClaudeProcess) ?? false }
            .sorted { ($0.status.sortRank, $0.name) < ($1.status.sortRank, $1.name) }
        return (sessions, parsed)
    }

    /// Reports the sessions now and after every change, until `stop()`. Calls come from a
    /// private queue and only when the list differs from the last one reported.
    public func start(onChange: @escaping @Sendable ([ClaudeSession]) -> Void) {
        queue.async { [self] in
            stopOnQueue()
            lastSent = nil
            lastParsed = [:]
            self.onChange = onChange

            // New and removed session files.
            let descriptor = open(directory.path(percentEncoded: false), O_EVTONLY)
            if descriptor >= 0 {
                directoryWatcher = makeWatcher(descriptor: descriptor, mask: .write)
            }

            // Catches sessions that crashed and left their file behind.
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(
                deadline: .now() + Self.livenessInterval, repeating: Self.livenessInterval,
                leeway: Self.livenessLeeway)
            timer.setEventHandler { [self] in refresh() }
            timer.resume()
            livenessTimer = timer

            refresh()
        }
    }

    public func stop() {
        queue.async { [self] in stopOnQueue() }
    }

    /// A vnode source on `queue` that schedules a debounced refresh; the caller stores it.
    /// `file` is the session file a watcher follows; its source is dropped when the inode is deleted
    /// or renamed over, so the next refresh re-opens it on the new inode.
    private func makeWatcher(
        descriptor: Int32, mask: DispatchSource.FileSystemEvent, file: URL? = nil
    ) -> DispatchSourceFileSystemObject {
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: mask, queue: queue)
        source.setEventHandler { [self, unowned source] in
            if let file, !source.data.isDisjoint(with: [.delete, .rename]) {
                source.cancel()
                if fileWatchers[file] === source { fileWatchers[file] = nil }
            }
            pendingRefresh?.cancel()
            let work = DispatchWorkItem { [self] in refresh() }
            pendingRefresh = work
            queue.asyncAfter(deadline: .now() + Self.debounce, execute: work)
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    /// Keeps one watcher per session file (a directory watcher does not see a file rewritten
    /// in place), then reports the sessions when they changed.
    private func refresh() {
        guard let onChange else { return }
        let files = Set(sessionFiles())
        for (file, watcher) in fileWatchers where !files.contains(file) {
            watcher.cancel()
            fileWatchers[file] = nil
        }
        for file in files where fileWatchers[file] == nil {
            let descriptor = open(file.path(percentEncoded: false), O_EVTONLY)
            if descriptor >= 0 {
                fileWatchers[file] = makeWatcher(descriptor: descriptor, mask: [.write, .extend, .delete, .rename], file: file)
            }
        }
        let (sessions, parsed) = load(keeping: lastParsed)
        lastParsed = parsed
        guard sessions != lastSent else { return }
        lastSent = sessions
        onChange(sessions)
    }

    private func stopOnQueue() {
        pendingRefresh?.cancel()
        pendingRefresh = nil
        directoryWatcher?.cancel()
        directoryWatcher = nil
        fileWatchers.values.forEach { $0.cancel() }
        fileWatchers = [:]
        livenessTimer?.cancel()
        livenessTimer = nil
        onChange = nil
    }

    private func sessionFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
    }
}

private extension SessionStatus {
    var sortRank: Int {
        switch self {
        case .waiting: 0
        case .busy: 1
        case .idle: 2
        case .unknown: 3
        }
    }
}
