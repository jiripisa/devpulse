import Carbon.HIToolbox
import DevPulseCore

/// A global hotkey through Carbon's `RegisterEventHotKey`; it needs no Accessibility permission.
@MainActor
final class HotkeyMonitor {
    private let onPress: () -> Void
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    /// The result of the last registration: `noErr` or why it failed.
    private(set) var status: OSStatus = noErr

    init(hotkey: Hotkey, onPress: @escaping () -> Void) {
        self.onPress = onPress
        installHandler()
        register(hotkey)
    }

    isolated deinit {
        unregister()
        if let handler { RemoveEventHandler(handler) }
    }

    /// Replaces the registered shortcut; `status` tells whether it worked (`eventHotKeyExistsErr`
    /// when another app holds the combination).
    func register(_ hotkey: Hotkey) {
        unregister()
        let id = EventHotKeyID(signature: OSType(0x4450_4C48), id: 1)  // 'DPLH'
        status = RegisterEventHotKey(
            UInt32(hotkey.keyCode), Self.carbonModifiers(hotkey.modifiers), id,
            GetApplicationEventTarget(), 0, &hotKey)
    }

    private func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }

    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userData).takeUnretainedValue()
                // The application event target delivers on the main thread.
                MainActor.assumeIsolated { monitor.onPress() }
                return noErr
            },
            1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    static func carbonModifiers(_ modifiers: HotkeyModifiers) -> UInt32 {
        var flags = 0
        if modifiers.contains(.command) { flags |= cmdKey }
        if modifiers.contains(.option) { flags |= optionKey }
        if modifiers.contains(.control) { flags |= controlKey }
        if modifiers.contains(.shift) { flags |= shiftKey }
        return UInt32(flags)
    }
}
