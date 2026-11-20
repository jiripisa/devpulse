import AppKit
import DevPulseCore
import Observation
import os
import ServiceManagement

/// The app's single owner of state: wires the store, the refresh loop, the Claude watcher and
/// the socket server, and mirrors the store's snapshot for the SwiftUI views.
@MainActor
@Observable
final class AppModel {
    private(set) var snapshot: Snapshot
    private(set) var isRefreshing = false
    /// The GitHub login of the last successful fetch, for the Settings status line.
    private(set) var githubLogin: String?
    /// Whether macOS starts DevPulse at login (`SMAppService.mainApp`), and whether that waits
    /// for the user's approval in System Settings.
    private(set) var launchesAtLogin = false
    private(set) var loginItemNeedsApproval = false
    /// Why the last launch-at-login change failed, shown under the toggle.
    private(set) var loginItemError: String?
    /// Whether `/usr/local/bin/devpulse` links to this app's CLI, and why an install failed.
    private(set) var cliStatus: CLIStatus = .notInstalled
    private(set) var cliInstallError: String?
    /// The selected Settings tab; the popover's Jira "Set up" link opens the Jira tab.
    var settingsTab: SettingsTab = .general
    /// Why the launcher shortcut could not be registered (taken by another app), shown in Settings.
    private(set) var hotkeyError: String?
    @ObservationIgnored private var refreshesRunning = 0
    /// DEBUG builds started with `-DevPulseDemoSnapshot <path>` show that snapshot instead of
    /// live data, for the website's screenshots: nothing is fetched, watched, notified or saved.
    @ObservationIgnored private let demoSnapshot: Snapshot?

    var settings: AppSettings {
        didSet { settingsChanged(from: oldValue) }
    }

    @ObservationIgnored let store: SnapshotStore
    @ObservationIgnored let server = SocketServer(path: SocketServer.defaultPath)
    @ObservationIgnored let updates: UpdateService
    let notifier = Notifier()
    @ObservationIgnored private(set) var opener: Opener!
    @ObservationIgnored private var launcher: LauncherPanelController?
    @ObservationIgnored private var hotkeyMonitor: HotkeyMonitor?
    /// The SwiftUI `openSettings` action, handed over by the menu bar label (actions only exist
    /// inside views).
    @ObservationIgnored var showSettingsWindow: (() -> Void)?

    @ObservationIgnored private let log = Logger(subsystem: "io.jp4.devpulse", category: "app")
    @ObservationIgnored private let policy = RefreshPolicy()
    @ObservationIgnored private var refreshLoop: Task<Void, Never>?
    @ObservationIgnored private var observers: [(NotificationCenter, any NSObjectProtocol)] = []
    @ObservationIgnored private var isAsleep = false
    @ObservationIgnored private var isLocked = false
    @ObservationIgnored private var seen: SeenState
    /// What `seen.json` holds, and when this run last wrote it (see `SeenState.needsSaving`).
    @ObservationIgnored private var savedSeen: SeenState
    @ObservationIgnored private var seenSavedAt: Date?
    /// The Jira token, read from the Keychain once; `jiraCredentialsChanged()` drops it.
    @ObservationIgnored private let jiraTokens = TokenCache {
        Keychain.read(service: JiraCredentials.keychainService, account: $0)
    }

    init() {
        let demo = Self.loadDemoSnapshot()
        demoSnapshot = demo
        // A demo never checks for updates, neither at launch nor on Sparkle's schedule.
        updates = UpdateService(disabledReason: demo == nil ? nil : DemoSnapshot.upgradeReport.message)
        let seen = SeenState.load(from: SeenState.defaultURL)
        self.seen = seen
        savedSeen = seen
        // The demo never reads the real settings (a Jira site would show in the launcher).
        let settings = demo == nil ? AppSettings.load(from: .standard) : AppSettings()
        self.settings = settings
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        // The credentials closure reads the store's current settings; the store does not exist
        // yet when the closure is made.
        weak var weakStore: SnapshotStore?
        let tokens = jiraTokens
        let store = SnapshotStore(
            github: GitHubSource(tokens: GhCLITokenProvider()),
            jiraFactory: { JiraSource(credentials: $0) },
            claude: ClaudeSessionSource(),
            jiraCredentials: {
                guard let settings = weakStore?.settings else { return nil }
                return JiraCredentials.resolve(settings: settings) { tokens.token(for: $0) }
            },
            settings: settings,
            appVersion: version)
        weakStore = store
        self.store = store
        snapshot = demo ?? store.snapshot
        opener = Opener { [weak self] pid in self?.snapshot.sessions.first { $0.pid == pid } }
        start()
    }

