import Foundation

/// Where the running app bundle lives.
public enum AppLocation {
    /// True inside `/Applications` or `~/Applications` (subfolders too). A build folder, a
    /// mounted DMG or a translocated copy is not installed: a login item or a CLI symlink
    /// pointing there would break.
    public static func isInstalled(bundleURL: URL, home: URL) -> Bool {
        let path = bundleURL.standardizedFileURL.path(percentEncoded: false)
        let roots = ["/Applications/", home.appending(path: "Applications").standardizedFileURL.path(percentEncoded: false) + "/"]
        return roots.contains { path.hasPrefix($0) }
    }
}
