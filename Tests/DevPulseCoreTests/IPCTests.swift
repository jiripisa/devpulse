import Foundation
import Testing
@testable import DevPulseCore

/// A blocking test client over a real Unix socket.
private final class TestClient: @unchecked Sendable {
    private(set) var fd: Int32
    private var buffer = Data()

    init(path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let bytes = Array(path.utf8) + [0]
            raw.copyBytes(from: bytes)
        }
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            let code = errno
            // `self` is fully initialized, so `deinit` runs after the throw: mark the fd closed,
            // or it would close the same number again, by then another test's socket.
            close(fd)
            fd = -1
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    deinit { if fd >= 0 { close(fd) } }

    func send(_ text: String) {
        let bytes = Array(text.utf8)
        _ = write(fd, bytes, bytes.count)
    }

    /// True when the peer has closed the connection (EOF within the timeout).
    func sawEOF(timeoutMs: Int32 = 2000) -> Bool {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, timeoutMs) > 0 else { return false }
        var byte: UInt8 = 0
        return read(fd, &byte, 1) == 0
    }

    /// Reads one line (without the newline); nil on timeout or EOF.
    func readLine(timeoutMs: Int32 = 2000) -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                return line
            }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, timeoutMs) > 0 else { return nil }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return nil }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }
}

/// Collects messages delivered to the server callback.
private final class Inbox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(ClientMessage, ClientID)] = []

    func add(_ message: ClientMessage, _ id: ClientID) {
        lock.lock(); defer { lock.unlock() }
        items.append((message, id))
    }

    var messages: [ClientMessage] {
        lock.lock(); defer { lock.unlock() }
        return items.map(\.0)
    }

    func wait(count: Int, timeout: TimeInterval = 2) async -> [ClientMessage] {
        let deadline = Date().addingTimeInterval(timeout)
        while messages.count < count, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return messages
    }
}

private func shortSocketPath() -> String {
    "/tmp/dp-\(UUID().uuidString.prefix(8)).sock"
}

@Suite("IPC")
struct IPCTests {

    private static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("protocol/fixtures/snapshot-v1.json")

    private static func loadFixture() throws -> Snapshot {
        try Snapshot.decoder.decode(Snapshot.self, from: Data(contentsOf: fixtureURL))
    }

    // MARK: Encoding / decoding

