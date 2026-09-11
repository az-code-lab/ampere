import Foundation

/// Nothing runs when the app is dragged to the Trash, and `brew uninstall`
/// only removes the bundle, so the privileged files would outlive the app.
/// A root launchd job watches the installed bundle path instead: once the
/// bundle has been gone for the grace period and no copy of Ampere is
/// running, it has the helper restore the system and remove every
/// privileged artifact, the job included.
///
/// The app registers the job through the helper (`register-daemon:<path>`)
/// over the account's passwordless rule, so no administrator prompt is
/// involved, and again whenever it runs from a new location. The job's
/// program is the installed helper; `AssociatedBundleIdentifiers` lists
/// it under Ampere in System Settings > Login Items.
public enum CleanupDaemon {
    /// How long a missing bundle must stay missing before it counts as an
    /// uninstall. A Homebrew upgrade and the in-app updater both remove
    /// and re-create the bundle within seconds; a reinstall inside this
    /// window keeps the helper and needs no new password prompt.
    public static let gracePeriodSeconds: UInt32 = 120

    /// The launchd property list watching `bundlePath`. Equal input gives
    /// identical bytes, so the app can tell an installed job from a stale
    /// one by comparing files.
    public static func plist(bundlePath: String) -> Data {
        let job: [String: Any] = [
            "Label": AppConstants.cleanupDaemonLabel,
            "ProgramArguments": [AppConstants.helperPath, "uninstall-if-missing:\(bundlePath)"],
            "WatchPaths": [bundlePath],
            "RunAtLoad": true,
            "AssociatedBundleIdentifiers": [AppConstants.appBundleIdentifier],
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0) else {
            preconditionFailure("a dictionary of strings and booleans always serializes")
        }
        return data
    }

    /// Whether the installed job already watches `bundlePath`.
    public static func isRegistered(bundlePath: String,
                                    plistPath: String = AppConstants.cleanupDaemonPlistPath) -> Bool {
        (try? Data(contentsOf: URL(fileURLWithPath: plistPath))) == plist(bundlePath: bundlePath)
    }

    /// The path the job should watch for this process, or nil when it must
    /// not watch anything: a bare debug executable, some other bundle, or
    /// a quarantined copy running from macOS's randomized translocation
    /// mount, whose path vanishes at every quit.
    public static func eligibleBundlePath(bundleURL: URL, bundleIdentifier: String?) -> String? {
        guard bundleIdentifier == AppConstants.appBundleIdentifier,
              bundleURL.pathExtension == "app" else { return nil }
        let path = bundleURL.standardizedFileURL.path
        guard isValidBundlePath(path), !path.contains("/AppTranslocation/") else { return nil }
        return path
    }

    /// The shape accepted for a watched path: absolute, with no empty, `.`
    /// or `..` segments and no trailing slash, so one bundle always maps to
    /// one string and the plist comparison stays exact.
    public static func isValidBundlePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.count > 1, !path.hasSuffix("/") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
            .contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    /// Root registers a watch path only for a real copy of the app, so an
    /// account with helper access cannot point the job at other paths.
    public static func isAppBundle(at path: String) -> Bool {
        let info = URL(fileURLWithPath: path).appending(path: "Contents/Info.plist")
        guard let data = try? Data(contentsOf: info),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let bundleIdentifier = (plist as? [String: Any])?["CFBundleIdentifier"] as? String
        else { return false }
        return bundleIdentifier == AppConstants.appBundleIdentifier
    }

    /// A missing bundle is an uninstall only while its parent directory is
    /// still there (an unmounted volume proves nothing) and no copy of the
    /// app is running: a running copy was moved, not removed, and it
    /// re-registers the job with its new path at the next launch.
    public static func shouldUninstall(bundleExists: Bool, parentExists: Bool, appRunning: Bool) -> Bool {
        parentExists && !bundleExists && !appRunning
    }
}
