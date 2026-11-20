import Foundation
import Testing
@testable import DevPulseCore

/// A clock the test moves by hand.
private final class TestClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 0)
}

@Suite("HeadlessSession")
struct HeadlessSessionTests {
    typealias Session = HeadlessSession

    private static let idle = Session.SparkleState(canCheck: true, sessionInProgress: false)
    /// Sparkle's silent check at launch: downloading the feed, nothing shown.
    private static let probing = Session.SparkleState(canCheck: false, sessionInProgress: true)
    /// An update dialog is up: Sparkle lets the user bring it to focus.
    private static let showing = Session.SparkleState(canCheck: true, sessionInProgress: true)
    private static let offer = Session.UpdateOffer(version: "0.1.1")

    private let clock = TestClock()

    private func session() -> Session {
        let clock = clock
        return Session(now: { clock.now })
    }

    private func report(_ phase: UpgradePhase, _ progress: Double? = nil,
                        _ message: String? = nil) -> Session.Effect {
        .report(UpgradeReport(phase, progress: progress, message: message))
    }

    /// A session with a headless check started from an idle Sparkle.
    private func running() -> Session {
        var s = session()
        _ = s.handle(.request(Self.idle))
        return s
    }

    // MARK: Starting

    @Test("A request while Sparkle is idle reports checking and starts the check")
    func startsWhenIdle() {
        var s = session()
        #expect(s.handle(.request(Self.idle)) == [report(.checking), .startCheck])
        #expect(s.mode == .running)
        #expect(s.isActive)
    }

    @Test("A full update: install, progress, installing, restart, then the app quits")
    func fullUpdate() {
        var s = running()
        #expect(s.handle(.userInitiatedCheck) == [])
        #expect(s.handle(.updateFound(Self.offer)) == [.reply(.install)])
        #expect(s.handle(.detail) == [])
        #expect(s.handle(.downloadStarted) == [report(.downloading)])
        #expect(s.handle(.expectedLength(1000)) == [report(.downloading, 0)])
        #expect(s.handle(.received(5)) == [])
        #expect(s.handle(.received(415)) == [report(.downloading, 0.42)])
        #expect(s.handle(.extracting) == [report(.installing)])
        #expect(s.handle(.detail) == [])
        #expect(s.handle(.readyToInstall) == [report(.restarting), .reply(.install)])
        #expect(s.mode == .relaunching)
        #expect(s.handle(.installing(applicationTerminated: true)) == [])
        #expect(s.handle(.installed) == [.acknowledge])
        #expect(s.mode == .off)
    }

    @Test("No update ends the run as up to date; later sessions get the standard dialogs")
    func upToDateHandsBack() {
        var s = running()
        #expect(s.handle(.notFound) == [report(.upToDate), .acknowledge])
        #expect(s.mode == .off)
        #expect(s.handle(.dismissed) == [.forward])
        #expect(s.handle(.updateFound(Self.offer)) == [.forward])
    }