    // MARK: Demo

    /// The snapshot of `-DevPulseDemoSnapshot <path>` (DEBUG only), or nil for live data. A
    /// path that does not load stops the app rather than falling back to the real data.
    private static func loadDemoSnapshot() -> Snapshot? {
        #if DEBUG
        guard let path = UserDefaults.standard.string(forKey: "DevPulseDemoSnapshot") else { return nil }
        do {
            return try DemoSnapshot.load(from: URL(fileURLWithPath: path))
        } catch {
            fatalError("Demo snapshot \(path) not loaded: \(error)")
        }
        #else
        return nil
        #endif
    }

    // MARK: Lifecycle

    private func start() {
        if demoSnapshot != nil {
            startLauncher()
            startServer()
            return
        }
        store.onChange = { [weak self] old, new in
            self?.publish(new)
            self?.notifyChanges(old: old, new: new)
        }
        notifier.onOpen = { [weak self] target in self?.open(target) }
        notifier.requestPermission()
        applyLaunchAtLoginDefault()
        updateLaunchAtLoginStatus()
        updateCLIStatus()
        // The alert is modal, so it waits until the app's run loop is going.
        Task { @MainActor [weak self] in
            if CommandLineInstaller.offerOnce() { self?.installCommandLineTool() }
        }
        startLauncher()
        startServer()
        store.startWatchingClaude()
        observeSleepAndLock()
        restartRefreshLoop()
    }

    private func startLauncher() {
        let launcher = LauncherPanelController(model: self)
        self.launcher = launcher
        let monitor = HotkeyMonitor(hotkey: settings.hotkey) { launcher.toggle() }
        hotkeyMonitor = monitor
        updateHotkeyError(monitor.status)
    }

    private func updateHotkeyError(_ status: OSStatus) {
        if status == noErr {
            hotkeyError = nil
        } else {
            log.error("Launcher shortcut not registered, status \(status, privacy: .public)")
            hotkeyError = "\(settings.hotkey.displayText) is already taken by another app. Pick a different shortcut."
        }
    }

    private func startServer() {
        do {
            try server.start { [weak self] message, client in
                Task { @MainActor in self?.handle(message, from: client) }
            }
            // The server replays only the last broadcast to new clients, so seed it now.
            server.broadcast(.snapshot(snapshot))
        } catch {
            log.error("Socket server not started, running without IPC: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func publish(_ new: Snapshot) {
        snapshot = new
        if store.githubLogin != githubLogin { githubLogin = store.githubLogin }
        server.broadcast(.snapshot(new))
    }

    // MARK: Notifications

    /// Runs the change detector on every snapshot change, keeps its "seen" state on disk and
    /// posts what it returns.
    private func notifyChanges(old: Snapshot, new: Snapshot) {
        let events = ChangeDetector.events(
            old: old, new: new, myGitHubLogin: store.githubLogin, myJiraAccountId: store.jiraAccountId,
            settings: settings, seen: &seen)
        let now = Date()
        if seen.needsSaving(comparedTo: savedSeen, savedAt: seenSavedAt, now: now) {
            do {
                try seen.save(to: SeenState.defaultURL)
                savedSeen = seen
                seenSavedAt = now
                log.debug("Seen state saved")
            } catch {
                log.error("Seen state not saved: \(error.localizedDescription, privacy: .public)")
            }
        }
        log.debug("Change detector: \(events.count, privacy: .public) event(s)")
        if !events.isEmpty { notifier.post(events) }
    }

    // MARK: Refresh

    /// Fetches GitHub and Jira now (the popover's button, `r`, waking). Claude Code sessions
    /// come from the watcher only.
    func refreshAll() {
        refresh(soon: RefreshPolicy.fetchedSources)
    }

    private func refresh(soon sources: Set<Source>) {
        guard demoSnapshot == nil else { return }
        Task { await refresh(sources) }
    }

    private func refresh(_ sources: Set<Source>) async {
        refreshesRunning += 1
        isRefreshing = true
        await store.refresh(sources)
        refreshesRunning -= 1
        isRefreshing = refreshesRunning > 0
    }

    /// One task that sleeps until the next fetch is due; no polling in between. Restarting it
    /// (a changed interval) cancels only the sleep: a fetch in flight finishes and the next one
    /// is scheduled from its start with the new interval.
    private func restartRefreshLoop() {
        refreshLoop?.cancel()
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = await self?.refreshIfDue() else { return }
                let tolerance = self?.policy.tolerance(forSleep: delay) ?? 0
                try? await Task.sleep(for: .seconds(delay), tolerance: .seconds(tolerance))
            }
        }
    }

