import AppKit
import DevPulseCore
import SwiftUI
import UserNotifications

/// The raw value names the tab for the demo's `-DevPulseDemoOpen settings:<tab>`.
enum SettingsTab: String, Hashable {
    case general, github, jira, notifications, updates
}

/// The Settings window (spec §5.4): one tab per area.
struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView(selection: $model.settingsTab) {
            Tab("General", systemImage: "gearshape", value: .general) { GeneralSettingsView(model: model) }
            Tab("GitHub", systemImage: "chevron.left.forwardslash.chevron.right", value: .github) {
                GitHubSettingsView(model: model)
            }
            Tab("Jira", systemImage: "ticket", value: .jira) { JiraSettingsView(model: model) }
            Tab("Notifications", systemImage: "bell.badge", value: .notifications) {
                NotificationSettingsView(model: model)
            }
            Tab("Updates", systemImage: "arrow.triangle.2.circlepath", value: SettingsTab.updates) {
                UpdateSettingsView(updates: model.updates)
            }
        }
        .frame(width: 520)
        .scenePadding(.top)
        .background(WindowReader { model.settingsPresenter.windowAppeared($0) })
    }
}

// MARK: General

private struct GeneralSettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                Stepper(value: refreshMinutes, in: 1...30) {
                    LabeledContent("Refresh GitHub and Jira every", value: "\(refreshMinutes.wrappedValue) min")
                }
                Toggle("Launch at login", isOn: Binding(
                    get: { model.launchesAtLogin }, set: { model.setLaunchAtLogin($0) }))
                if model.loginItemNeedsApproval {
                    Text("Approve DevPulse in System Settings › General › Login Items.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = model.loginItemError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Section {
                LabeledContent("Quick launcher shortcut") {
                    HotkeyRecorder(hotkey: $model.settings.hotkey)
                }
                if let error = model.hotkeyError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Section {
                LabeledContent("Command line tool") { commandLineTool }
                if let blocker = model.cliInstallBlocker {
                    Text(blocker).font(.caption).foregroundStyle(.secondary)
                } else if let error = model.cliInstallError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            } footer: {
                Text("Puts `devpulse` on your PATH for the terminal dashboard.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            model.updateLaunchAtLoginStatus()
            model.updateCLIStatus()
        }
    }

    @ViewBuilder
    private var commandLineTool: some View {
        let canInstall = model.cliInstallBlocker == nil
        switch model.cliStatus {
        case .installed:
            Text("Installed at \(CLIInstall.linkPath)").foregroundStyle(.secondary)
        case .pointsElsewhere(let path):
            HStack {
                Text("\(CLIInstall.linkPath) points to \(path)").foregroundStyle(.secondary)
                Button("Replace", action: model.installCommandLineTool).disabled(!canInstall)
            }
        case .notInstalled:
            Button("Install", action: model.installCommandLineTool).disabled(!canInstall)
        }
    }

    private var refreshMinutes: Binding<Int> {
        Binding(
            get: { Int((model.settings.refreshInterval / 60).rounded()) },
            set: { model.settings.refreshInterval = TimeInterval($0 * 60) })
    }
}

// MARK: GitHub

private struct GitHubSettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") { status }
                if model.snapshot.sources.github.state != .ok {
                    Text("DevPulse uses the GitHub CLI. Run `gh auth login` in a terminal, then check again.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Check Again", action: model.refreshAll)
                        .disabled(model.isRefreshing)
                }
            }
            Section {
                Toggle("Include team review requests", isOn: $model.settings.includeTeamReviewRequests)
            } footer: {
                Text("Also list pull requests that ask one of your teams for a review.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                TextField("Default repository", text: optionalText(\.defaultRepo),
                          prompt: Text(AppSettings.mostFrequentRepo(model.snapshot.myPullRequests) ?? "owner/name"))
            } footer: {
                Text("Used by the quick launcher for `gh <number>`; empty means the repository of most of your pull requests.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var status: some View {
        let github = model.snapshot.sources.github
        switch github.state {
        case .ok:
            Label(model.githubLogin.map { "Signed in as \($0)" } ?? "Connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .error:
            Text(github.message ?? "Error").foregroundStyle(.red)
        case .fetching:
            Text("Checking…").foregroundStyle(.secondary)
        case .disabled:
            Text("Off").foregroundStyle(.secondary)
        case .unconfigured:
            Text("Not configured").foregroundStyle(.secondary)
        }
    }

    private func optionalText(_ field: WritableKeyPath<AppSettings, String?>) -> Binding<String> {
        Binding(
            get: { model.settings[keyPath: field] ?? "" },
            set: {
                let text = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                model.settings[keyPath: field] = text.isEmpty ? nil : text
            })
    }
}

// MARK: Jira

private struct JiraSettingsView: View {
    @Bindable var model: AppModel
    @State private var site = ""
    @State private var email = ""
    @State private var token = ""
    @State private var hasStoredToken = false
    @State private var result: Result<String, any Error>?
    @State private var isTesting = false

    var body: some View {
        Form {
            Section {
                TextField("Site", text: $site, prompt: Text("acme.atlassian.net"))
                TextField("E-mail", text: $email, prompt: Text("you@acme.com"))
                    .textContentType(.username)
                SecureField("API token", text: $token,
                            prompt: Text(hasStoredToken ? "Saved in Keychain — leave empty to keep" : "Paste your API token"))
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Link("Create an API token at id.atlassian.com",
                         destination: URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")!)
                    Text("The token is stored in your login Keychain, never in the settings file.")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            Section {
                HStack {
                    resultLine
                    Spacer()
                    if isTesting { ProgressView().controlSize(.small) }
                    Button("Test Connection", action: test).disabled(isTesting)
                    Button("Save", action: save).keyboardShortcut(.defaultAction)
                }
            }
            Section {
                TextField("Default project", text: defaultProject,
                          prompt: Text(AppSettings.mostFrequentProject(model.snapshot.tickets) ?? "KEY"))
            } footer: {
                Text("Used by the quick launcher for `jira <number>`; empty means the project of most of your tickets.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
    }

    @ViewBuilder
    private var resultLine: some View {
        switch result {
        case .success(let text):
            Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failure(let error):
            Text(error.localizedDescription).foregroundStyle(.red)
        case nil:
            EmptyView()
        }
    }

    private var defaultProject: Binding<String> {
        Binding(
            get: { model.settings.defaultJiraProject ?? "" },
            set: {
                let text = $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                model.settings.defaultJiraProject = text.isEmpty ? nil : text
            })
    }

    private func load() {
        site = model.settings.jiraSite?.absoluteString ?? ""
        email = model.settings.jiraEmail ?? ""
        hasStoredToken = model.storedJiraToken(for: model.settings.jiraEmail)
    }

    private func save() {
        do {
            try model.saveJira(site: site, email: email, token: token)
            token = ""
            load()
            result = .success("Saved")
        } catch {
            result = .failure(error)
        }
    }

    private func test() {
        isTesting = true
        result = nil
        Task {
            do {
                let count = try await model.testJira(site: site, email: email, token: token)
                result = .success("Connected — \(count) open ticket\(count == 1 ? "" : "s")")
            } catch {
                result = .failure(error)
            }
            isTesting = false
        }
    }
}

// MARK: Notifications

private struct NotificationSettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            if model.notifier.authorization == .denied {
                Section {
                    HStack {
                        Text("Notifications are turned off for DevPulse in System Settings.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open System Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                        }
                    }
                }
            }
            ForEach(Source.allCases, id: \.self) { source in
                Section {
                    ForEach(NotificationTrigger.allCases.filter { $0.source == source }, id: \.self) { trigger in
                        Toggle(trigger.label, isOn: binding(for: trigger))
                            .disabled(!isEnabled(source))
                            .help(trigger == .teamReviewRequest && !model.settings.includeTeamReviewRequests
                                  ? "Needs “Include team review requests” in GitHub" : "")
                    }
                } header: {
                    Toggle(isOn: binding(for: source)) {
                        Text(source.label).font(.headline)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await model.notifier.updateAuthorization() }
    }

    /// The source's notification master switch; the source stays fetched and shown either way.
    private func isEnabled(_ source: Source) -> Bool { model.settings.notificationsEnabled[source] ?? true }

    private func binding(for source: Source) -> Binding<Bool> {
        Binding(get: { isEnabled(source) }, set: { model.settings.notificationsEnabled[source] = $0 })
    }

    private func binding(for trigger: NotificationTrigger) -> Binding<Bool> {
        Binding(
            get: { model.settings.triggers[trigger] ?? trigger.defaultEnabled },
            set: { model.settings.triggers[trigger] = $0 })
    }
}

private extension Source {
    var label: String {
        switch self {
        case .github: "GitHub"
        case .jira: "Jira"
        case .claude: "Claude Code"
        }
    }
}

private extension NotificationTrigger {
    var label: String {
        switch self {
        case .directReviewRequest: "Review requested from you"
        case .teamReviewRequest: "Review requested from one of your teams"
        case .prHumanComment: "New comment or review by a person"
        case .prCopilotComment: "New comment or review by Copilot"
        case .prBotComment: "New comment by another bot (CI, Sonar, Dependabot…)"
        case .ciFinished: "CI finished (passed, failed or errored)"
        case .jiraHumanComment: "New comment by a person"
        case .jiraAutomationComment: "New comment by Jira automation or an app"
        case .claudeWaiting: "A session is waiting for your input"
        case .claudeFinished: "A session finished its work"
        }
    }
}

// MARK: Updates

private struct UpdateSettingsView: View {
    @Bindable var updates: UpdateService

    var body: some View {
        Form {
            Section {
                Toggle("Check for updates automatically", isOn: $updates.automaticallyChecks)
                LabeledContent("DevPulse \(version)") {
                    Button("Check Now", action: updates.checkNow)
                        .disabled(!updates.canCheck)
                }
            } footer: {
                Text("DevPulse asks at every launch whether a newer version exists and installs it only after you agree.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }
}
