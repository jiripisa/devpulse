import Foundation

public enum Source: String, Codable, Sendable, CaseIterable {
    case github, jira, claude
}

public enum NotificationTrigger: String, Codable, Sendable, CaseIterable {
    case directReviewRequest, teamReviewRequest
    case prHumanComment, prCopilotComment, prBotComment, ciFinished
    case jiraHumanComment, jiraAutomationComment
    case claudeWaiting, claudeFinished

    public var source: Source {
        switch self {
        case .directReviewRequest, .teamReviewRequest, .prHumanComment, .prCopilotComment, .prBotComment, .ciFinished:
            .github
        case .jiraHumanComment, .jiraAutomationComment:
            .jira
        case .claudeWaiting, .claudeFinished:
            .claude
        }
    }

    /// The defaults of spec §2.2.
    public var defaultEnabled: Bool {
        switch self {
        case .teamReviewRequest, .prBotComment, .jiraAutomationComment: false
        default: true
        }
    }
}

/// Modifier keys of the global hotkey, independent of AppKit/Carbon.
public struct HotkeyModifiers: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = HotkeyModifiers(rawValue: 1 << 0)
    public static let option = HotkeyModifiers(rawValue: 1 << 1)
    public static let control = HotkeyModifiers(rawValue: 1 << 2)
    public static let shift = HotkeyModifiers(rawValue: 1 << 3)
}

public struct Hotkey: Codable, Sendable, Equatable {
    /// Virtual key code (49 = space).
    public var keyCode: Int
    public var modifiers: HotkeyModifiers

    public init(keyCode: Int, modifiers: HotkeyModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

public struct AppSettings: Codable, Sendable, Equatable {
    public static let intervalRange: ClosedRange<TimeInterval> = 60...1800
    private static let defaultsKey = "devpulse.settings"

    /// Seconds between fetches; always within `intervalRange`.
    public var refreshInterval: TimeInterval {
        didSet { refreshInterval = Self.clamp(refreshInterval) }
    }
    /// Whether a source is fetched and shown at all.
    public var sourceEnabled: [Source: Bool]
    /// The master switch of a source's notifications (Settings › Notifications); off keeps the
    /// source fetched and shown, it only stops posting.
    public var notificationsEnabled: [Source: Bool]
    public var triggers: [NotificationTrigger: Bool]
    public var includeTeamReviewRequests: Bool
    public var defaultRepo: String?
    public var defaultJiraProject: String?
    public var jiraSite: URL?
    public var jiraEmail: String?
    public var hotkey: Hotkey
    public var launchAtLogin: Bool

    public init(
        refreshInterval: TimeInterval = 120,
        sourceEnabled: [Source: Bool] = Dictionary(uniqueKeysWithValues: Source.allCases.map { ($0, true) }),
        notificationsEnabled: [Source: Bool] = Dictionary(uniqueKeysWithValues: Source.allCases.map { ($0, true) }),
        triggers: [NotificationTrigger: Bool] = Dictionary(
            uniqueKeysWithValues: NotificationTrigger.allCases.map { ($0, $0.defaultEnabled) }),
        includeTeamReviewRequests: Bool = false,
        defaultRepo: String? = nil,
        defaultJiraProject: String? = nil,
        jiraSite: URL? = nil,
        jiraEmail: String? = nil,
        hotkey: Hotkey = Hotkey(keyCode: 49, modifiers: [.option]),
        launchAtLogin: Bool = true
    ) {
        self.refreshInterval = Self.clamp(refreshInterval)
        self.sourceEnabled = sourceEnabled
        self.notificationsEnabled = notificationsEnabled
        self.triggers = triggers
        self.includeTeamReviewRequests = includeTeamReviewRequests
        self.defaultRepo = defaultRepo
        self.defaultJiraProject = defaultJiraProject
        self.jiraSite = jiraSite
        self.jiraEmail = jiraEmail
        self.hotkey = hotkey
        self.launchAtLogin = launchAtLogin
    }

    private static func clamp(_ interval: TimeInterval) -> TimeInterval {
        min(max(interval, intervalRange.lowerBound), intervalRange.upperBound)
    }

    // Missing keys (older or hand-edited settings) fall back to the defaults.
    private enum CodingKeys: String, CodingKey {
        case refreshInterval, sourceEnabled, notificationsEnabled, triggers, includeTeamReviewRequests
        case defaultRepo, defaultJiraProject, jiraSite, jiraEmail, hotkey, launchAtLogin
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        self.init(
            refreshInterval: try c.decodeIfPresent(TimeInterval.self, forKey: .refreshInterval) ?? d.refreshInterval,
            sourceEnabled: d.sourceEnabled.merging(
                try c.decodeIfPresent([Source: Bool].self, forKey: .sourceEnabled) ?? [:]) { $1 },
            notificationsEnabled: d.notificationsEnabled.merging(
                try c.decodeIfPresent([Source: Bool].self, forKey: .notificationsEnabled) ?? [:]) { $1 },
            triggers: d.triggers.merging(
                try c.decodeIfPresent([NotificationTrigger: Bool].self, forKey: .triggers) ?? [:]) { $1 },
            includeTeamReviewRequests: try c.decodeIfPresent(Bool.self, forKey: .includeTeamReviewRequests)
                ?? d.includeTeamReviewRequests,
            defaultRepo: try c.decodeIfPresent(String.self, forKey: .defaultRepo),
            defaultJiraProject: try c.decodeIfPresent(String.self, forKey: .defaultJiraProject),
            jiraSite: try c.decodeIfPresent(URL.self, forKey: .jiraSite),
            jiraEmail: try c.decodeIfPresent(String.self, forKey: .jiraEmail),
            hotkey: try c.decodeIfPresent(Hotkey.self, forKey: .hotkey) ?? d.hotkey,
            launchAtLogin: try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin)
    }

    public static func load(from defaults: UserDefaults) -> AppSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return settings
    }

    public func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// Whether going from `old` to these settings changes what the sources fetch (a switched
    /// source, team review requests, the Jira site or e-mail), so the shell refetches right away.
    public func requiresRefetch(comparedTo old: AppSettings) -> Bool {
        sourceEnabled != old.sourceEnabled || includeTeamReviewRequests != old.includeTeamReviewRequests
            || jiraSite != old.jiraSite || jiraEmail != old.jiraEmail
    }

    // MARK: Defaults pre-fill

    /// The repo (`owner/name`) with the most PRs; ties go to the alphabetically first.
    public static func mostFrequentRepo(_ prs: [PullRequest]) -> String? {
        mode(of: prs.map(\.repo))
    }

    /// The Jira project key (the part of the ticket key before the number) with the most tickets.
    public static func mostFrequentProject(_ tickets: [Ticket]) -> String? {
        mode(of: tickets.compactMap { ticket in ticket.key.lastIndex(of: "-").map { String(ticket.key[..<$0]) } })
    }

    private static func mode(of values: [String]) -> String? {
        let counts = values.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        return counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
    }
}
