import AppKit
import DevPulseCore
import SwiftUI

/// Click, then press a shortcut: it becomes the launcher hotkey. Esc cancels. Shortcuts the
/// launcher cannot use (no ⌘/⌥/⌃, Spotlight's) are refused with the reason.
struct HotkeyRecorder: View {
    @Binding var hotkey: Hotkey
    @State private var isRecording = false
    @State private var problem: String?
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Button(isRecording ? "Type a shortcut…" : hotkey.displayText) {
                isRecording ? stop() : start()
            }
            .monospaced(!isRecording)
            .help(isRecording ? "Press the new shortcut, or Esc to cancel" : "Click to change")
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        problem = nil
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { record(event) }
            return nil
        }
    }

    private func record(_ event: NSEvent) {
        let modifiers = HotkeyModifiers(event.modifierFlags)
        if event.keyCode == 53, modifiers.isEmpty {
            stop()
            return
        }
        let candidate = Hotkey(keyCode: Int(event.keyCode), modifiers: modifiers)
        if let reason = candidate.problem {
            problem = reason
            return
        }
        hotkey = candidate
        stop()
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }
}

private extension HotkeyModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.command) { insert(.command) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.control) { insert(.control) }
        if flags.contains(.shift) { insert(.shift) }
    }
}
