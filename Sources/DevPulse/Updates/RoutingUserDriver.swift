import DevPulseCore
import Foundation
import Sparkle

/// Sparkle's user driver: a thin adapter over `HeadlessSession`, which decides for each call
/// whether the standard dialogs get it (background updates ask first) or a headless
/// `devpulse upgrade` answers it and reports the phase instead.
@MainActor
final class RoutingUserDriver: NSObject, SPUUserDriver {
    /// Where reports go: the socket broadcast.
    var onReport: ((UpgradeReport) -> Void)?
    /// Starts a user-initiated check (`SPUUpdater.checkForUpdates`), which comes back here.
    var onStartCheck: (() -> Void)?
    /// A headless run started or ended.
    var onActiveChange: ((Bool) -> Void)?

    private let standard: SPUStandardUserDriver
    private var session = HeadlessSession()
    /// The standard "installing" window for a termination the app refused, with its retry.
    private var stalledInstall: (() -> Void)?

    init(standard: SPUStandardUserDriver) {
        self.standard = standard
    }

    var isActive: Bool { session.isActive }

    /// Feeds one event to the session and carries out its effects in order. `forward` passes
    /// the call to the standard driver; `reply` and `acknowledge` answer Sparkle directly.
    func handle(_ event: HeadlessSession.Event,
                forward: () -> Void = {},
                reply: (SPUUserUpdateChoice) -> Void = { _ in },
                acknowledge: () -> Void = {}) {
        let wasActive = session.isActive
        for effect in session.handle(event) {
            switch effect {
            case .report(let report): onReport?(report)
            case .forward: forward()
            case .reply(.install): reply(.install)
            case .reply(.dismiss): reply(.dismiss)
            case .acknowledge: acknowledge()
            case .startCheck: onStartCheck?()
            case .wake(let delay):
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(delay))
                    self?.handle(.wake)
                }
            case .showStalledInstall:
                stalledInstall?()
                stalledInstall = nil
            }
        }
        if session.isActive != wasActive { onActiveChange?(session.isActive) }
    }

    // MARK: SPUUserDriver

    func show(_ request: SPUUpdatePermissionRequest,
              reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        handle(.permissionRequest, forward: { standard.show(request, reply: reply) })
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        handle(.userInitiatedCheck, forward: {
            standard.showUserInitiatedUpdateCheck(cancellation: cancellation)
        })
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let offer = HeadlessSession.UpdateOffer(
            version: appcastItem.displayVersionString,
            infoURL: appcastItem.infoURL?.absoluteString,
            informationOnly: appcastItem.isInformationOnlyUpdate,
            alreadyInstalling: state.stage == .installing)
        handle(.updateFound(offer),
               forward: { standard.showUpdateFound(with: appcastItem, state: state, reply: reply) },
               reply: reply)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        handle(.detail, forward: { standard.showUpdateReleaseNotes(with: downloadData) })
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {
        handle(.detail, forward: {
            standard.showUpdateReleaseNotesFailedToDownloadWithError(error)
        })
    }

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        handle(.notFound,
               forward: {
                   standard.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
               },
               acknowledge: acknowledgement)
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        handle(.error(error.localizedDescription),
               forward: { standard.showUpdaterError(error, acknowledgement: acknowledgement) },
               acknowledge: acknowledgement)
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        handle(.downloadStarted, forward: {
            standard.showDownloadInitiated(cancellation: cancellation)
        })
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        handle(.expectedLength(expectedContentLength),
               forward: {
                   standard.showDownloadDidReceiveExpectedContentLength(expectedContentLength)
               })
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        handle(.received(length), forward: {
            standard.showDownloadDidReceiveData(ofLength: length)
        })
    }

    func showDownloadDidStartExtractingUpdate() {
        handle(.extracting, forward: { standard.showDownloadDidStartExtractingUpdate() })
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        handle(.detail, forward: { standard.showExtractionReceivedProgress(progress) })
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        handle(.readyToInstall, forward: {
            standard.showReady(toInstallAndRelaunch: reply)
        }, reply: reply)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        let show = { [standard] in
            standard.showInstallingUpdate(withApplicationTerminated: applicationTerminated,
                                          retryTerminatingApplication: retryTerminatingApplication)
        }
        // Kept for a headless run: shown only if the app refuses to quit (`showStalledInstall`).
        stalledInstall = applicationTerminated ? nil : show
        handle(.installing(applicationTerminated: applicationTerminated), forward: show)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool,
                                          acknowledgement: @escaping () -> Void) {
        handle(.installed,
               forward: {
                   standard.showUpdateInstalledAndRelaunched(relaunched,
                                                             acknowledgement: acknowledgement)
               },
               acknowledge: acknowledgement)
    }

    func showUpdateInFocus() {
        handle(.detail, forward: { standard.showUpdateInFocus() })
    }

    func dismissUpdateInstallation() {
        stalledInstall = nil
        handle(.dismissed, forward: { standard.dismissUpdateInstallation() })
    }
}
