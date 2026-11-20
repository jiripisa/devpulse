import Foundation
import Testing
@testable import DevPulseCore

@Suite @MainActor struct TokenCacheTests {
    @Test func readsOncePerAccountUntilInvalidated() {
        var reads: [String] = []
        let cache = TokenCache { account in
            reads.append(account)
            return account == "me@acme.com" ? "secret" : nil
        }
        #expect(cache.token(for: "me@acme.com") == "secret")
        #expect(cache.token(for: "me@acme.com") == "secret")
        #expect(reads == ["me@acme.com"])

        cache.invalidate()
        #expect(cache.token(for: "me@acme.com") == "secret")
        #expect(reads == ["me@acme.com", "me@acme.com"])
    }

    @Test func aMissIsReadAgain() {
        var stored: String?
        var reads = 0
        let cache = TokenCache { _ in
            reads += 1
            return stored
        }
        #expect(cache.token(for: "me@acme.com") == nil)
        // A locked Keychain or a token added later: the next refresh reads again.
        stored = "secret"
        #expect(cache.token(for: "me@acme.com") == "secret")
        #expect(cache.token(for: "me@acme.com") == "secret")
        #expect(reads == 2)
    }
}

@Suite struct HotkeyTextTests {
    @Test func defaultIsOptionSpace() {
        #expect(Hotkey(keyCode: 49, modifiers: [.option]).displayText == "⌥Space")
    }

    @Test func modifiersUseTheStandardOrder() {
        #expect(Hotkey(keyCode: 40, modifiers: [.command, .shift, .option, .control]).displayText == "⌃⌥⇧⌘K")
    }

    @Test func namesSpecialAndUnknownKeys() {
        #expect(Hotkey(keyCode: 122, modifiers: [.control]).displayText == "⌃F1")
        #expect(Hotkey(keyCode: 126, modifiers: [.command]).displayText == "⌘↑")
        #expect(Hotkey(keyCode: 36, modifiers: [.option]).displayText == "⌥↩")
        #expect(Hotkey(keyCode: 200, modifiers: [.option]).displayText == "⌥Key 200")
    }

    @Test func needsARealModifier() {
        #expect(Hotkey(keyCode: 0, modifiers: []).problem != nil)
        #expect(Hotkey(keyCode: 0, modifiers: [.shift]).problem != nil)
        #expect(Hotkey(keyCode: 0, modifiers: [.control, .shift]).problem == nil)
    }

    @Test func refusesSpotlightShortcuts() {
        #expect(Hotkey(keyCode: 49, modifiers: [.command]).problem == "⌘Space is the Spotlight shortcut")
        #expect(Hotkey(keyCode: 49, modifiers: [.command, .option]).problem == "⌥⌘Space opens Spotlight in Finder")
        #expect(Hotkey(keyCode: 49, modifiers: [.option]).problem == nil)
    }
}

@Suite struct JiraSiteTests {
    @Test(arguments: [
        ("acme.atlassian.net", "https://acme.atlassian.net"),
        ("  https://acme.atlassian.net/  ", "https://acme.atlassian.net"),
        ("https://acme.atlassian.net/jira/your-work", "https://acme.atlassian.net"),
        // HTTPS only: the API token must never go out in clear text.
        ("http://jira.local:8080/", "https://jira.local:8080"),
        ("HTTP://acme.atlassian.net", "https://acme.atlassian.net"),
    ])
    func normalizes(input: String, expected: String) {
        #expect(JiraCredentials.site(from: input)?.absoluteString == expected)
    }

    @Test(arguments: ["", "   ", "https://", "ftp://acme.atlassian.net", "not a host"])
    func rejects(input: String) {
        #expect(JiraCredentials.site(from: input) == nil)
    }
}

@Suite struct JiraTokenStoreTests {
    private final class Memory {
        var items: [String: String] = [:]
        var store: SecretStore {
            SecretStore(
                read: { self.items[$0] },
                write: { value, account in self.items[account] = value },
                delete: { self.items[$0] = nil })
        }
    }

    @Test func writesANewToken() throws {
        let memory = Memory()
        try JiraCredentials.storeToken(" tok ", email: "me@acme.com", previousEmail: nil, in: memory.store)
        #expect(memory.items == ["me@acme.com": "tok"])
    }

    @Test func emptyTokenKeepsTheStoredOne() throws {
        let memory = Memory()
        memory.items = ["me@acme.com": "old"]
        try JiraCredentials.storeToken("", email: "me@acme.com", previousEmail: "me@acme.com", in: memory.store)
        #expect(memory.items == ["me@acme.com": "old"])
    }

    @Test func changedEmailMovesTheStoredToken() throws {
        let memory = Memory()
        memory.items = ["old@acme.com": "old"]
        try JiraCredentials.storeToken("", email: "new@acme.com", previousEmail: "old@acme.com", in: memory.store)
        #expect(memory.items == ["new@acme.com": "old"])
    }

    @Test func changedEmailWithNewTokenDropsTheOldItem() throws {
        let memory = Memory()
        memory.items = ["old@acme.com": "old"]
        try JiraCredentials.storeToken("new", email: "new@acme.com", previousEmail: "old@acme.com", in: memory.store)
        #expect(memory.items == ["new@acme.com": "new"])
    }
}

@Suite struct AppLocationTests {
    private let home = URL(fileURLWithPath: "/Users/me")

    @Test(arguments: ["/Applications/DevPulse.app", "/Users/me/Applications/DevPulse.app", "/Applications/Tools/DevPulse.app"])
    func installed(path: String) {
        #expect(AppLocation.isInstalled(bundleURL: URL(fileURLWithPath: path), home: home))
    }

    @Test(arguments: [
        "/Users/me/Development/devpulse/build/release/DevPulse.app",
        "/Volumes/DevPulse/DevPulse.app",
        "/private/var/folders/xy/T/AppTranslocation/1234/d/DevPulse.app",
        "/Applications-old/DevPulse.app",
    ])
    func notInstalled(path: String) {
        #expect(!AppLocation.isInstalled(bundleURL: URL(fileURLWithPath: path), home: home))
    }
}
