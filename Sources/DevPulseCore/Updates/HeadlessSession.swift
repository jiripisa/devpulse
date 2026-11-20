import Foundation

/// One phase report of a headless upgrade, as it goes out on the socket.
public struct UpgradeReport: Equatable, Sendable {
    public var phase: UpgradePhase
    public var progress: Double?
    public var message: String?

    public init(_ phase: UpgradePhase, progress: Double? = nil, message: String? = nil) {
        self.phase = phase
        self.progress = progress
        self.message = message
    }
}

/// `devpulse upgrade` as Sparkle's user driver sees it, without Sparkle types: the driver turns
/// each of its calls into an `Event`, and carries out the returned `Effect`s in order.
///
/// Modes, and what happens to the driver's calls in each:
/// - `off`: no headless run; every call goes to the standard dialogs (`forward`).
/// - `pending`: requested while Sparkle runs its own silent check (e.g. at launch). An update it
///   finds is adopted; any other call that shows a dialog is forwarded and fails the request as
///   busy; the end of that check is forwarded. Sparkle becoming idle starts the headless check;
///   after `pendingTimeout` the request fails.
/// - `running`: everything is answered here and nothing is forwarded, except the permission
///   question, which is the user's to answer.
/// - `relaunching`: `restarting` was reported and the app is about to quit; the rest of the
///   session is swallowed. If the app has not quit after `terminationGrace`, Sparkle's own
///   "installing" window takes over so the user can retry. A failure is still reported.
///
/// A dialog the standard driver has shown is never taken over: a request then fails as busy.
public struct HeadlessSession {
    public enum Mode: Equatable, Sendable { case off, pending, running, relaunching }

    /// What `SPUUpdater` says about itself.
    public struct SparkleState: Equatable, Sendable {
        /// `canCheckForUpdates`: also true while a dialog is up (the check brings it to focus).
        public var canCheck: Bool
        public var sessionInProgress: Bool

        public init(canCheck: Bool, sessionInProgress: Bool) {
            self.canCheck = canCheck
            self.sessionInProgress = sessionInProgress
        }

        var isIdle: Bool { canCheck && !sessionInProgress }
    }

    /// The parts of an appcast item and its state that decide the answer.
    public struct UpdateOffer: Equatable, Sendable {
        public var version: String
        public var infoURL: String?
        /// The feed only points to a page; Sparkle must not be told to install it.
        public var informationOnly: Bool
        /// Installing began in an earlier session; `install` relaunches right away.
        public var alreadyInstalling: Bool

        public init(version: String, infoURL: String? = nil, informationOnly: Bool = false,
                    alreadyInstalling: Bool = false) {
            self.version = version
            self.infoURL = infoURL
            self.informationOnly = informationOnly
            self.alreadyInstalling = alreadyInstalling
        }
    }

    public enum Event: Equatable, Sendable {
        /// `devpulse upgrade` asked for an update.
        case request(SparkleState)
        /// `canCheckForUpdates` changed.
        case sparkleChanged(SparkleState)
        /// A `wake(after:)` effect came due.
        case wake
        case permissionRequest
        case userInitiatedCheck
        case updateFound(UpdateOffer)
        /// Release notes, extraction progress, bringing the dialog to focus: shown only on top of
        /// a dialog that is already up.
        case detail
        case notFound
        case error(String)
        case downloadStarted
        case expectedLength(UInt64)
        case received(UInt64)
        case extracting
        case readyToInstall
        case installing(applicationTerminated: Bool)
        case installed
        case dismissed
    }

    public enum Choice: Equatable, Sendable { case install, dismiss }

    public enum Effect: Equatable, Sendable {
        /// Broadcast to the socket clients.
        case report(UpgradeReport)
        /// Pass the call on to the standard driver, with its reply or acknowledgement.
        case forward
        /// Answer Sparkle's question.
        case reply(Choice)
        /// Call Sparkle's acknowledgement handler.
        case acknowledge
        /// Start a user-initiated check (`checkForUpdates`), routed here.
        case startCheck
        /// Send `.wake` after this delay.
        case wake(after: TimeInterval)
        /// Show the standard "installing" window for the stalled termination, with its retry.
        case showStalledInstall
    }

    public static let pendingTimeout: TimeInterval = 60
    public static let terminationGrace: TimeInterval = 5
    public static let busyMessage = "An update is already in progress in DevPulse."
    public static let timeoutMessage = "Timed out waiting for DevPulse's update check."
    public static let canceledMessage = "The update was canceled."

    public private(set) var mode = Mode.off
    public var isActive: Bool { mode != .off }

    /// The standard driver shows a dialog in the current Sparkle session.
    private var standardShowsDialog = false
    /// For a client joining the run.
    private var lastReport: UpgradeReport?
    /// When the pending request times out, or when a refused termination gets the retry UI.
    private var deadline: Date?
    private var download = DownloadProgress()
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    private var isHeadless: Bool { mode == .running || mode == .relaunching }