    @Test("Snapshot message is exactly one line with the documented envelope")
    func snapshotEncoding() throws {
        let snapshot = try Self.loadFixture()
        let data = try ServerMessage.snapshot(snapshot).line()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasPrefix(#"{"type":"snapshot","protocol":1,"data":{"#))
        #expect(text.hasSuffix("}\n"))
        #expect(text.dropLast().contains("\n") == false)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["protocol"] as? Int == 1)
        let inner = try JSONSerialization.data(withJSONObject: try #require(object["data"]))
        #expect(try Snapshot.decoder.decode(Snapshot.self, from: inner) == snapshot)
    }

    @Test("Upgrade message encodes phase, progress and message")
    func upgradeEncoding() throws {
        let data = try ServerMessage.upgrade(phase: .downloading, progress: 0.5, message: nil).line()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["type"] as? String == "upgrade")
        #expect(object["phase"] as? String == "downloading")
        #expect(object["progress"] as? Double == 0.5)
        #expect(object["message"] == nil)
        #expect(String(decoding: data, as: UTF8.self).hasSuffix("\n"))
    }

    @Test("Every upgrade phase has its wire name", arguments: [
        (UpgradePhase.checking, "checking"),
        (.downloading, "downloading"),
        (.installing, "installing"),
        (.restarting, "restarting"),
        (.upToDate, "upToDate"),
        (.failed, "failed"),
    ])
    func upgradePhaseNames(phase: UpgradePhase, wireName: String) throws {
        let data = try ServerMessage.upgrade(phase: phase, progress: nil, message: nil).line()
        #expect(String(decoding: data, as: UTF8.self)
            == #"{"phase":"\#(wireName)","type":"upgrade"}"# + "\n")
    }

    @Test("A failed upgrade carries its message and leaves out the progress")
    func failedUpgradeEncoding() throws {
        let message = "An update is already in progress in DevPulse."
        let data = try ServerMessage.upgrade(phase: .failed, progress: nil, message: message).line()
        #expect(String(decoding: data, as: UTF8.self)
            == #"{"message":"\#(message)","phase":"failed","type":"upgrade"}"# + "\n")
    }

    @Test("Every client message shape decodes")
    func clientDecoding() throws {
        func decode(_ json: String) throws -> ClientMessage {
            try JSONDecoder().decode(ClientMessage.self, from: Data(json.utf8))
        }
        #expect(try decode(#"{"type":"hello","protocol":1}"#) == .hello(protocol: 1))
        #expect(try decode(#"{"type":"refresh"}"#) == .refresh)
        #expect(try decode(#"{"type":"openSettings"}"#) == .openSettings)
        #expect(try decode(#"{"type":"upgrade"}"#) == .upgrade)
        #expect(try decode(#"{"type":"open","kind":"jiraForPr","id":"PR_1"}"#)
            == .open(kind: .jiraForPr, id: "PR_1"))
        #expect(try decode(#"{"type":"open","kind":"session","id":"4242"}"#)
            == .open(kind: .session, id: "4242"))
    }

    @Test("Unknown type throws a decoding error")
    func unknownType() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ClientMessage.self, from: Data(#"{"type":"bogus"}"#.utf8))
        }
    }

    // MARK: Server over a real socket

    @Test("A connecting client receives the snapshot first; refresh reaches onMessage")
    func integration() async throws {
        let path = shortSocketPath()
        defer { unlink(path) }
        let server = SocketServer(path: path)
        let inbox = Inbox()
        try server.start { inbox.add($0, $1) }
        defer { server.stop() }

        let snapshot = try Self.loadFixture()
        server.broadcast(.snapshot(snapshot))

        let client = try TestClient(path: path)
        let line = try #require(client.readLine())
        let object = try #require(JSONSerialization.jsonObject(with: line) as? [String: Any])
        #expect(object["type"] as? String == "snapshot")

        client.send("{\"type\":\"refresh\"}\n")
        let received = await inbox.wait(count: 1)
        #expect(received == [.refresh])
    }

    @Test("Broadcast reaches all clients; unknown messages are ignored and the connection stays")
    func broadcastAndUnknown() async throws {
        let path = shortSocketPath()
        defer { unlink(path) }
        let server = SocketServer(path: path)
        let inbox = Inbox()
        try server.start { inbox.add($0, $1) }
        defer { server.stop() }

        let a = try TestClient(path: path)
        let b = try TestClient(path: path)
        a.send("{\"type\":\"bogus\"}\nnot json\n{\"type\":\"hello\",\"protocol\":1}\n")
        let received = await inbox.wait(count: 1)
        #expect(received == [.hello(protocol: 1)])

        server.broadcast(.upgrade(phase: .checking, progress: nil, message: nil))
        for client in [a, b] {
            let line = try #require(client.readLine())
            let object = try #require(JSONSerialization.jsonObject(with: line) as? [String: Any])
            #expect(object["phase"] as? String == "checking")
        }
    }

    @Test("send(to:) targets one client")
    func sendToClient() async throws {
        let path = shortSocketPath()
        defer { unlink(path) }
        let server = SocketServer(path: path)
        let ids = IDBox()
        let inbox = Inbox()
        try server.start { message, id in
            ids.set(id)
            inbox.add(message, id)
        }
        defer { server.stop() }

        let a = try TestClient(path: path)
        let b = try TestClient(path: path)
        a.send("{\"type\":\"refresh\"}\n")
        _ = await inbox.wait(count: 1)
        server.send(.upgrade(phase: .failed, progress: nil, message: "boom"), to: try #require(ids.value))
        let line = try #require(a.readLine())
        #expect(String(decoding: line, as: UTF8.self).contains("boom"))
        #expect(b.readLine(timeoutMs: 200) == nil)
    }

    @Test("A stale socket file is removed on start")
    func staleSocket() throws {
        let path = shortSocketPath()
        defer { unlink(path) }
        // Simulate a crash: bind a socket and close it, leaving the file behind.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        close(fd)
        #expect(bound == 0)
        #expect(FileManager.default.fileExists(atPath: path))

        let server = SocketServer(path: path)
        try server.start { _, _ in }
        defer { server.stop() }
        _ = try TestClient(path: path)
    }

    @Test("Socket file mode is 0600")
    func permissions() throws {
        let path = shortSocketPath()
        defer { unlink(path) }
        let server = SocketServer(path: path)
        try server.start { _, _ in }
        defer { server.stop() }
        var info = stat()
        #expect(stat(path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
    }

    @Test("A too-long path fails with a clear error")
    func pathTooLong() {
        let server = SocketServer(path: "/tmp/" + String(repeating: "x", count: 120) + ".sock")
        #expect(throws: SocketServerError.self) {
            try server.start { _, _ in }
        }
    }

    @Test("Clients over the cap of 16 are closed")
    func clientCap() throws {
        let path = shortSocketPath()
        defer { unlink(path) }
        let server = SocketServer(path: path)
        try server.start { _, _ in }
        defer { server.stop() }

        let accepted = try (0..<16).map { _ in try TestClient(path: path) }
        let extra = try TestClient(path: path)
        #expect(extra.sawEOF())
        #expect(accepted[0].sawEOF(timeoutMs: 100) == false)
    }

    @Test("A snapshot over 64 KB reaches a client that reads only afterwards")
    func largeSnapshot() async throws {
        let path = shortSocketPath()
        defer { unlink(path) }
        let server = SocketServer(path: path)
        try server.start { _, _ in }
        defer { server.stop() }

        var snapshot = try Self.loadFixture()
        let template = try #require(snapshot.myPullRequests.first)
        snapshot.myPullRequests = (0..<400).map { index in
            var pr = template
            pr.id = "PR_\(index)"
            return pr
        }
        let client = try TestClient(path: path)
        try await Task.sleep(for: .milliseconds(50))  // let the server accept it
        server.broadcast(.snapshot(snapshot))
        try await Task.sleep(for: .milliseconds(200))  // client reads only now

        let line = try #require(client.readLine())
        #expect(line.count > 65536)
        let object = try #require(JSONSerialization.jsonObject(with: line) as? [String: Any])
        let data = try #require(object["data"] as? [String: Any])
        #expect((data["myPullRequests"] as? [Any])?.count == 400)
    }

    @Test("A client closing abruptly does not hurt the server")
    func abruptClose() async throws {
        let path = shortSocketPath()
        defer { unlink(path) }
        let server = SocketServer(path: path)
        try server.start { _, _ in }
        defer { server.stop() }
        let snapshot = try Self.loadFixture()

        do {
            let doomed = try TestClient(path: path)
            doomed.send("{\"type\":\"refresh\"}\n")
        }  // closed here
        try await Task.sleep(for: .milliseconds(50))
        server.broadcast(.snapshot(snapshot))
        server.broadcast(.snapshot(snapshot))

        let fresh = try TestClient(path: path)
        #expect(fresh.readLine() != nil)
    }

    @Test("Clients that hang up before they are accepted do not take the server down")
    func hangUpBeforeAccept() async throws {
        let path = shortSocketPath()
        defer { unlink(path) }
        let server = SocketServer(path: path)
        try server.start { _, _ in }
        defer { server.stop() }
        // Accepting writes the last snapshot at once: to a peer already gone, an unguarded
        // write raises SIGPIPE and kills the process (as `devpulse`'s "is the app up?" probe did).
        server.broadcast(.snapshot(try Self.loadFixture()))

        for _ in 0..<200 {
            _ = try? TestClient(path: path)  // connect and close right away
        }
        try await Task.sleep(for: .milliseconds(100))

        let fresh = try TestClient(path: path)
        #expect(fresh.readLine() != nil)
    }

    @Test("A second server on a live socket throws alreadyRunning and leaves it intact")
    func alreadyRunning() throws {
        let path = shortSocketPath()
        defer { unlink(path) }
        let first = SocketServer(path: path)
        try first.start { _, _ in }
        defer { first.stop() }

        let second = SocketServer(path: path)
        #expect(throws: SocketServerError.alreadyRunning(path: path)) {
            try second.start { _, _ in }
        }
        second.stop()  // must not unlink the first server's file
        _ = try TestClient(path: path)
    }

    @Test("start twice without stop throws")
    func startTwice() throws {
        let path = shortSocketPath()
        defer { unlink(path) }
        let server = SocketServer(path: path)
        try server.start { _, _ in }
        defer { server.stop() }
        #expect(throws: SocketServerError.alreadyStarted) {
            try server.start { _, _ in }
        }
    }

    @Test("stop removes the socket file")
    func stopCleansUp() throws {
        let path = shortSocketPath()
        let server = SocketServer(path: path)
        try server.start { _, _ in }
        server.stop()
        #expect(FileManager.default.fileExists(atPath: path) == false)
    }
}

private final class IDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var id: ClientID?
    func set(_ id: ClientID) { lock.lock(); self.id = id; lock.unlock() }
    var value: ClientID? { lock.lock(); defer { lock.unlock() }; return id }
}
