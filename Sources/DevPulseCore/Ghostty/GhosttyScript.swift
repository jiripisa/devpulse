import Foundation

/// The AppleScript that brings a Claude Code session's Ghostty terminal to the front.
///
/// Ghostty's `focus` command brings the terminal's window to the front but does not switch to
/// the terminal's tab (Ghostty 1.4.0), so a session in a background tab stayed hidden. The
/// script finds the window and tab that hold the terminal, activates the window, selects the
/// tab, then focuses the terminal (the right split within the tab).
public enum GhosttyScript {
    public static let bundleID = "com.mitchellh.ghostty"

    public static func focus(terminalID: String) -> String {
        let id = escaped(terminalID)
        return """
            tell application id "\(bundleID)"
                with timeout of 5 seconds
                    repeat with w in windows
                        repeat with t in tabs of w
                            if (count of (terminals of t whose id is "\(id)")) > 0 then
                                activate window w
                                select tab t
                                focus (first terminal of t whose id is "\(id)")
                                activate
                                return true
                            end if
                        end repeat
                    end repeat
                    focus (first terminal whose id is "\(id)")
                    activate
                    return true
                end timeout
            end tell
            """
    }

    /// The former script, for a Ghostty whose dictionary has no tabs: the window comes to the
    /// front, the tab stays as it is.
    public static func focusTerminalOnly(terminalID: String) -> String {
        """
        tell application id "\(bundleID)"
            with timeout of 5 seconds
                focus (first terminal whose id is "\(escaped(terminalID))")
                activate
            end timeout
        end tell
        """
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
