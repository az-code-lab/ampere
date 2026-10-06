import Foundation

/// Nothing runs when the app is dragged to the Trash, and `brew uninstall`
/// only removes the bundle, so the privileged files would outlive the app.
/// A root launchd job watches the installed bundle path instead: once the
/// bundle has been gone for the grace period and no copy of Ampere runs
/// from anywhere on disk (one deleted from under itself is waited for,
/// see verdict), it has the helper restore the system and remove every
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
    /// How often the job looks for the bundle during the grace period.
    public static let pollSeconds: UInt32 = 5

    /// Whether the bundle stayed missing for a whole grace period: it is
    /// looked for before any wait and then every `poll` seconds, and any
    /// sighting ends the run. The period thus starts when the bundle is
    /// first seen missing, never when the job starts: launchd also runs
    /// the job at boot and on every change to the path, and a single look
    /// at the end of a wait that began then could land inside the seconds
    /// a `brew upgrade` (which quits the app first) leaves the path empty
    /// between removing one bundle and placing the next, and purge a Mac
    /// that was only being upgraded. A bundle removed again after a
    /// sighting gets a fresh period from the run that removal starts.
    public static func stayedMissing(gracePeriod: UInt32 = gracePeriodSeconds, poll: UInt32 = pollSeconds,
                                     exists: () -> Bool, wait: (UInt32) -> Void) -> Bool {
        var waited: UInt32 = 0
        while true {
            if exists() { return false }
            if waited >= gracePeriod { return true }
            let step = min(max(poll, 1), gracePeriod - waited)
            wait(step)
            waited += step
        }
    }

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

    /// What the job does once the bundle has stayed missing for a grace
    /// period.
    public enum Verdict: Equatable {
        /// Restore the system and remove every artifact.
        case uninstall
        /// Leave everything installed, for this reason (logged).
        case keep(String)
        /// Every running copy is on its way out: wait, then look again.
        case awaitQuit
    }

    /// A missing bundle is an uninstall only while its parent directory is
    /// still there (an unmounted volume proves nothing) and no copy of the
    /// app runs from anywhere on disk. Where each running copy's executable
    /// is tells a move from a removal. A copy whose executable still exists
    /// outside a Trash folder was moved, not removed: the job keeps
    /// everything, and the copy re-registers the job with its new path at
    /// its next launch. A copy whose executable is gone (deleted while
    /// running, as `rm -rf` and some uninstallers do; Finder refuses) or
    /// now sits in a Trash folder is being uninstalled: the job waits for
    /// it to quit, since quitting changes no watched path and would
    /// otherwise leave the helper installed until the next boot, and then
    /// looks at the bundle again. A copy the kernel cannot place keeps
    /// everything, the conservative reading; one that exited since it was
    /// listed does not count.
    public static func verdict(parentExists: Bool, runningFrom locations: [InstanceGuard.ExecutableLocation],
                               exists: (String) -> Bool) -> Verdict {
        guard parentExists else { return .keep("its volume is not mounted") }
        let running = locations.filter { $0 != .exited }
        guard !running.isEmpty else { return .uninstall }
        if running.contains(.unknown) { return .keep("a copy of Ampere is running") }
        for case .at(let path) in running where exists(path) && !isInTrash(path) {
            return .keep("a copy of Ampere is running from \(path)")
        }
        return .awaitQuit
    }

    /// Whether `path` lies in a Trash folder: an account's `.Trash`, or a
    /// volume's `.Trashes`.
    public static func isInTrash(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0 == ".Trash" || $0 == ".Trashes" }
    }
}