    /// Fetches when due and returns how long to sleep until the next check.
    private func refreshIfDue() async -> TimeInterval {
        if store.shouldRefresh(policy: policy) {
            // Its own unstructured task, so cancelling the loop never cancels the fetch.
            await Task { await self.refresh(RefreshPolicy.fetchedSources) }.value
        }
        let delay = policy.secondsUntilDue(
            now: Date(), lastAttempt: store.lastAttempt, interval: settings.refreshInterval)
        // Still 0 while paused: check again after a full interval (waking refreshes anyway).
        return delay > 0 ? delay : settings.refreshInterval
    }

    private func settingsChanged(from old: AppSettings) {
        guard settings != old, demoSnapshot == nil else { return }
        store.settings = settings
        settings.save(to: .standard)
        if settings.hotkey != old.hotkey, let hotkeyMonitor {
            hotkeyMonitor.register(settings.hotkey)
            updateHotkeyError(hotkeyMonitor.status)
        }
        if settings.refreshInterval != old.refreshInterval { restartRefreshLoop() }
        // Claude Code too, so its switch applies; the store takes its sessions from the watcher.
        if settings.requiresRefetch(comparedTo: old) { refresh(soon: Set(Source.allCases)) }
    }

    /// For a changed Jira token: it lives in the Keychain, so `settings` does not see it.
    func jiraCredentialsChanged() {
        jiraTokens.invalidate()
        refreshAll()
    }

    // MARK: Jira setup

    struct JiraSetupError: LocalizedError {
        let errorDescription: String?
    }

    /// Saves the Jira fields of Settings: the token goes to the Keychain (an empty token keeps
    /// the stored one), site and e-mail to the settings.
    func saveJira(site siteText: String, email emailText: String, token: String) throws {
        let (site, email) = try validatedJira(site: siteText, email: emailText)
        do {
            try JiraCredentials.storeToken(
                token, email: email, previousEmail: settings.jiraEmail,
                in: .keychain(service: JiraCredentials.keychainService))
        } catch {
            throw JiraSetupError(errorDescription: "The token could not be saved to the Keychain.")
        }
        jiraTokens.invalidate()
        var next = settings
        next.jiraSite = site
        next.jiraEmail = email
        // One mutation: when site or e-mail changed, `settings` starts the refetch itself.
        let refetches = next.requiresRefetch(comparedTo: settings)
        settings = next
        if !refetches { jiraCredentialsChanged() }
    }

    /// Fetches once with the entered values (the stored token when `token` is empty); returns
    /// the number of open tickets or throws with the message the popover would show.
    func testJira(site siteText: String, email emailText: String, token: String) async throws -> Int {
        let (site, email) = try validatedJira(site: siteText, email: emailText)
        let typed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token = typed.isEmpty
            ? Keychain.read(service: JiraCredentials.keychainService, account: email) : typed
        else { throw JiraSetupError(errorDescription: "Enter the API token.") }
        let source = JiraSource(credentials: JiraCredentials(site: site, email: email, token: token))
        do {
            return try await source.fetch().tickets.count
        } catch {
            throw JiraSetupError(errorDescription: SourceErrorMessage.text(for: error))
        }
    }

    func storedJiraToken(for email: String?) -> Bool {
        guard let email, !email.isEmpty else { return false }
        return Keychain.read(service: JiraCredentials.keychainService, account: email) != nil
    }

    private func validatedJira(site: String, email: String) throws -> (URL, String) {
        guard let url = JiraCredentials.site(from: site) else {
            throw JiraSetupError(errorDescription: "Enter the Jira site, e.g. acme.atlassian.net.")
        }
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.contains("@") else { throw JiraSetupError(errorDescription: "Enter your Jira e-mail.") }
        return (url, email)
    }

