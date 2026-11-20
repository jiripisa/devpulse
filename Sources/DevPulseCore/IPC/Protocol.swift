import Foundation

/// Version of the newline-delimited JSON protocol spoken over the local socket.
public let ipcProtocolVersion = 1

/// What `open` refers to; the `id` in the message is the PR id, ticket key or session pid.
public enum OpenKind: String, Codable, Sendable, Equatable {
    case pr, ticket, session, jiraForPr
}

/// Phases of an in-app upgrade, reported to the terminal client.
public enum UpgradePhase: String, Codable, Sendable, Equatable {
    case checking, downloading, installing, restarting, upToDate, failed
}

/// Identifies one connected socket client.
public struct ClientID: Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }
}

/// Client → server. An unknown `type` fails to decode; the server logs it and keeps the connection.
public enum ClientMessage: Decodable, Sendable, Equatable {
    case hello(protocol: Int)
    case refresh
    case openSettings
    case upgrade
    case open(kind: OpenKind, id: String)

    private enum CodingKeys: String, CodingKey {
        case type, `protocol`, kind, id
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "hello":
            self = .hello(protocol: try container.decode(Int.self, forKey: .protocol))
        case "refresh":
            self = .refresh
        case "openSettings":
            self = .openSettings
        case "upgrade":
            self = .upgrade
        case "open":
            self = .open(
                kind: try container.decode(OpenKind.self, forKey: .kind),
                id: try container.decode(String.self, forKey: .id))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "Unknown message type \(type)")
        }
    }
}

/// Server → client.
public enum ServerMessage: Encodable, Sendable {
    case snapshot(Snapshot)
    case upgrade(phase: UpgradePhase, progress: Double?, message: String?)

    private enum CodingKeys: String, CodingKey {
        case type, `protocol`, data, phase, progress, message
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .snapshot(let snapshot):
            try container.encode("snapshot", forKey: .type)
            try container.encode(ipcProtocolVersion, forKey: .protocol)
            try container.encode(snapshot, forKey: .data)
        case .upgrade(let phase, let progress, let message):
            try container.encode("upgrade", forKey: .type)
            try container.encode(phase, forKey: .phase)
            try container.encodeIfPresent(progress, forKey: .progress)
            try container.encodeIfPresent(message, forKey: .message)
        }
    }

    /// The wire form: exactly one line of JSON ending in `\n`. This is the only supported
    /// encoding path (the `Encodable` conformance alone would not use ISO 8601 dates).
    public func line() throws -> Data {
        var data: Data
        switch self {
        case .snapshot(let snapshot):
            // Hand-assembled so `type` comes first, as in the documented message.
            data = Data(#"{"type":"snapshot","protocol":\#(ipcProtocolVersion),"data":"#.utf8)
            data.append(try Snapshot.encoder.encode(snapshot))
            data.append(UInt8(ascii: "}"))
        case .upgrade:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            data = try encoder.encode(self)
        }
        data.append(UInt8(ascii: "\n"))
        return data
    }
}
