import AppKit
import DevPulseCore
import SwiftUI

/// The floating search panel. It never activates the app but takes the keyboard, so typing
/// works while the app the user came from stays frontmost. Created on demand, released on close.
@MainActor
final class LauncherPanelController {
    private let model: AppModel
    private var panel: LauncherPanel?

    init(model: AppModel) {
        self.model = model
    }

    func toggle() {
        panel == nil ? show() : close()
    }

    /// Opens the panel with `query` typed in and row `select` selected (the demo's
    /// screenshots; empty and nil otherwise).
    func show(query: String = "", select: Int? = nil) {
        guard panel == nil else { return }
        let panel = LauncherPanel()
        panel.onClose = { [weak self] in self?.close() }
        panel.contentView = NSHostingView(rootView: LauncherView(
            model: model,
            query: query,
            select: select,
            keys: panel.keys,
            onOpen: { [weak self] target in
                self?.close()
                self?.model.open(target)
            },
            onClose: { [weak self] in self?.close() },
            onHeight: { [weak panel] height in panel?.setContentHeight(height) }))
        panel.setContentHeight(LauncherView.height(showsContent: false))
        panel.center(on: NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        #if DEBUG
        playDemoKeys(into: panel)
        #endif
    }

    #if DEBUG
    /// `-DevPulseDemoKeys tab,down,…` (DEBUG demo only): presses these keys inside this panel
    /// once the results are there, through the app's own event dispatch to its key window (this
    /// panel), so the real key handling runs. Nothing goes to the system or to another app.
    private func playDemoKeys(into panel: NSPanel) {
        guard let list = UserDefaults.standard.string(forKey: "DevPulseDemoKeys") else { return }
        let keys = list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak panel] in
            guard let panel else { return }
            for name in keys {
                guard let key = Self.demoKey(name) else { fatalError("-DevPulseDemoKeys: no key \(name)") }
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    let event = NSEvent.keyEvent(
                        with: type, location: .zero, modifierFlags: key.flags, timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: panel.windowNumber, context: nil, characters: key.characters,
                        charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.code)
                    // Through the app, as typing comes: ⌘ keys go to `performKeyEquivalent` first.
                    if let event { NSApp.sendEvent(event) }
                }
            }
        }
    }

    private static func demoKey(_ name: String) -> (code: UInt16, characters: String, flags: NSEvent.ModifierFlags)? {
        func function(_ value: Int) -> String { String(Character(UnicodeScalar(value)!)) }
        switch name {
        case "tab": return (48, "\t", [])
        case "backtab": return (48, "\u{19}", [.shift])
        case "down": return (125, function(NSDownArrowFunctionKey), [.numericPad, .function])
        case "up": return (126, function(NSUpArrowFunctionKey), [.numericPad, .function])
        case "left": return (123, function(NSLeftArrowFunctionKey), [.numericPad, .function])
        case "right": return (124, function(NSRightArrowFunctionKey), [.numericPad, .function])
        // What a Czech layout types on the keys 1 2 3, so the demo checks the key position.
        case "cmd1": return (18, "+", [.command])
        case "cmd2": return (19, "ě", [.command])
        case "cmd3": return (20, "š", [.command])
        default: return nil
        }
    }
    #endif

    func close() {
        guard let panel else { return }
        self.panel = nil
        panel.onClose = nil
        // The view's closure holds the view, which holds `keys`: a cycle until it goes.
        panel.keys.onFilter = nil
        panel.orderOut(nil)
        // Released a turn later: a close may come from inside the panel's own key handling.
        DispatchQueue.main.async { panel.contentView = nil }
    }
}

private final class LauncherPanel: NSPanel {
    static let width = LauncherView.width
    var onClose: (() -> Void)?
    let keys = LauncherKeys()
    /// The top edge stays where it is while the list grows and shrinks.
    private var top: CGFloat?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 60),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .floating
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        onClose?()
    }

    /// ⌘1–⌘3 by key position, before the search field: on a Czech layout those keys type + ě š
    /// even with ⌘, so the field never sees a 1, 2 or 3.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        if flags == .command, let filter = LauncherFilter(numberKeyCode: event.keyCode), let onFilter = keys.onFilter {
            onFilter(filter)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onClose?()
    }

    /// Above the middle like Spotlight, but so that the panel, once grown, still fits.
    func center(on screen: NSScreen?) {
        guard let area = screen?.visibleFrame else { return }
        let top = LauncherPlacement.top(
            in: area, barHeight: LauncherView.height(showsContent: false),
            fullHeight: LauncherView.height(showsContent: true))
        setFrameOrigin(NSPoint(x: area.midX - Self.width / 2, y: top - frame.height))
        self.top = top
    }

    func setContentHeight(_ height: CGFloat) {
        let top = top ?? frame.maxY
        setFrame(NSRect(x: frame.minX, y: top - height, width: Self.width, height: height), display: true)
    }
}
