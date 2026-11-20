import AppKit
import DevPulseCore
import os

/// Links the bundled `devpulse` terminal client onto the PATH, through an administrator prompt.
@MainActor
enum CommandLineInstaller {
    private static let log = Logger(subsystem: "io.jp4.devpulse", category: "cli")
    private static let offeredKey = "devpulse.cliInstallOffered"
    /// AppleScript's "User canceled." error number.
    private static let userCanceled = -128

    enum Outcome: Equatable {
        case installed
        case canceled
        case failed(String)
    }

    static var bundleURL: URL { Bundle.main.bundleURL }

    static var status: CLIStatus {
        CLIInstall.status(linkPath: CLIInstall.linkPath, bundleURL: bundleURL)
    }

    /// Creates `/usr/local/bin/devpulse` (replacing an existing link) after an admin prompt.
    /// It runs as root, so it checks the location and the helper itself, whoever calls it.
    static func install() -> Outcome {
        if case .failure(let error) = CLIInstall.canInstall(bundleURL: bundleURL) {
            return .failed(error.localizedDescription)
        }
        let helper = CLIInstall.helperPath(bundle: bundleURL).path(percentEncoded: false)
        guard let script = NSAppleScript(source: CLIInstall.appleScript(helper: helper)) else {
            return .failed("Could not prepare the installation.")
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        guard let error else { return .installed }
        if error[NSAppleScript.errorNumber] as? Int == userCanceled { return .canceled }
        let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown error."
        log.error("Command line tool not installed: \(message, privacy: .public)")
        return .failed("Could not install the command line tool: \(message)")
    }

    /// Asks once, on the first launch from an Applications folder, whether to install the tool.
    /// Returns true when the user chose "Install".
    static func offerOnce() -> Bool {
        let defaults = UserDefaults.standard
        let canInstall = if case .success = CLIInstall.canInstall(bundleURL: bundleURL) { true } else { false }
        guard CLIInstall.shouldOffer(
            alreadyOffered: defaults.bool(forKey: offeredKey), canInstall: canInstall, status: status)
        else { return false }
        defaults.set(true, forKey: offeredKey)
        NSApp.activate()  // a menu bar only app is never frontmost on its own
        let alert = NSAlert()
        alert.messageText = "Install the command line tool?"
        alert.informativeText = "Puts “devpulse” on your PATH, so you can open the terminal dashboard by typing it in a terminal. macOS asks for your password."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Not Now")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
