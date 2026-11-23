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
    /// once the results are there, through the panel's own event dispatch, so the text field's
    /// real key handling runs. Nothing goes to the system or to another app.
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
                    if let event { panel.sendEvent(event) }
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
        default: return nil
        }
    }
    #endif

    func close() {
        guard let panel else { return }
        self.panel = nil
        panel.onClose = nil
        panel.orderOut(nil)
        // Released a turn later: a close may come from inside the panel's own key handling.
        DispatchQueue.main.async { panel.contentView = nil }
    }
}

private final class LauncherPanel: NSPanel {
    static let width = LauncherView.width
    var onClose: (() -> Void)?
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

    override func cancelOperation(_ sender: Any?) {
        onClose?()
    }

    func center(on screen: NSScreen?) {
        guard let area = screen?.visibleFrame else { return }
        let origin = NSPoint(x: area.midX - Self.width / 2, y: area.midY - frame.height / 2 + area.height * 0.15)
        setFrameOrigin(origin)
        top = frame.maxY
    }

    func setContentHeight(_ height: CGFloat) {
        let top = top ?? frame.maxY
        setFrame(NSRect(x: frame.minX, y: top - height, width: Self.width, height: height), display: true)
    }
}