    @Test("An error ends the run as failed with its text")
    func errorFails() {
        var s = running()
        #expect(s.handle(.error("The feed could not be loaded."))
            == [report(.failed, nil, "The feed could not be loaded."), .acknowledge])
        #expect(s.mode == .off)
    }

    @Test("A session dismissed without a final phase fails as canceled")
    func dismissedWithoutFinalPhase() {
        var s = running()
        _ = s.handle(.updateFound(Self.offer))
        #expect(s.handle(.dismissed) == [report(.failed, nil, Session.canceledMessage)])
        #expect(s.mode == .off)
    }

    @Test("An information-only update fails and is dismissed, never installed")
    func informationOnly() {
        var s = running()
        let offer = Session.UpdateOffer(version: "0.2.0", infoURL: "https://example.com/devpulse",
                                        informationOnly: true)
        #expect(s.handle(.updateFound(offer)) == [
            report(.failed, nil,
                   "DevPulse 0.2.0 can't be installed automatically; get it from "
                       + "https://example.com/devpulse."),
            .reply(.dismiss),
        ])
        #expect(s.mode == .off)
    }

    @Test("An update already installing reports restarting before install relaunches it")
    func alreadyInstalling() {
        var s = running()
        let offer = Session.UpdateOffer(version: "0.1.1", alreadyInstalling: true)
        #expect(s.handle(.updateFound(offer)) == [report(.restarting), .reply(.install)])
        #expect(s.mode == .relaunching)
    }

    // MARK: Joining

    @Test("A second request joins: the current phase is reported again, nothing restarts")
    func joinReplays() {
        var s = running()
        _ = s.handle(.updateFound(Self.offer))
        _ = s.handle(.expectedLength(100))
        _ = s.handle(.received(42))
        #expect(s.handle(.request(Self.showing)) == [report(.downloading, 0.42)])
        _ = s.handle(.readyToInstall)
        #expect(s.handle(.request(Self.idle)) == [report(.restarting)])
        #expect(s.mode == .relaunching)
    }

    // MARK: After restarting

    @Test("A failure after restarting is reported and hands back to the standard dialogs")
    func errorAfterRestarting() {
        var s = running()
        _ = s.handle(.readyToInstall)
        #expect(s.handle(.error("Installation failed"))
            == [report(.failed, nil, "Installation failed"), .acknowledge])
        #expect(s.mode == .off)
    }

    @Test("While relaunching, a dismiss ends the session silently")
    func dismissWhileRelaunching() {
        var s = running()
        _ = s.handle(.readyToInstall)
        #expect(s.handle(.dismissed) == [])
        #expect(s.mode == .off)
    }

    @Test("A refused termination shows Sparkle's retry UI after the grace period")
    func stalledTermination() {
        var s = running()
        _ = s.handle(.readyToInstall)
        #expect(s.handle(.installing(applicationTerminated: false))
            == [.wake(after: Session.terminationGrace)])
        // A wake that comes early (the sleep and the wall clock disagree) sleeps the rest.
        clock.now += Session.terminationGrace - 1
        #expect(s.handle(.wake) == [.wake(after: 1)])
        #expect(s.mode == .relaunching)
        clock.now += 1
        #expect(s.handle(.wake) == [.showStalledInstall])
        #expect(s.mode == .off)
        // The standard driver now owns the rest of the session, including its teardown.
        #expect(s.handle(.dismissed) == [.forward])
    }

    // MARK: Sparkle busy

    @Test("A dialog already shown is never taken over")
    func shownDialogRefuses() {
        var s = session()
        #expect(s.handle(.updateFound(Self.offer)) == [.forward])
        #expect(s.handle(.request(Self.showing)) == [report(.failed, nil, Session.busyMessage)])
        #expect(s.mode == .off)
        #expect(s.handle(.readyToInstall) == [.forward])
        #expect(s.handle(.dismissed) == [.forward])
    }

    @Test("Cold start: a request during the silent launch check waits, then starts")
    func coldStartWaits() {
        var s = session()
        #expect(s.handle(.request(Self.probing))
            == [report(.checking), .wake(after: Session.pendingTimeout)])
        #expect(s.mode == .pending)
        #expect(s.isActive)
        #expect(s.handle(.sparkleChanged(Self.probing)) == [])
        #expect(s.handle(.sparkleChanged(Self.idle)) == [.startCheck])
        #expect(s.mode == .running)
        // The wake scheduled for the wait finds nothing to time out.
        clock.now += Session.pendingTimeout
        #expect(s.handle(.wake) == [])
        #expect(s.handle(.notFound) == [report(.upToDate), .acknowledge])
    }

    @Test("A pending request adopts the update the silent check found")
    func pendingAdopts() {
        var s = session()
        _ = s.handle(.request(Self.probing))
        #expect(s.handle(.updateFound(Self.offer)) == [.reply(.install)])
        #expect(s.mode == .running)
        #expect(s.handle(.downloadStarted) == [report(.downloading)])
    }

    @Test("A pending request times out after 60 s")
    func pendingTimesOut() {
        var s = session()
        _ = s.handle(.request(Self.probing))
        clock.now += Session.pendingTimeout - 1
        #expect(s.handle(.wake) == [.wake(after: 1)])
        #expect(s.mode == .pending)
        clock.now += 1
        #expect(s.handle(.wake) == [report(.failed, nil, Session.timeoutMessage)])
        #expect(s.mode == .off)
    }

    @Test("A pending request fails as busy once the standard driver shows a dialog")
    func pendingFailsWhenDialogShows() {
        var s = session()
        _ = s.handle(.request(Self.probing))
        #expect(s.handle(.permissionRequest)
            == [.forward, report(.failed, nil, Session.busyMessage)])
        #expect(s.mode == .off)
    }

    @Test("A pending request forwards the end of the silent check")
    func pendingForwardsDismiss() {
        var s = session()
        _ = s.handle(.request(Self.probing))
        #expect(s.handle(.dismissed) == [.forward])
        #expect(s.mode == .pending)
    }

    @Test("A dismissed dialog is no longer in the way")
    func dismissClearsShownDialog() {
        var s = session()
        _ = s.handle(.updateFound(Self.offer))
        _ = s.handle(.dismissed)
        #expect(s.handle(.request(Self.probing))
            == [report(.checking), .wake(after: Session.pendingTimeout)])
    }

    @Test("Sparkle with no session forgets a dialog it never dismissed")
    func noSessionClearsShownDialog() {
        var s = session()
        _ = s.handle(.updateFound(Self.offer))
        #expect(s.handle(.request(Self.idle)) == [report(.checking), .startCheck])
    }

    // MARK: Routing

    @Test("Without a headless run every call goes to the standard driver")
    func offForwards() {
        var s = session()
        let events: [Session.Event] = [
            .permissionRequest, .userInitiatedCheck, .detail, .notFound, .error("x"),
            .downloadStarted, .expectedLength(10), .received(1), .extracting, .readyToInstall,
            .installing(applicationTerminated: false), .installed, .dismissed,
        ]
        for event in events {
            #expect(s.handle(event) == [.forward], "\(event)")
        }
        #expect(s.handle(.wake) == [])
    }

    @Test("A headless run still forwards the permission question; it is the user's to answer")
    func permissionAlwaysForwarded() {
        var s = running()
        #expect(s.handle(.permissionRequest) == [.forward])
        #expect(s.mode == .running)
    }
}
