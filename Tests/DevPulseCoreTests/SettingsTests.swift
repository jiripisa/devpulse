import Foundation
import Testing
@testable import DevPulseCore

/// Runs `body` with an empty defaults suite of its own and removes it afterwards. The suite is a
/// file in a temporary folder: one named by a plain suite name would end up in
/// `~/Library/Preferences`, where `cfprefsd` writes its plist back even after it was removed.
private func withFreshDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
    let folder = FileManager.default.temporaryDirectory.appending(path: "devpulse.tests.\(UUID().uuidString)")
    let name = folder.appending(path: "settings").path
    defer {
        UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(at: folder)
    }
    try body(UserDefaults(suiteName: name)!)
}

@Suite struct SettingsTests {
    @Test func defaultsMatchTheSpec() {
        let settings = AppSettings()
        #expect(settings.refreshInterval == 120)
        #expect(Source.allCases.allSatisfy { settings.sourceEnabled[$0] == true })
        #expect(settings.includeTeamReviewRequests == false)
        #expect(settings.defaultRepo == nil)
        #expect(settings.jiraProjects.isEmpty)
        #expect(settings.jiraSite == nil)
        #expect(settings.jiraEmail == nil)
        #expect(settings.hotkey == Hotkey(keyCode: 49, modifiers: [.option]))
        #expect(settings.launchAtLogin == true)
    }

    @Test func triggerDefaultsAndSources() {
        let on: Set<NotificationTrigger> = [
            .directReviewRequest, .prHumanComment, .prCopilotComment, .ciFinished,
            .jiraHumanComment, .claudeWaiting, .claudeFinished,
        ]
        for trigger in NotificationTrigger.allCases {
            #expect(trigger.defaultEnabled == on.contains(trigger), "\(trigger)")
            #expect(AppSettings().triggers[trigger] == trigger.defaultEnabled)
        }
        #expect(NotificationTrigger.directReviewRequest.source == .github)
        #expect(NotificationTrigger.ciFinished.source == .github)
        #expect(NotificationTrigger.jiraAutomationComment.source == .jira)
        #expect(NotificationTrigger.claudeWaiting.source == .claude)
        #expect(NotificationTrigger.claudeFinished.source == .claude)
    }

    @Test func intervalIsClampedTo60To1800() {
        #expect(AppSettings(refreshInterval: 5).refreshInterval == 60)
        #expect(AppSettings(refreshInterval: 99_999).refreshInterval == 1800)
        #expect(AppSettings(refreshInterval: 300).refreshInterval == 300)
        var settings = AppSettings()
        settings.refreshInterval = 1
        #expect(settings.refreshInterval == 60)
    }