    // MARK: Launch at login

    private static let loginItemDefaultKey = "devpulse.loginItemDefaultApplied"

    /// "Launch at login" is on by default. It is applied once, the first time DevPulse runs from
    /// an Applications folder, so a build run from elsewhere never becomes a login item.
    private func applyLaunchAtLoginDefault() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.loginItemDefaultKey),
              AppLocation.isInstalled(bundleURL: Bundle.main.bundleURL, home: URL.homeDirectory)
        else { return }
        // Marked done only once it worked, so a failed registration is tried again next launch.
        if !settings.launchAtLogin || setLaunchAtLogin(true) {
            defaults.set(true, forKey: Self.loginItemDefaultKey)
        }
    }

    /// Registers or unregisters the login item; the setting changes only when that worked.
    @discardableResult
    func setLaunchAtLogin(_ on: Bool) -> Bool {
        defer { updateLaunchAtLoginStatus() }
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log.error("Launch at login not changed: \(error.localizedDescription, privacy: .public)")
            loginItemError = "Could not \(on ? "turn on" : "turn off") launch at login: \(error.localizedDescription)"
            return false
        }
        loginItemError = nil
        settings.launchAtLogin = on
        return true
    }

    func updateLaunchAtLoginStatus() {
        let status = SMAppService.mainApp.status
        launchesAtLogin = status == .enabled || status == .requiresApproval
        loginItemNeedsApproval = status == .requiresApproval
    }

    // MARK: Command line tool

    func updateCLIStatus() {
        cliStatus = CommandLineInstaller.status
    }

    /// Why the tool cannot be installed from where the app runs, or nil when it can.
    var cliInstallBlocker: String? {
        if case .failure(let error) = CLIInstall.canInstall(bundleURL: CommandLineInstaller.bundleURL) {
            return error.localizedDescription
        }
        return nil
    }

    func installCommandLineTool() {
        defer { updateCLIStatus() }
        switch CommandLineInstaller.install() {
        case .installed, .canceled: cliInstallError = nil
        case .failed(let message): cliInstallError = message
        }
    }

    // MARK: Sleep and screen lock

    private func observeSleepAndLock() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        observe(workspace, NSWorkspace.willSleepNotification) { $0.isAsleep = true }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.isAsleep = false }
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.isLocked = true }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.isLocked = false }
    }

    private func observe(
        _ center: NotificationCenter, _ name: Notification.Name, _ change: @escaping @MainActor (AppModel) -> Void
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                change(self)
                self.updatePause()
            }
        }
        observers.append((center, token))
    }

    private func updatePause() {
        let paused = isAsleep || isLocked
        guard paused != store.isPaused else { return }
        store.setPaused(paused)
        log.info("Fetching \(paused ? "paused" : "resumed", privacy: .public)")
        // Waking or unlocking fetches once right away (spec §2.3).
        if !paused { refreshAll() }
    }

    // MARK: Actions

    func open(_ target: OpenTarget) {
        opener.open(target)
    }

    func openSettings() {
        NSApp.activate()
        showSettingsWindow?()
    }

    func openSettings(_ tab: SettingsTab) {
        settingsTab = tab
        openSettings()
    }

    // MARK: Client messages

    private func handle(_ message: ClientMessage, from client: ClientID) {
        switch message {
        case .hello:
            break
        case .refresh:
            refreshAll()
        case .open(let kind, let id):
            if let target = OpenResolver.target(for: kind, id: id, in: snapshot) {
                open(target)
            } else {
                log.info("Nothing to open for \(kind.rawValue, privacy: .public) \(id, privacy: .public)")
            }
        case .openSettings:
            openSettings()
        case .upgrade where demoSnapshot != nil:
            let report = DemoSnapshot.upgradeReport
            server.send(.upgrade(phase: report.phase, progress: report.progress, message: report.message), to: client)
        case .upgrade:
            // Every client hears the phases: the requesting CLI, and open TUIs in their header.
            updates.runHeadless { [server] phase, progress, message in
                server.broadcast(.upgrade(phase: phase, progress: progress, message: message))
            }
        }
    }
}
