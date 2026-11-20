import Foundation

/// What the change detector has already seen, persisted between launches so a restart
/// does not replay old notifications. Comment keys are prefixed with their source
/// (`github:` / `jira:`) so each source can be pruned on its own.
public struct SeenState: Codable, Sendable, Equatable {
    public var baselined: Set<Source>
    public var reviewRequests: Set<String>
    public var comments: Set<String>
    /// Keys of the form `<prId>@<headOid>:<state>`.
    public var ciNotified: Set<String>
    /// When each source was last fetched successfully; only comments newer than this
    /// (minus a slack) notify, so old discussions of a newly appearing PR/ticket stay quiet.
    public var lastChecked: [Source: Date]

    public init(
        baselined: Set<Source> = [], reviewRequests: Set<String> = [],
        comments: Set<String> = [], ciNotified: Set<String> = [], lastChecked: [Source: Date] = [:]
    ) {
        self.baselined = baselined
        self.reviewRequests = reviewRequests
        self.comments = comments
        self.ciNotified = ciNotified
        self.lastChecked = lastChecked
    }

    // `lastChecked` is missing in files written by older versions.
    private enum CodingKeys: String, CodingKey {
        case baselined, reviewRequests, comments, ciNotified, lastChecked
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            baselined: try c.decode(Set<Source>.self, forKey: .baselined),
            reviewRequests: try c.decode(Set<String>.self, forKey: .reviewRequests),
            comments: try c.decode(Set<String>.self, forKey: .comments),
            ciNotified: try c.decode(Set<String>.self, forKey: .ciNotified),
            lastChecked: try c.decodeIfPresent([Source: Date].self, forKey: .lastChecked) ?? [:])
    }

    /// How often a change of `lastChecked` alone is written to disk.
    public static let lastCheckedSaveInterval: TimeInterval = 600

    /// Whether this state should replace `saved` (what the file holds, written at `savedAt`).
    /// A changed seen set is saved at once; `lastChecked`, which moves on every successful
    /// fetch, at most every `lastCheckedSaveInterval`. Losing a few minutes of it on a crash
    /// only widens the window in which a comment counts as fresh.
    public func needsSaving(comparedTo saved: SeenState, savedAt: Date?, now: Date) -> Bool {
        guard self != saved else { return false }
        var sameTimes = self
        sameTimes.lastChecked = saved.lastChecked
        if sameTimes != saved { return true }
        guard let savedAt else { return true }
        return now.timeIntervalSince(savedAt) >= Self.lastCheckedSaveInterval
    }

    /// `~/Library/Application Support/DevPulse/seen.json`.
    public static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "DevPulse/seen.json", directoryHint: .notDirectory)
    }

    /// An empty state when the file is missing or corrupt.
    public static func load(from url: URL) -> SeenState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(SeenState.self, from: data)
        else { return SeenState() }
        return state
    }

    /// Writes atomically, creating the directory.
    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
