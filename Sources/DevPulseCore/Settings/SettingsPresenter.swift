import Foundation

/// Opens the Settings window and puts it in front of every other app's windows: from the
/// popover, and from a socket client while the terminal is the active app.
///
/// A menu bar app is never active on its own, and `NSApp.activate()` is only a request: macOS
/// turns it down when another app (the terminal running `devpulse`) is active and has not yielded.
/// The window then opened, or stayed, behind that app's windows. So after opening, the window
/// is brought to front itself (`bringToFront`, AppKit's `orderFrontRegardless`), which works
/// whether or not the app became active.
@MainActor
public final class SettingsPresenter<Window: AnyObject> {
    private let activate: @MainActor () -> Void
    private let bringToFront: @MainActor (Window) -> Void
    /// SwiftUI's `openSettings` action; only views have it, so one hands it over.
    private var openAction: (@MainActor () -> Void)?
    /// A request made before a view handed the action over.
    private var isPending = false
    private weak var window: Window?

    public init(activate: @escaping @MainActor () -> Void, bringToFront: @escaping @MainActor (Window) -> Void) {
        self.activate = activate
        self.bringToFront = bringToFront
    }

    public func setOpenAction(_ action: @escaping @MainActor () -> Void) {
        openAction = action
        if isPending {
            isPending = false
            open()
        }
    }

    public func request() {
        activate()
        if openAction == nil {
            isPending = true
        } else {
            open()
        }
    }

    /// The Settings view was placed in `window`: the first time it opens, or a new window after
    /// the old one closed. It only opens on request, so it goes to the front.
    public func windowAppeared(_ window: Window) {
        self.window = window
        bringToFront(window)
    }

    private func open() {
        openAction?()
        // An open window is only reordered by `openSettings`; a new one arrives in `windowAppeared`.
        if let window { bringToFront(window) }
    }
}
