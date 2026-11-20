#if DEBUG
import AppKit
import SwiftUI

/// DEBUG demo only (`-DevPulseDemoOpen popover`): the popover's content in a plain window at its
/// real width, so a screenshot needs no click on the menu bar. It is as tall as its lists, so the
/// screenshot shows every row instead of a cut-off scroll area.
@MainActor
enum DemoPopoverWindow {
    private static var window: NSWindow?

    static func show(model: AppModel) {
        let content = NSHostingView(rootView: PopoverView(model: model, maxListHeight: .infinity))
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