    public mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .request(let sparkle):
            return request(sparkle)
        case .sparkleChanged(let sparkle):
            noteSessionEnded(sparkle)
            guard mode == .pending, sparkle.isIdle else { return [] }
            begin(.running)
            return [.startCheck]
        case .wake:
            return wake()
        case .permissionRequest:
            return isHeadless ? [.forward] : standardShows()
        case .userInitiatedCheck:
            return isHeadless ? [] : standardShows()
        case .updateFound(let offer):
            return updateFound(offer)
        case .detail:
            return isHeadless ? [] : [.forward]
        case .notFound:
            switch mode {
            case .running: return finish(.upToDate) + [.acknowledge]
            case .relaunching: return [.acknowledge]
            case .off, .pending: return standardShows()
            }
        case .error(let message):
            return isHeadless ? finish(.failed, message: message) + [.acknowledge] : standardShows()
        case .downloadStarted:
            switch mode {
            case .running: return report(.downloading)
            case .relaunching: return []
            case .off, .pending: return standardShows()
            }
        case .expectedLength(let length):
            guard isHeadless else { return [.forward] }
            return progress(download.expect(length))
        case .received(let length):
            guard isHeadless else { return [.forward] }
            return progress(download.receive(length))
        case .extracting:
            switch mode {
            case .running: return report(.installing)
            case .relaunching: return []
            case .off, .pending: return standardShows()
            }
        case .readyToInstall:
            switch mode {
            case .running: return relaunch() + [.reply(.install)]
            case .relaunching: return [.reply(.install)]
            case .off, .pending: return standardShows()
            }
        case .installing(let applicationTerminated):
            return installing(applicationTerminated: applicationTerminated)
        case .installed:
            guard isHeadless else { return [.forward] }
            end()
            return [.acknowledge]
        case .dismissed:
            switch mode {
            case .running:
                return finish(.failed, message: Self.canceledMessage)
            case .relaunching:
                end()
                return []
            case .off, .pending:
                standardShowsDialog = false
                return [.forward]
            }
        }
    }

    // MARK: Transitions

    private mutating func request(_ sparkle: SparkleState) -> [Effect] {
        if isActive {
            return lastReport.map { [.report($0)] } ?? []
        }
        noteSessionEnded(sparkle)
        if sparkle.isIdle {
            begin(.running)
            return report(.checking) + [.startCheck]
        }
        if standardShowsDialog {
            return [.report(UpgradeReport(.failed, message: Self.busyMessage))]
        }
        begin(.pending)
        deadline = now() + Self.pendingTimeout
        return report(.checking) + [.wake(after: Self.pendingTimeout)]
    }

    private mutating func updateFound(_ offer: UpdateOffer) -> [Effect] {
        switch mode {
        case .off:
            return standardShows()
        case .pending:
            // Nothing was shown yet and the user asked for the update: take it over.
            begin(.running)
        case .running, .relaunching:
            break
        }
        if offer.informationOnly {
            let page = offer.infoURL ?? "the DevPulse website"
            let message =
                "DevPulse \(offer.version) can't be installed automatically; get it from \(page)."
            return finish(.failed, message: message) + [.reply(.dismiss)]
        }
        let restart = offer.alreadyInstalling && mode == .running ? relaunch() : []
        return restart + [.reply(.install)]
    }

    private mutating func installing(applicationTerminated: Bool) -> [Effect] {
        switch mode {
        case .off, .pending:
            return standardShows()
        case .running, .relaunching:
            let restart = mode == .running ? relaunch() : []
            // Sparkle sent the quit event. Normally the app is gone long before the grace
            // period; if it is still here, termination was refused, and Sparkle's window offers
            // the retry. Showing that window at once would flash it on every update.
            guard !applicationTerminated else { return restart }
            deadline = now() + Self.terminationGrace
            return restart + [.wake(after: Self.terminationGrace)]
        }
    }

    private mutating func wake() -> [Effect] {
        guard let deadline else { return [] }
        // The sleep runs on the continuous clock, the deadline on the wall clock: a wake that
        // comes early sleeps the rest instead of leaving the session waiting for good.
        let left = deadline.timeIntervalSince(now())
        guard left <= 0 else { return [.wake(after: left)] }
        switch mode {
        case .pending:
            return finish(.failed, message: Self.timeoutMessage)
        case .relaunching:
            end()
            standardShowsDialog = true
            return [.showStalledInstall]
        case .off, .running:
            return []
        }
    }

    /// A call the standard driver shows a dialog for. A pending request fails: that dialog
    /// is the user's now.
    private mutating func standardShows() -> [Effect] {
        standardShowsDialog = true
        guard mode == .pending else { return [.forward] }
        return [.forward] + finish(.failed, message: Self.busyMessage)
    }

    private mutating func progress(_ fraction: Double?) -> [Effect] {
        guard mode == .running, let fraction else { return [] }
        return report(.downloading, progress: fraction)
    }

    private mutating func noteSessionEnded(_ sparkle: SparkleState) {
        if !sparkle.sessionInProgress { standardShowsDialog = false }
    }

    private mutating func begin(_ mode: Mode) {
        self.mode = mode
        deadline = nil
        download = DownloadProgress()
    }

    private mutating func relaunch() -> [Effect] {
        let effects = report(.restarting)
        mode = .relaunching
        return effects
    }

    /// Reports a final phase and hands later sessions back to the standard dialogs.
    private mutating func finish(_ phase: UpgradePhase, message: String? = nil) -> [Effect] {
        let effects = report(phase, message: message)
        end()
        return effects
    }

    private mutating func end() {
        mode = .off
        deadline = nil
    }

    private mutating func report(_ phase: UpgradePhase, progress: Double? = nil,
                                 message: String? = nil) -> [Effect] {
        let report = UpgradeReport(phase, progress: progress, message: message)
        lastReport = report
        return [.report(report)]
    }
}
