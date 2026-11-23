#if DEBUG
import Foundation

// DEBUG builds only: what a demo needs besides its snapshot, so the website's screenshots can be
// taken next to a running DevPulse without touching it (see development_workflow.md §3).

/// What a demo opens at launch, from `-DevPulseDemoOpen <what>`: no hotkey and no click on the
/// menu bar needed.
public enum DemoOpen: Equatable, Sendable {
    /// The launcher panel with this query typed in, and with the row `select` selected as if the
    /// user had moved there, so it expands.
    case launcher(query: String, select: Int? = nil)
    /// The popover's content in a plain window at its real size.
    case popover
    /// The Settings window on the tab with this name (`general`, `jira`, …).
    case settings(tab: String)

    /// `launcher:<query>[@<row>]`, `popover` or `settings:<tab>`; nil for anything else.
    public init?(argument: String) {
        if argument == "popover" {
            self = .popover
            return
        }
        guard let colon = argument.firstIndex(of: ":") else { return nil }
        let value = String(argument[argument.index(after: colon)...])
        switch argument[..<colon] {
        case "launcher":
            if let at = value.lastIndex(of: "@"), let row = Int(value[value.index(after: at)...]) {
                self = .launcher(query: String(value[..<at]), select: row)
            } else {
                self = .launcher(query: value)
            }
        case "settings" where !value.isEmpty: self = .settings(tab: value)
        default: return nil
        }
    }
}

extension DemoSnapshot {
    /// The defaults suite a demo keeps its settings in; the app's own domain stays untouched.
    public static let defaultsSuite = "io.jp4.devpulse.demo"

    /// The GitHub login a demo's Settings show as signed in ("Signed in as alice"); a demo never
    /// asks `gh`.
    public static let githubLogin = "alice"

    /// What a demo's Settings show: example Jira and GitHub values, defaults otherwise. The Jira
    /// token is never stored; the demo only says that one is.
    public static var settings: AppSettings {
        AppSettings(
            githubRepos: ["acmecorp/webapp"],
            jiraSite: URL(string: "https://acme.atlassian.net"),
            jiraEmail: "alice@acme.example")
    }
}

extension SocketServer {
    /// `~/Library/Application Support/DevPulse/devpulse-demo.sock`: a demo never takes the
    /// socket of a DevPulse that runs at the same time.
    public static var demoPath: String {
        URL(fileURLWithPath: defaultPath).deletingLastPathComponent()
            .appendingPathComponent("devpulse-demo.sock").path
    }
}
#endif
