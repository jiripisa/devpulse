#if DEBUG
import AppKit
import SwiftUI

/// DEBUG demo only (`-DevPulseDemoOpen popover`): the popover's content in a plain window at its
/// real size, so a screenshot needs no click on the menu bar.
@MainActor
enum DemoPopoverWindow {
    private static var window: NSWindow?

    static func show(model: AppModel) {
        let content = NSHostingView(rootView: PopoverView(model: model))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: content.fittingSize),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = content
        window.isReleasedWhenClosed = false
        window.center()
        window.orderFrontRegardless()
        self.window = window
    }
}
#endif
