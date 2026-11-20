import AppKit
import DevPulseCore

/// Opens what a click, a notification or a socket client points at: a web page, or the Ghostty
/// terminal of a Claude Code session.
@MainActor
final class Opener {
    /// Looks up a session in the current snapshot (for its working directory).
    private let session: (Int) -> ClaudeSession?

    init(session: @escaping (Int) -> ClaudeSession?) {
        self.session = session
    }

    func open(_ target: OpenTarget) {
        switch target {
        case .url(let url):
            NSWorkspace.shared.open(url)
        case .session(let pid):
            let cwd = session(pid)?.cwd ?? ""
            Task {
                let focused = await withCheckedContinuation { continuation in
                    GhosttyFocus.queue.async {
                        continuation.resume(returning: GhosttyFocus.focus(sessionPid: pid, cwd: cwd))
                    }
                }
                if !focused { GhosttyFocus.activateApp() }
            }
        }
    }
}
