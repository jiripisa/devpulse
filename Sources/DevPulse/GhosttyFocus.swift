// Focusing the Ghostty terminal of a Claude Code session.
//
// Finding (Ghostty 1.4.0, checked 2026-11-19 with `sdef /Applications/Ghostty.app`): Ghostty
// ships a scripting dictionary ("Ghostty Scripting Dictionary"). The application has `window`,
// `tab` and `terminal` elements; every `terminal` (one surface, i.e. a tab or a split) exposes
// `id` (stable), `tty` (e.g. `/dev/ttys006`), `pid` (the foreground process) and
// `working directory`, and responds to `focus` ("Focus a terminal, bringing its window to the
// front"). `get {id, tty, pid, working directory} of every terminal` lists them all in one
// Apple Event; `whose` clauses work.
//
// A session is matched by the tty of its pid (sysctl, as `ps -o tty=`), then by the terminal's
// foreground pid (claude itself), then by a working directory only one terminal has
// (`GhosttyMatch` in the core). The match is focused, then Ghostty is activated. When nothing
// matches, the caller activates Ghostty (`com.mitchellh.ghostty`) as a fallback.
//
// Apple Events need `NSAppleEventsUsageDescription` in Info.plist and, under the hardened
// runtime, the `com.apple.security.automation.apple-events` entitlement; macOS asks the user
// once ("DevPulse wants to control Ghostty"). That consent is settled first with
// `AEDeterminePermissionToAutomateTarget`, which waits for the user's answer, so the scripts'
// 5-second timeout never cuts the prompt off.

import AppKit
import DevPulseCore
import os

enum GhosttyFocus {
    static let bundleID = "com.mitchellh.ghostty"

    /// Apple Events block until Ghostty answers (or the user answers the consent prompt), so they
    /// run here, never on the main thread. One queue keeps the scripts serialized.
    static let queue = DispatchQueue(label: "io.jp4.devpulse.ghostty")

    private static let log = Logger(subsystem: "io.jp4.devpulse", category: "ghostty")

    /// Focuses the terminal that runs the session; false when Ghostty is not running, does not
    /// answer, or no terminal matches for sure. Blocking: call it on `queue`.
    static func focus(sessionPid: Int, cwd: String) -> Bool {
        guard isRunning, mayAutomate() else { return false }
        guard let terminals = listTerminals() else { return false }
        let tty = ProcessTTY.path(of: sessionPid)
        guard let id = GhosttyMatch.terminalID(in: terminals, tty: tty, pid: sessionPid, cwd: cwd) else {
            log.info("No Ghostty terminal matches session \(sessionPid, privacy: .public) (\(terminals.count, privacy: .public) terminals)")
            return false
        }
        let script = """
            tell application id "\(bundleID)"
                with timeout of 5 seconds
                    focus (first terminal whose id is "\(escaped(id))")
                    activate
                end timeout
            end tell
            """
        return run(script) != nil
    }

    /// The fallback: brings Ghostty to the front, but never launches it.
    @MainActor
    static func activateApp() {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.activate()
    }

    /// Asks for (or reads) the user's consent to control Ghostty; blocks while the system
    /// prompt is shown.
    private static func mayAutomate() -> Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let address = target.aeDesc else { return false }
        let status = AEDeterminePermissionToAutomateTarget(
            address, AEEventClass(typeWildCard), AEEventID(typeWildCard), true)
        guard status == noErr else {
            log.info("Not allowed to control Ghostty (OSStatus \(status, privacy: .public))")
            return false
        }
        return true
    }

    private static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    private static func listTerminals() -> [GhosttyTerminal]? {
        let script = """
            tell application id "\(bundleID)"
                with timeout of 5 seconds
                    get {id, tty, pid, working directory} of every terminal
                end timeout
            end tell
            """
        guard let result = run(script), result.numberOfItems == 4,
              let ids = result.atIndex(1), let ttys = result.atIndex(2),
              let pids = result.atIndex(3), let directories = result.atIndex(4)
        else { return nil }
        guard ids.numberOfItems > 0 else { return [] }
        return (1...ids.numberOfItems).compactMap { index in
            guard let id = ids.atIndex(index)?.stringValue else { return nil }
            let pid = pids.atIndex(index).map { Int($0.int32Value) }
            return GhosttyTerminal(
                id: id, tty: ttys.atIndex(index)?.stringValue, pid: pid == 0 ? nil : pid,
                workingDirectory: directories.atIndex(index)?.stringValue)
        }
    }

    private static func run(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let number = error[NSAppleScript.errorNumber] as? Int ?? 0
            let message = error[NSAppleScript.errorMessage] as? String ?? "unknown"
            log.error("Ghostty script failed (\(number, privacy: .public)): \(message, privacy: .public)")
            return nil
        }
        return result
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
