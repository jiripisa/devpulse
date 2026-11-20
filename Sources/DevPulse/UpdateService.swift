import AppKit
import DevPulseCore
import Foundation
import Observation
import os
import Sparkle

/// Auto-update on Sparkle: the feed and the EdDSA public key come from
/// Info.plist (`SUFeedURL`, `SUPublicEDKey`). Every launch asks the feed
/// for a newer version; Sparkle's standard dialog offers it and installs
/// only after the user agrees. `devpulse upgrade` installs without a dialog
/// (`runHeadless`).
@MainActor
@Observable
final class UpdateService {

    @ObservationIgnored private let updater: SPUUpdater
    @ObservationIgnored private let userDriver: RoutingUserDriver
    /// The standard driver holds its delegate weakly.
    @ObservationIgnored private let reminders = ScheduledUpdateReminders()
    /// Why Sparkle did not start (e.g. a broken feed setting); `runHeadless` reports it.
    @ObservationIgnored private var startError: String?
    /// Sparkle's `canCheckForUpdates`.
    private var sparkleCanCheck = false
    /// A `devpulse upgrade` runs or waits for Sparkle.
    private(set) var isUpgrading = false
    /// "Check for Updates…" is enabled: Sparkle can check, and no headless run would swallow it.
    var canCheck: Bool { sparkleCanCheck && !isUpgrading }
    /// Settings › Updates; Sparkle keeps the value in its own defaults.
    var automaticallyChecks: Bool {
        didSet { updater.automaticallyChecksForUpdates = automaticallyChecks }
    }
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?
    @ObservationIgnored private let log = Logger(subsystem: "io.jp4.devpulse", category: "updates")

    /// `disabledReason` (the demo) keeps Sparkle from starting, so it neither checks at launch
    /// nor on its schedule; `runHeadless` reports the reason.
    init(disabledReason: String? = nil) {
        let standard = SPUStandardUserDriver(hostBundle: .main, delegate: reminders)
        userDriver = RoutingUserDriver(standard: standard)
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main,
                             userDriver: userDriver, delegate: nil)
        automaticallyChecks = updater.automaticallyChecksForUpdates
        userDriver.onStartCheck = { [weak self] in self?.updater.checkForUpdates() }
        userDriver.onActiveChange = { [weak self] in self?.isUpgrading = $0 }
        if let disabledReason {
            startError = disabledReason
        } else {
            do {
                try updater.start()
            } catch {
                startError = error.localizedDescription
                log.error("Sparkle not started: \(error.localizedDescription, privacy: .public)")
            }
        }
        sparkleCanCheck = updater.canCheckForUpdates
        canCheckObservation = updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.sparkleCanCheck = self.updater.canCheckForUpdates
                // A `devpulse upgrade` waiting for Sparkle's own check starts once it is done.
                self.userDriver.handle(.sparkleChanged(self.sparkleState))
            }
        }
        // "At launch", not Sparkle's daily schedule: ask now when enabled.
        if startError == nil, updater.automaticallyChecksForUpdates {
            updater.checkForUpdatesInBackground()
        }
    }

    private var sparkleState: HeadlessSession.SparkleState {
        .init(canCheck: updater.canCheckForUpdates, sessionInProgress: updater.sessionInProgress)
    }

    /// "Check for Updates…": always shows a result, also "you're up to date".
    func checkNow() {
        updater.checkForUpdates()
    }

    /// `devpulse upgrade`: checks, downloads, installs and relaunches without a dialog,
    /// reporting each phase (the caller broadcasts them to every client). A request while one
    /// runs joins it; one during Sparkle's own silent check waits for it; a dialog the user
    /// already sees is never taken over (see `HeadlessSession`).
    func runHeadless(report: @escaping (UpgradePhase, Double?, String?) -> Void) {
        userDriver.onReport = { report($0.phase, $0.progress, $0.message) }
        if let startError, !userDriver.isActive {
            return report(.failed, nil, startError)
        }
        userDriver.handle(.request(sparkleState))
    }
}

/// Sparkle's gentle reminders for an app without a Dock icon: a scheduled update found while
/// DevPulse is in the background brings the app forward, so the standard dialog is not hidden
/// behind other apps.
private final class ScheduledUpdateReminders: NSObject, SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                   forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        guard handleShowingUpdate, !state.userInitiated else { return }
        MainActor.assumeIsolated { NSApp.activate() }
    }
}
