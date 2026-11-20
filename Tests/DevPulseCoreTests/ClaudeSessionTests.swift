import Foundation
import Testing
@testable import DevPulseCore

private struct FakeInspector: ProcessInspector {
    var alive: Set<Int32>
    func isClaudeProcess(pid: Int32) -> Bool { alive.contains(pid) }
}

private func sessionJSON(
    pid: Int, name: String, status: String?, cwd: String = "/Users/me/STORE-2474", updatedAt: Int = 1_795_108_491_192
) -> String {
    let statusField = status.map { "\"status\":\"\($0)\"," } ?? ""
    return """
    {"pid":\(pid),"sessionId":"abc","cwd":"\(cwd)","startedAt":1795106814759,"kind":"interactive",\
    "name":"\(name)",\(statusField)"updatedAt":\(updatedAt)}
    """
}

private func makeDirectory(_ files: [String: String]) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "devpulse-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (file, content) in files {
        try content.write(to: dir.appending(path: file), atomically: true, encoding: .utf8)
    }
    return dir
}

/// Collects what the source reports; `waitForLatest` fails after `timeout` seconds instead of hanging.
private final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [[ClaudeSession]] = []
    private var latest: [ClaudeSession]? { all.last }

    var history: [[ClaudeSession]] { lock.withLock { all } }

    func record(_ sessions: [ClaudeSession]) {
        lock.withLock { all.append(sessions) }
    }

    func waitForLatest(
        timeout: Double = 5, where matches: ([ClaudeSession]) -> Bool
    ) async -> [ClaudeSession]? {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if let sessions = lock.withLock({ latest }), matches(sessions) { return sessions }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }
}

@Suite struct SessionFileParserTests {
    @Test func parsesRealShapedFile() throws {
        let json = """
        {"pid":11491,"sessionId":"x","cwd":"/Users/me/dev/STORE-2474","startedAt":1795106814759,\
        "procStart":"Thu","version":"2.1.328","kind":"interactive","entrypoint":"cli","name":"b0",\
        "status":"waiting","waitingFor":"permission prompt","updatedAt":1795108491192,\
        "statusUpdatedAt":1795108500000,"future":{"a":1}}
        """
        let session = try #require(SessionFileParser.parse(Data(json.utf8)))
        #expect(session.pid == 11491)
        #expect(session.name == "b0")
        #expect(session.cwd == "/Users/me/dev/STORE-2474")
        #expect(session.status == .waiting)
        #expect(session.waitingFor == "permission prompt")
        #expect(session.jiraKey == "STORE-2474")
        #expect(session.updatedAt == Date(timeIntervalSince1970: 1_795_108_500))
    }

    @Test func fallsBackToUpdatedAt() throws {
        let session = try #require(SessionFileParser.parse(Data(sessionJSON(pid: 1, name: "a", status: "busy").utf8)))
        #expect(session.updatedAt == Date(timeIntervalSince1970: 1_795_108_491.192))
    }

    @Test func truncatedJSONGivesNil() {
        #expect(SessionFileParser.parse(Data(#"{"pid":1,"name":"a","cwd":"/x"#.utf8)) == nil)
    }

    @Test func missingStatusGivesUnknown() throws {
        let session = try #require(SessionFileParser.parse(Data(sessionJSON(pid: 1, name: "a", status: nil).utf8)))
        #expect(session.status == .unknown)
    }

    @Test func missingCwdGivesNoJiraKeyAndFallsBackToName() throws {
        let missing = try #require(SessionFileParser.parse(Data(#"{"pid":1,"name":"n","status":"idle"}"#.utf8)))
        #expect(missing.cwd == "")
        #expect(missing.name == "n")
        #expect(missing.jiraKey == nil)
        let nameless = try #require(SessionFileParser.parse(Data(#"{"pid":1,"cwd":""}"#.utf8)))
        #expect(nameless.name == "")
        #expect(nameless.jiraKey == nil)
    }

