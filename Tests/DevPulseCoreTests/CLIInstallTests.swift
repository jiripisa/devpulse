import Foundation
import Testing
@testable import DevPulseCore

@Suite("CLIInstall")
struct CLIInstallTests {
    private let home = URL(fileURLWithPath: "/Users/someone")

    @Test("Accepts an app in /Applications or ~/Applications", arguments: [
        "/Applications/DevPulse.app",
        "/Users/someone/Applications/DevPulse.app",
        "/Applications/Utilities/DevPulse.app",  // subfolders are fine: the path stays stable
    ])
    func accepts(path: String) {
        let result = CLIInstall.canInstall(bundleURL: URL(fileURLWithPath: path), home: home, isExecutable: { _ in true })
        #expect(throws: Never.self) { try result.get() }
    }

    @Test("Refuses a copy without an executable helper")
    func helperMissing() {
        let bundle = URL(fileURLWithPath: "/Applications/DevPulse.app")
        var asked: [String] = []
        let result = CLIInstall.canInstall(bundleURL: bundle, home: home) { path in
            asked.append(path)
            return false
        }
        #expect(result.failure == .helperMissing)
        #expect(asked == ["/Applications/DevPulse.app/Contents/Helpers/devpulse"])
        #expect(CLIInstallError.helperMissing.errorDescription
            == "The command line tool is missing from this copy of DevPulse.")
    }

    @Test("Offers the install once, only where it can install and is not installed yet")
    func shouldOffer() {
        #expect(CLIInstall.shouldOffer(alreadyOffered: false, canInstall: true, status: .notInstalled))
        #expect(CLIInstall.shouldOffer(alreadyOffered: false, canInstall: true, status: .pointsElsewhere("/x")))
        #expect(!CLIInstall.shouldOffer(alreadyOffered: true, canInstall: true, status: .notInstalled))
        #expect(!CLIInstall.shouldOffer(alreadyOffered: false, canInstall: false, status: .notInstalled))
        #expect(!CLIInstall.shouldOffer(alreadyOffered: false, canInstall: true, status: .installed))
    }

    @Test("Rejects a mounted DMG, a translocated copy and a build folder", arguments: [
        "/Volumes/DevPulse/DevPulse.app",
        "/private/var/folders/ab/xyz/T/AppTranslocation/1234/d/DevPulse.app",
        "/Users/someone/Downloads/DevPulse.app",
        "/Users/someone/dev/build/release/DevPulse.app",
    ])
    func rejects(path: String) {
        let result = CLIInstall.canInstall(bundleURL: URL(fileURLWithPath: path), home: home)
        #expect(result.failure == .notInApplications)
    }

    @Test("Rejects /Applications paths that pass through AppTranslocation")
    func rejectsTranslocationUnderApplications() {
        let url = URL(fileURLWithPath: "/Applications/AppTranslocation/x/DevPulse.app")
        #expect(CLIInstall.canInstall(bundleURL: url, home: home).failure == .notInApplications)
    }

    @Test("The not-in-Applications reason tells the user what to do")
    func reason() {
        #expect(CLIInstallError.notInApplications.errorDescription
            == "Move DevPulse to the Applications folder first — the command line tool would otherwise point at a location that can disappear.")
    }

    @Test("The helper lives in Contents/Helpers, not Contents/MacOS")
    func helperPath() {
        let bundle = URL(fileURLWithPath: "/Applications/DevPulse.app")
        #expect(CLIInstall.helperPath(bundle: bundle).path == "/Applications/DevPulse.app/Contents/Helpers/devpulse")
    }

    @Test("Status follows the symlink")
    func status() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = dir.appending(path: "DevPulse.app")
        let link = dir.appending(path: "devpulse").path

        #expect(CLIInstall.status(linkPath: link, bundleURL: bundle) == .notInstalled)

        let helper = CLIInstall.helperPath(bundle: bundle).path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: helper)
        // The link is ours, but this copy has no helper behind it: not a working install.
        #expect(CLIInstall.status(linkPath: link, bundleURL: bundle) == .pointsElsewhere(helper))
        try FileManager.default.createDirectory(
            atPath: (helper as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: helper))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper)
        #expect(CLIInstall.status(linkPath: link, bundleURL: bundle) == .installed)

        try FileManager.default.removeItem(atPath: link)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "/somewhere/else/devpulse")
        #expect(CLIInstall.status(linkPath: link, bundleURL: bundle) == .pointsElsewhere("/somewhere/else/devpulse"))
    }

    @Test("A regular file at the link path counts as pointing elsewhere")
    func regularFile() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let link = dir.appending(path: "devpulse")
        try Data().write(to: link)
        #expect(CLIInstall.status(linkPath: link.path, bundleURL: dir.appending(path: "DevPulse.app"))
            == .pointsElsewhere(link.path))
    }

    @Test("The install script is quoted for the shell and for AppleScript")
    func script() {
        let helper = "/Applications/My \"App\" it's\\x.app/Contents/Helpers/devpulse"
        let script = CLIInstall.appleScript(helper: helper, linkPath: "/usr/local/bin/devpulse")
        // Shell: single quotes, with ' written as '\''. AppleScript: \ and " escaped.
        let shell = "mkdir -p '/usr/local/bin' && ln -sfn '/Applications/My \"App\" it'\\''s\\x.app/Contents/Helpers/devpulse' '/usr/local/bin/devpulse'"
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        #expect(script == "do shell script \"\(escaped)\" with administrator privileges")
    }

    @Test("Shell quoting handles spaces and single quotes")
    func shellQuote() {
        #expect(CLIInstall.shellQuote("/a b/it's") == "'/a b/it'\\''s'")
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { error } else { nil }
    }
}
