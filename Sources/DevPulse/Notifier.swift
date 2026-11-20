import DevPulseCore
import Observation
import os
import UserNotifications

/// Posts the change detector's events as macOS notifications. A click hands the event's target
/// to `onOpen`; notifications also show while DevPulse is the active app.
@MainActor
@Observable
final class Notifier: NSObject {
    /// Nil until the system has answered; Settings shows a hint when notifications are denied.
    private(set) var authorization: UNAuthorizationStatus?
    @ObservationIgnored var onOpen: ((OpenTarget) -> Void)?

    @ObservationIgnored private let center = UNUserNotificationCenter.current()
    @ObservationIgnored private let log = Logger(subsystem: "io.jp4.devpulse", category: "notify")

    override init() {
        super.init()
        // Set early, so a click that launched the app is delivered too.
        center.delegate = self
    }

    /// The system asks only the first time; later calls just report the current answer.
    func requestPermission() {
        Task {
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                log.info("Notifications \(granted ? "allowed" : "not allowed", privacy: .public)")
            } catch {
                log.error("Notification permission failed: \(error.localizedDescription, privacy: .public)")
            }
            await updateAuthorization()
        }
    }

    func updateAuthorization() async {
        authorization = await center.notificationSettings().authorizationStatus
    }

    func post(_ events: [NotificationEvent]) {
        for event in events {
            let content = UNMutableNotificationContent()
            content.title = event.title
            content.body = event.body
            content.sound = .default
            content.threadIdentifier = event.trigger.source.rawValue
            content.userInfo = event.target.userInfo
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            let log = self.log
            let trigger = event.trigger.rawValue
            center.add(request) { error in
                if let error {
                    log.error("Notification \(trigger, privacy: .public) not posted: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        log.info("Posted \(events.count, privacy: .public) notification(s)")
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let target = OpenTarget(userInfo: response.notification.request.content.userInfo)
        else { return }
        await MainActor.run { onOpen?(target) }
    }
}