    @Test func noJiraKeyInCwd() throws {
        let json = sessionJSON(pid: 1, name: "a", status: "idle", cwd: "/Users/me/devpulse")
        #expect(try #require(SessionFileParser.parse(Data(json.utf8))).jiraKey == nil)
    }

    @Test(arguments: ["sdk", "background", ""])
    func skipsSessionsThatAreNotInteractive(kind: String) {
        let json = #"{"pid":1,"name":"a","cwd":"/x","status":"busy","kind":"\#(kind)"}"#
        #expect(SessionFileParser.read(Data(json.utf8)) == .notInteractive)
        #expect(SessionFileParser.parse(Data(json.utf8)) == nil)
    }

    @Test func aMissingKindStillCounts() throws {
        let json = #"{"pid":1,"name":"a","cwd":"/x","status":"busy"}"#
        #expect(try #require(SessionFileParser.parse(Data(json.utf8))).name == "a")
        #expect(SessionFileParser.read(Data(#"{"pid":1,"cwd":"/x"#.utf8)) == .incomplete)
    }
}

@Suite struct ClaudeSessionSourceTests {
    @Test func skipsDeadProcessesAndSorts() throws {
        let dir = try makeDirectory([
            "1.json": sessionJSON(pid: 1, name: "z-idle", status: "idle"),
            "2.json": sessionJSON(pid: 2, name: "dead", status: "busy"),
            "3.json": sessionJSON(pid: 3, name: "a-busy", status: "busy"),
            "4.json": sessionJSON(pid: 4, name: "w-waiting", status: "waiting"),
            "5.json": sessionJSON(pid: 5, name: "b-unknown", status: "weird"),
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = ClaudeSessionSource(directory: dir, inspector: FakeInspector(alive: [1, 3, 4, 5]))
        #expect(source.currentSessions().map(\.name) == ["w-waiting", "a-busy", "z-idle", "b-unknown"])
    }

    @Test func threeFilesOneDeadGivesTwo() throws {
        let dir = try makeDirectory([
            "1.json": sessionJSON(pid: 1, name: "a", status: "busy"),
            "2.json": sessionJSON(pid: 2, name: "b", status: "idle"),
            "3.json": sessionJSON(pid: 3, name: "c", status: "idle"),
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = ClaudeSessionSource(directory: dir, inspector: FakeInspector(alive: [1, 3]))
        #expect(source.currentSessions().count == 2)
    }

    @Test func ignoresNonJSONAndBrokenFiles() throws {
        let dir = try makeDirectory([
            "1.json": sessionJSON(pid: 1, name: "a", status: "busy"),
            "1.abc123.key": sessionJSON(pid: 1, name: "key", status: "busy"),
            "9.json": "{ truncated",
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = ClaudeSessionSource(directory: dir, inspector: FakeInspector(alive: [1, 9]))
        #expect(source.currentSessions().map(\.name) == ["a"])
    }

    @Test func listsInteractiveSessionsOnly() throws {
        let dir = try makeDirectory([
            "1.json": sessionJSON(pid: 1, name: "a", status: "busy"),
            "2.json": #"{"pid":2,"name":"sdk","cwd":"/x","status":"busy","kind":"sdk"}"#,
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = ClaudeSessionSource(directory: dir, inspector: FakeInspector(alive: [1, 2]))
        #expect(source.currentSessions().map(\.name) == ["a"])
    }

    @Test func missingDirectoryGivesEmpty() {
        let dir = FileManager.default.temporaryDirectory.appending(path: "devpulse-missing-\(UUID().uuidString)")
        #expect(ClaudeSessionSource(directory: dir, inspector: FakeInspector(alive: [])).currentSessions().isEmpty)
    }

    @Test func startReportsInitialAndChangedSessions() async throws {
        let dir = try makeDirectory(["1.json": sessionJSON(pid: 1, name: "a", status: "busy")])
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = ClaudeSessionSource(directory: dir, inspector: FakeInspector(alive: [1, 2]))
        let reports = Reports()
        source.start { reports.record($0) }
        defer { source.stop() }

        #expect(await reports.waitForLatest { $0.count == 1 } != nil)
        try sessionJSON(pid: 2, name: "b", status: "idle")
            .write(to: dir.appending(path: "2.json"), atomically: true, encoding: .utf8)
        #expect(await reports.waitForLatest { $0.count == 2 } != nil)
    }

    @Test func reportsFileRewrittenInPlace() async throws {
        let dir = try makeDirectory(["1.json": sessionJSON(pid: 1, name: "a", status: "busy")])
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = ClaudeSessionSource(directory: dir, inspector: FakeInspector(alive: [1]))
        let reports = Reports()
        source.start { reports.record($0) }
        defer { source.stop() }

        #expect(await reports.waitForLatest { $0.first?.status == .busy } != nil)
        // Same inode, new contents: the directory sees no event.
        let handle = try FileHandle(forWritingTo: dir.appending(path: "1.json"))
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(sessionJSON(pid: 1, name: "a", status: "waiting").utf8))
        try handle.close()
        #expect(await reports.waitForLatest { $0.first?.status == .waiting } != nil)
    }

    @Test func reportsInPlaceRewriteAfterAtomicReplace() async throws {
        let dir = try makeDirectory(["1.json": sessionJSON(pid: 1, name: "a", status: "busy")])
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "1.json")
        let source = ClaudeSessionSource(directory: dir, inspector: FakeInspector(alive: [1]))
        let reports = Reports()
        source.start { reports.record($0) }
        defer { source.stop() }
        #expect(await reports.waitForLatest { $0.first?.status == .busy } != nil)

        try sessionJSON(pid: 1, name: "a", status: "idle").write(to: file, atomically: true, encoding: .utf8)
        #expect(await reports.waitForLatest { $0.first?.status == .idle } != nil)

        // The watcher must now follow the new inode.
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(sessionJSON(pid: 1, name: "a", status: "waiting").utf8))
        try handle.close()
        #expect(await reports.waitForLatest { $0.first?.status == .waiting } != nil)
    }

    @Test func keepsSessionWhileItsFileIsUnreadable() async throws {
        let dir = try makeDirectory(["1.json": sessionJSON(pid: 1, name: "a", status: "busy")])
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "1.json")
        let source = ClaudeSessionSource(directory: dir, inspector: FakeInspector(alive: [1]))
        let reports = Reports()
        source.start { reports.record($0) }
        defer { source.stop() }
        let original = try #require(await reports.waitForLatest { $0.count == 1 })

        // A partial write must not drop the session, and no new report may be made for it.
        try #"{"pid":1,"na"#.write(to: file, atomically: false, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(600))
        #expect(reports.history == [original])

        // The next complete write is reported as usual.
        try sessionJSON(pid: 1, name: "a", status: "waiting").write(to: file, atomically: false, encoding: .utf8)
        #expect(await reports.waitForLatest { $0.first?.status == .waiting } != nil)
    }
}

@Suite struct SystemProcessInspectorTests {
    @Test func rejectsNonClaudeAndMissingProcesses() {
        let inspector = SystemProcessInspector()
        #expect(!inspector.isClaudeProcess(pid: getpid()))
        #expect(!inspector.isClaudeProcess(pid: 0x7FFF_FFF0))
    }
}

@Suite struct ClaudeExecutablePathTests {
    @Test(arguments: [
        ("/Users/me/.local/share/claude/versions/2.1.328", true),
        ("/Users/me/.local/bin/claude", true),
        ("/usr/bin/vim", false),
        ("/Users/me/.local/share/mise/installs/node/25.8.1/bin/node", false),
    ])
    func recognisesClaudeExecutable(path: String, expected: Bool) {
        #expect(SystemProcessInspector.isClaudeExecutable(path: path) == expected)
    }
}
