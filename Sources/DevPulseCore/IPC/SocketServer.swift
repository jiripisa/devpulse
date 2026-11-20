import Foundation
import os

public enum SocketServerError: Error, LocalizedError, Equatable {
    case pathTooLong(path: String, maxBytes: Int)
    case system(operation: String, errno: Int32)
    case alreadyRunning(path: String)
    case alreadyStarted

    public var errorDescription: String? {
        switch self {
        case .pathTooLong(let path, let maxBytes):
            return "Socket path is too long (limit \(maxBytes) bytes): \(path)"
        case .system(let operation, let code):
            return "\(operation) failed: \(String(cString: strerror(code)))"
        case .alreadyRunning(let path):
            return "Another instance is already listening on \(path)"
        case .alreadyStarted:
            return "The server is already started"
        }
    }
}

/// Local Unix-domain socket server speaking newline-delimited JSON (see `ClientMessage` /
/// `ServerMessage`). All state lives on one serial queue. Client sockets are non-blocking; a
/// client whose write cannot complete immediately (or fails) is dropped. At most
/// `maxClients` clients are served; further connections are closed right after accept.
///
/// `onMessage` is called on the server's private serial queue: callers hop to their own actor
/// there, and must never call `start` / `stop` from it (both preconditions against that).
public final class SocketServer: @unchecked Sendable {
    /// `~/Library/Application Support/DevPulse/devpulse.sock`
    public static var defaultPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DevPulse/devpulse.sock").path
    }

    private struct Client {
        let fd: Int32
        let source: DispatchSourceRead
        var buffer = Data()
    }

    /// A client sending more than this without a newline is misbehaving.
    private static let maxLineBytes = 1 << 20

    private static let maxClients = 16

    private let path: String
    private let queue = DispatchQueue(label: "io.jp4.devpulse.ipc")
    private let log = Logger(subsystem: "io.jp4.devpulse", category: "ipc")

    // Everything below is touched only on `queue`.
    private var started = false
    private var acceptSuspended = false
    private var acceptSource: DispatchSourceRead?
    private var clients: [ClientID: Client] = [:]
    private var nextClientID = 1
    private var lastSnapshotLine: Data?
    private var onMessage: (@Sendable (ClientMessage, ClientID) -> Void)?

    public init(path: String) {
        self.path = path
    }

    public func start(onMessage: @escaping @Sendable (ClientMessage, ClientID) -> Void) throws {
        dispatchPrecondition(condition: .notOnQueue(queue))
        try queue.sync { try startLocked(onMessage: onMessage) }
    }

    public func broadcast(_ msg: ServerMessage) {
        guard let line = encode(msg) else { return }
        queue.async { [self] in
            if case .snapshot = msg { lastSnapshotLine = line }
            for id in Array(clients.keys) { write(line, to: id) }
        }
    }

    public func send(_ msg: ServerMessage, to id: ClientID) {
        guard let line = encode(msg) else { return }
        queue.async { [self] in write(line, to: id) }
    }

    public func stop() {
        dispatchPrecondition(condition: .notOnQueue(queue))
        queue.sync {
            guard started else { return }
            started = false
            if acceptSuspended {
                acceptSource?.resume()  // a suspended source must be resumed before it is cancelled
                acceptSuspended = false
            }
            acceptSource?.cancel()
            acceptSource = nil
            for id in Array(clients.keys) { drop(id) }
            onMessage = nil
            lastSnapshotLine = nil
            unlink(path)
        }
    }

    // MARK: Setup

    private func startLocked(onMessage: @escaping @Sendable (ClientMessage, ClientID) -> Void) throws {
        guard !started else { throw SocketServerError.alreadyStarted }
        var addr = sockaddr_un()
        let maxBytes = MemoryLayout.size(ofValue: addr.sun_path) - 1
        let pathBytes = Array(path.utf8)
        guard pathBytes.count <= maxBytes else {
            throw SocketServerError.pathTooLong(path: path, maxBytes: maxBytes)
        }
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: pathBytes) }

        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        // A file left by a crashed run would make bind fail with EADDRINUSE, but a live
        // listener must not be stolen: probe first.
        try removeStaleSocket(addr: &addr)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketServerError.system(operation: "socket", errno: errno) }

        setCloseOnExec(fd)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw SocketServerError.system(operation: "bind", errno: code)
        }
        // The parent directory is 0700 as well, so no one can connect before this lands.
        guard chmod(path, 0o600) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw SocketServerError.system(operation: "chmod", errno: code)
        }

        // The backlog exceeds the client cap: a burst of connections must reach accept (and be
        // closed there when over the cap) instead of being refused by the kernel.
        guard listen(fd, Int32(Self.maxClients * 2)) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw SocketServerError.system(operation: "listen", errno: code)
        }
        setNonBlocking(fd)

        started = true
        self.onMessage = onMessage
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [self] in acceptPending(on: fd) }
        source.setCancelHandler { close(fd) }
        acceptSource = source
        source.resume()
    }

    // MARK: Accepting and reading

    private func acceptPending(on fd: Int32) {
        while true {
            let clientFD = accept(fd, nil, nil)
            if clientFD < 0 {
                switch errno {
                case EAGAIN, EWOULDBLOCK:
                    return  // nothing more to accept
                case EINTR, ECONNABORTED:
                    continue
                default:
                    // E.g. EMFILE: the pending connection keeps the level-triggered source
                    // firing, so pause accepting and retry in a second.
                    log.error("accept failed: \(String(cString: strerror(errno)), privacy: .public)")
                    pauseAccepting()
                    return
                }
            }
            guard clients.count < Self.maxClients else {
                log.error("Too many clients; refusing a connection")
                close(clientFD)
                continue
            }
            setNonBlocking(clientFD)
            setCloseOnExec(clientFD)
            var one: Int32 = 1
            if setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) != 0 {
                // EINVAL: the peer hung up before the accept (e.g. a client probing whether the
                // app runs). Writing to it unguarded would raise SIGPIPE and kill the app.
                let reason = String(cString: strerror(errno))
                log.info("Dropping a client gone before accept: \(reason, privacy: .public)")
                close(clientFD)
                continue
            }
            // Room for a whole snapshot, so a healthy client is never dropped for a large write.
            var sendBuffer: Int32 = 1 << 20
            if setsockopt(clientFD, SOL_SOCKET, SO_SNDBUF, &sendBuffer, socklen_t(MemoryLayout<Int32>.size)) != 0 {
                log.error("SO_SNDBUF failed: \(String(cString: strerror(errno)), privacy: .public)")
            }

            let id = ClientID(rawValue: nextClientID)
            nextClientID += 1
            let source = DispatchSource.makeReadSource(fileDescriptor: clientFD, queue: queue)
            source.setEventHandler { [self] in readAvailable(from: id) }
            source.setCancelHandler { close(clientFD) }
            clients[id] = Client(fd: clientFD, source: source)
            source.resume()

            if let line = lastSnapshotLine { write(line, to: id) }
        }
    }

    private func pauseAccepting() {
        guard let source = acceptSource, !acceptSuspended else { return }
        acceptSuspended = true
        source.suspend()
        queue.asyncAfter(deadline: .now() + 1) { [self] in
            guard acceptSuspended, let source = acceptSource else { return }
            acceptSuspended = false
            source.resume()
        }
    }

    private func removeStaleSocket(addr: inout sockaddr_un) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { throw SocketServerError.system(operation: "socket", errno: errno) }
        defer { close(probe) }
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 { throw SocketServerError.alreadyRunning(path: path) }
        // ECONNREFUSED / ENOENT / ENOTSOCK etc.: nobody is listening, the file is stale.
        unlink(path)
    }

    private func readAvailable(from id: ClientID) {
        guard let client = clients[id] else { return }
        var chunk = [UInt8](repeating: 0, count: 16384)
        let count = read(client.fd, &chunk, chunk.count)
        if count == 0 { return drop(id) }
        if count < 0 {
            if errno == EAGAIN || errno == EINTR { return }
            return drop(id)
        }
        clients[id]?.buffer.append(contentsOf: chunk[0..<count])

        while let buffer = clients[id]?.buffer, let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            clients[id]?.buffer.removeSubrange(buffer.startIndex...newline)
            handle(line: line, from: id)
        }
        if let size = clients[id]?.buffer.count, size > Self.maxLineBytes {
            log.error("Client \(id.rawValue) sent an oversized line; dropping")
            drop(id)
        }
    }

    private func handle(line: Data, from id: ClientID) {
        guard !line.isEmpty else { return }
        do {
            let message = try JSONDecoder().decode(ClientMessage.self, from: line)
            onMessage?(message, id)
        } catch {
            log.error("Ignoring undecodable client message: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Writing

    private func encode(_ msg: ServerMessage) -> Data? {
        do {
            return try msg.line()
        } catch {
            log.error("Could not encode server message: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Writes everything or drops the client (EAGAIN means it is not keeping up).
    private func write(_ data: Data, to id: ClientID) {
        guard let client = clients[id] else { return }
        let ok = data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(client.fd, raw.baseAddress! + offset, raw.count - offset)
                if n > 0 {
                    offset += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
        if !ok { drop(id) }
    }

    private func drop(_ id: ClientID) {
        guard let client = clients.removeValue(forKey: id) else { return }
        client.source.cancel()  // the cancel handler closes the fd
    }

    private func setCloseOnExec(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFD)
        _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC)
    }

    private func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }
}
