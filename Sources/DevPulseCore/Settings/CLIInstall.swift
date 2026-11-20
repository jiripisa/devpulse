import Foundation

/// Why the command line tool cannot be installed from where the app runs.
public enum CLIInstallError: Error, Equatable, LocalizedError {
    case notInApplications
    case helperMissing

    public var errorDescription: String? {
        switch self {
        case .notInApplications:
            "Move DevPulse to the Applications folder first — the command line tool would otherwise point at a location that can disappear."
        case .helperMissing:
            "The command line tool is missing from this copy of DevPulse."
        }
    }
}

/// Whether `/usr/local/bin/devpulse` is a link to this app's bundled helper.
public enum CLIStatus: Equatable {
    case notInstalled
    case installed
    /// Something else is at the link path: another link's target, or the path itself for a file.
    case pointsElsewhere(String)
}

/// The `devpulse` terminal client, bundled at `Contents/Helpers/devpulse` and linked onto the PATH.
public enum CLIInstall {
    public static let linkPath = "/usr/local/bin/devpulse"

    /// `Contents/Helpers`, never `Contents/MacOS`: on a case-insensitive volume `devpulse` would
    /// collide with the app executable `DevPulse`.
    public static func helperPath(bundle: URL) -> URL {
        bundle.appending(path: "Contents/Helpers/devpulse")
    }

    /// Whether a path is an executable file; replaceable in tests.
    public typealias ExecutableCheck = (String) -> Bool

    public static func isExecutableFile(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    /// The link must point at a stable place, so only `/Applications` and `~/Applications` (and
    /// their subfolders) qualify; a mounted DMG, a translocated copy or a build folder do not.
    /// The helper must also be there: the install runs as root and links whatever path it gets.
    public static func canInstall(
        bundleURL: URL, home: URL = URL.homeDirectory, isExecutable: ExecutableCheck = isExecutableFile
    ) -> Result<Void, CLIInstallError> {
        let path = bundleURL.standardizedFileURL.path(percentEncoded: false)
        guard !path.contains("/AppTranslocation/"), !path.hasPrefix("/Volumes/"),
              AppLocation.isInstalled(bundleURL: bundleURL, home: home)
        else { return .failure(.notInApplications) }
        guard isExecutable(helperPath(bundle: bundleURL).path(percentEncoded: false)) else {
            return .failure(.helperMissing)
        }
        return .success(())
    }

    /// Whether to ask at launch: once ever, only where the install can work, and not when the
    /// tool is installed already.
    public static func shouldOffer(alreadyOffered: Bool, canInstall: Bool, status: CLIStatus) -> Bool {
        !alreadyOffered && canInstall && status != .installed
    }

    /// A link to this copy's helper counts as installed only while the helper is there; a link
    /// to a missing helper is reported like any other target, so Settings offers "Replace".
    public static func status(
        linkPath: String, bundleURL: URL, isExecutable: ExecutableCheck = isExecutableFile
    ) -> CLIStatus {
        let fileManager = FileManager.default
        guard (try? fileManager.attributesOfItem(atPath: linkPath)) != nil else { return .notInstalled }
        guard let target = try? fileManager.destinationOfSymbolicLink(atPath: linkPath) else {
            return .pointsElsewhere(linkPath)  // a regular file, not our link
        }
        let helper = helperPath(bundle: bundleURL).standardizedFileURL.path(percentEncoded: false)
        let ours = URL(fileURLWithPath: target).standardizedFileURL.path(percentEncoded: false) == helper
        return ours && isExecutable(helper) ? .installed : .pointsElsewhere(target)
    }

    /// The AppleScript that creates the link with administrator privileges.
    public static func appleScript(helper: String, linkPath: String = linkPath) -> String {
        let directory = (linkPath as NSString).deletingLastPathComponent
        let shell = "mkdir -p \(shellQuote(directory)) && ln -sfn \(shellQuote(helper)) \(shellQuote(linkPath))"
        return "do shell script \"\(appleScriptEscape(shell))\" with administrator privileges"
    }

    /// Single-quotes `text` for `sh`; an embedded `'` becomes `'\''`.
    public static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
