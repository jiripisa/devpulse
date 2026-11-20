#if DEBUG
import Foundation
import Testing
@testable import DevPulseCore

@Suite("Demo mode")
struct DemoModeTests {

    @Test("launcher:<query> opens the launcher with the rest typed in, spaces and colons kept")
    func launcherQuery() {
        #expect(DemoOpen(argument: "launcher:gh") == .launcher(query: "gh"))
        #expect(DemoOpen(argument: "launcher:gh webapp 455") == .launcher(query: "gh webapp 455"))
        #expect(DemoOpen(argument: "launcher:a:b") == .launcher(query: "a:b"))
        #expect(DemoOpen(argument: "launcher:") == .launcher(query: ""))
    }

    @Test("popover opens the popover content")
    func popover() {
        #expect(DemoOpen(argument: "popover") == .popover)
    }

    @Test("settings:<tab> opens Settings on that tab")
    func settings() {
        #expect(DemoOpen(argument: "settings:jira") == .settings(tab: "jira"))
        #expect(DemoOpen(argument: "settings:notifications") == .settings(tab: "notifications"))
    }

    @Test("Anything else is not understood", arguments: ["", "launcher", "popover:x", "settings", "settings:", "menu:x", "Popover"])
    func unknown(argument: String) {
        #expect(DemoOpen(argument: argument) == nil)
    }

    @Test("The demo serves its own socket next to the app's")
    func socketPath() {
        let app = URL(fileURLWithPath: SocketServer.defaultPath)
        let demo = URL(fileURLWithPath: SocketServer.demoPath)
        #expect(demo.lastPathComponent == "devpulse-demo.sock")
        #expect(demo.deletingLastPathComponent() == app.deletingLastPathComponent())
    }

    @Test("Demo settings use example values in their own defaults suite")
    func settingsValues() {
        let settings = DemoSnapshot.settings
        #expect(DemoSnapshot.defaultsSuite == "io.jp4.devpulse.demo")
        #expect(settings.jiraSite == URL(string: "https://acme.atlassian.net"))
        #expect(settings.jiraEmail == "alice@acme.example")
        #expect(settings.defaultRepo == "acmecorp/webapp")
        // GitHub signs in through gh, not the settings: the demo's login is a value of its own.
        #expect(DemoSnapshot.githubLogin == "alice")
        // Everything else stays at the defaults, as a new user would see it.
        var defaults = settings
        defaults.jiraSite = nil
        defaults.jiraEmail = nil
        defaults.defaultRepo = nil
        #expect(defaults == AppSettings())
    }
}
#endif