    @Test func decodingClampsAndFillsMissingFields() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"refreshInterval": 10}"#.utf8))
        #expect(settings.refreshInterval == 60)
        #expect(settings.launchAtLogin == true)
        #expect(settings.hotkey.keyCode == 49)
        // Stored before notifications had their own switches.
        #expect(Source.allCases.allSatisfy { settings.notificationsEnabled[$0] == true })
    }

    @Test func jsonRoundTrip() throws {
        var settings = AppSettings()
        settings.refreshInterval = 600
        settings.sourceEnabled[.jira] = false
        settings.notificationsEnabled[.claude] = false
        settings.triggers[.prBotComment] = true
        settings.includeTeamReviewRequests = true
        settings.defaultRepo = "acme/app"
        settings.jiraProjects = ["ACME"]
        settings.jiraSite = URL(string: "https://acme.atlassian.net")
        settings.jiraEmail = "me@acme.test"
        settings.hotkey = Hotkey(keyCode: 40, modifiers: [.command, .shift])
        settings.launchAtLogin = false
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AppSettings.self, from: data) == settings)
    }

    @Test func userDefaultsRoundTrip() {
        withFreshDefaults { defaults in
            #expect(AppSettings.load(from: defaults) == AppSettings())
            var settings = AppSettings()
            settings.defaultRepo = "acme/app"
            settings.sourceEnabled[.claude] = false
            settings.save(to: defaults)
            #expect(AppSettings.load(from: defaults) == settings)
        }
    }

    @Test func mostFrequentRepoPicksTheModeWithAlphabeticalTies() {
        #expect(AppSettings.mostFrequentRepo([]) == nil)
        let prs = ["b/x", "a/y", "b/x", "a/y", "c/z"].enumerated().map { makePR(repo: $1, number: $0) }
        #expect(AppSettings.mostFrequentRepo(prs) == "a/y")
        let prs2 = ["b/x", "b/x", "a/y"].enumerated().map { makePR(repo: $1, number: $0) }
        #expect(AppSettings.mostFrequentRepo(prs2) == "b/x")
    }

    @Test func theOldSingleProjectBecomesTheProjectList() throws {
        let old = Data(#"{"defaultJiraProject":"STORE","refreshInterval":300}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: old)
        #expect(settings.jiraProjects == ["STORE"])
        let both = Data(#"{"defaultJiraProject":"STORE","jiraProjects":["WA","OPS"]}"#.utf8)
        #expect(try JSONDecoder().decode(AppSettings.self, from: both).jiraProjects == ["WA", "OPS"])
        #expect(AppSettings().jiraProjects.isEmpty)
    }

    @Test func parsesTheProjectListAsTyped() {
        #expect(AppSettings.parseProjects("store, WA  ops") == ["STORE", "WA", "OPS"])
        #expect(AppSettings.parseProjects(" , store,,store ;x 9AB a-b") == ["STORE"])
        #expect(AppSettings.parseProjects("") == [])
        #expect(AppSettings.parseProjects((1...12).map { "P\($0)" }.joined(separator: ",")).count
            == AppSettings.maxJiraProjects)
        #expect(AppSettings.projectsText(["STORE", "WA"]) == "STORE, WA")
        var settings = AppSettings()
        settings.jiraProjects = ["store", "Store", "wa"]
        #expect(settings.jiraProjects == ["STORE", "WA"])
    }

    @Test func projectsByFrequencyListsEveryProjectMostTicketsFirst() {
        #expect(AppSettings.projectsByFrequency([]) == [])
        let tickets = ["WA-1", "STORE-2", "STORE-3", "OPS-4", "AB-5"].map { makeTicket(key: $0) }
        #expect(AppSettings.projectsByFrequency(tickets) == ["STORE", "AB", "OPS", "WA"])
    }

}

@Suite struct KeychainTests {
    @Test func writeReadOverwriteDelete() throws {
        let service = "io.jp4.devpulse.tests.\(UUID().uuidString)"
        defer { Keychain.delete(service: service, account: "me") }
        #expect(Keychain.read(service: service, account: "me") == nil)
        try Keychain.write("secret", service: service, account: "me")
        #expect(Keychain.read(service: service, account: "me") == "secret")
        try Keychain.write("other", service: service, account: "me")
        #expect(Keychain.read(service: service, account: "me") == "other")
        Keychain.delete(service: service, account: "me")
        #expect(Keychain.read(service: service, account: "me") == nil)
    }
}

func makePR(repo: String = "acme/app", number: Int = 1, id: String? = nil) -> PullRequest {
    PullRequest(
        id: id ?? "\(repo)#\(number)", repo: repo, number: number, title: "PR \(number)",
        url: "https://github.com/\(repo)/pull/\(number)", headBranch: "b", headOid: "o",
        checks: .none, reviewDecision: .none, approvals: 0, pendingReviewers: 0, commentCount: 0,
        requestedDirectly: false, updatedAt: Date(timeIntervalSince1970: 0), recentComments: [])
}

func makeTicket(key: String) -> Ticket {
    Ticket(
        key: key, summary: "S", status: "To Do", statusCategory: .todo,
        url: "https://acme.atlassian.net/browse/\(key)", updatedAt: Date(timeIntervalSince1970: 0),
        commentCount: 0, recentComments: [])
}
