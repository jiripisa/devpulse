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
    /// The Jira projects (keys like `STORE`) the launcher looks a bare number and
    /// `jira <number>` up in, at most `maxJiraProjects`; the first one's row stays when the
    /// ticket does not exist. Empty means the projects of my tickets, most tickets first.
    public var jiraProjects: [String] {
        didSet { jiraProjects = Self.cleanProjects(jiraProjects) }
    }
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
        jiraProjects: [String] = [],
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
        self.jiraProjects = Self.cleanProjects(jiraProjects)
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
        case defaultRepo, jiraProjects, jiraSite, jiraEmail, hotkey, launchAtLogin
        /// Before 0.10 there was one project; it becomes the only entry of `jiraProjects`.
        case defaultJiraProject
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(refreshInterval, forKey: .refreshInterval)
        try c.encode(sourceEnabled, forKey: .sourceEnabled)
        try c.encode(notificationsEnabled, forKey: .notificationsEnabled)
        try c.encode(triggers, forKey: .triggers)
        try c.encode(includeTeamReviewRequests, forKey: .includeTeamReviewRequests)
        try c.encodeIfPresent(defaultRepo, forKey: .defaultRepo)
        try c.encode(jiraProjects, forKey: .jiraProjects)
        try c.encodeIfPresent(jiraSite, forKey: .jiraSite)
        try c.encodeIfPresent(jiraEmail, forKey: .jiraEmail)
        try c.encode(hotkey, forKey: .hotkey)
        try c.encode(launchAtLogin, forKey: .launchAtLogin)
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
            jiraProjects: try c.decodeIfPresent([String].self, forKey: .jiraProjects)
                ?? (try c.decodeIfPresent(String.self, forKey: .defaultJiraProject)).map { [$0] } ?? [],
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

    /// Every Jira project of these tickets, the one with the most tickets first (ties
    /// alphabetically), at most `maxJiraProjects`.
    public static func projectsByFrequency(_ tickets: [Ticket]) -> [String] {
        let counts = tickets.map { JiraKey.project(of: $0.key) }.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        let sorted = counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
        return Array(sorted.prefix(maxJiraProjects))
    }

    // MARK: Jira projects

    /// A bare number costs one lookup per project, so the list stays short.
    public static let maxJiraProjects = 10

    /// The project keys in what was typed in Settings, e.g. `store, WA  ops`: separated by
    /// commas or spaces, upper-cased, each once, invalid ones left out.
    public static func parseProjects(_ text: String) -> [String] {
        cleanProjects(text.split { $0 == "," || $0.isWhitespace }.map(String.init))
    }

    /// The projects as Settings shows them: `STORE, WA`.
    public static func projectsText(_ projects: [String]) -> String {
        projects.joined(separator: ", ")
    }

    private static func cleanProjects(_ projects: [String]) -> [String] {
        var seen = Set<String>()
        let keys = projects
            .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { $0.wholeMatch(of: /[A-Z][A-Z0-9_]*/) != nil && seen.insert($0).inserted }
        return Array(keys.prefix(maxJiraProjects))
    }

    private static func mode(of values: [String]) -> String? {
        let counts = values.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        return counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
    }
}
