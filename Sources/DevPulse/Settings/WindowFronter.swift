import AppKit
import os

/// Puts a window in front of other apps' windows once it is on screen, even when macOS did not
/// activate the app (see `SettingsPresenter`). SwiftUI shows a new window a moment after placing
/// its view, so this waits for the window to report that it became visible (an update,
/// occlusion change or becoming key) for up to 2 s, and logs when it gives up. A window closed
/// in the meantime is not brought back.
@MainActor
final class WindowFronter {
    private static let log = Logger(subsystem: "io.jp4.devpulse", category: "app")
    private static let limit: Duration = .seconds(2)
    private static let signals = [
        NSWindow.didUpdateNotification, NSWindow.didChangeOcclusionStateNotification,
        NSWindow.didBecomeKeyNotification,
    ]

    private weak var window: NSWindow?
    private var observers: [any NSObjectProtocol] = []
    private var timeout: Task<Void, Never>?

    static func bringToFront(_ window: NSWindow) {
        if window.isVisible {
            front(window)
            return
        }
        WindowFronter(window).start()
    }

    private init(_ window: NSWindow) {
        self.window = window
    }

    /// The observers and the timeout keep this alive until one of them finishes it.
    private func start() {
        observers = Self.signals.map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { self.check() }
            }
        }
        timeout = Task {
            try? await Task.sleep(for: Self.limit)
            guard !Task.isCancelled else { return }
            self.giveUp()
        }
    }

    private func check() {
        guard let window, window.isVisible else { return }
        finish()
        Self.front(window)
    }

    private func giveUp() {
        finish()
        if let window {
            Self.log.error(
                "Settings window did not become visible within 2 s, not brought to front (\(window.title, privacy: .public))")
        }
    }

    private func finish() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        timeout?.cancel()
        timeout = nil
    }

    private static func front(_ window: NSWindow) {
        window.orderFrontRegardless()
        window.makeKey()
    }
}
