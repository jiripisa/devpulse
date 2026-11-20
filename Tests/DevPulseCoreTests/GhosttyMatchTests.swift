import Foundation
import Testing
@testable import DevPulseCore

private func terminal(_ id: String, tty: String? = nil, pid: Int? = nil, cwd: String? = nil) -> GhosttyTerminal {
    GhosttyTerminal(id: id, tty: tty, pid: pid, workingDirectory: cwd)
}

@Suite struct GhosttyMatchTests {
    private let terminals = [
        terminal("A", tty: "/dev/ttys001", pid: 100, cwd: "/Users/me/main"),
        terminal("B", tty: "/dev/ttys002", pid: 200, cwd: "/Users/me/main"),
        terminal("C", tty: "/dev/ttys003", pid: 300, cwd: "/Users/me/feature"),
    ]

    @Test func ttyWins() {
        #expect(GhosttyMatch.terminalID(in: terminals, tty: "/dev/ttys002", pid: 300, cwd: "/Users/me/feature") == "B")
    }

    @Test func foregroundPidIsNext() {
        #expect(GhosttyMatch.terminalID(in: terminals, tty: nil, pid: 300, cwd: "/elsewhere") == "C")
        #expect(GhosttyMatch.terminalID(in: terminals, tty: "/dev/ttys999", pid: 100, cwd: "/elsewhere") == "A")
    }

    @Test func uniqueWorkingDirectoryIsLast() {
        #expect(GhosttyMatch.terminalID(in: terminals, tty: nil, pid: 1, cwd: "/Users/me/feature/") == "C")
    }

    @Test func ambiguousWorkingDirectoryIsNil() {
        #expect(GhosttyMatch.terminalID(in: terminals, tty: nil, pid: 1, cwd: "/Users/me/main") == nil)
    }

    @Test func nothingMatches() {
        #expect(GhosttyMatch.terminalID(in: terminals, tty: nil, pid: 1, cwd: "") == nil)
        #expect(GhosttyMatch.terminalID(in: [], tty: "/dev/ttys001", pid: 100, cwd: "/Users/me/main") == nil)
    }
}

@Suite struct ProcessTTYTests {
    @Test func missingProcessHasNoTTY() {
        #expect(ProcessTTY.path(of: 999_999) == nil)
    }

    @Test func agreesWithPs() throws {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "tty=", "-p", "\(getpid())"]
        let pipe = Pipe()
        ps.standardOutput = pipe
        try ps.run()
        ps.waitUntilExit()
        let raw = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let expected: String? = raw.isEmpty || raw.hasPrefix("?") ? nil : "/dev/" + raw
        #expect(ProcessTTY.path(of: Int(getpid())) == expected)
    }
}
