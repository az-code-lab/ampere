import Foundation

/// The helper's `uninstall`: restore first, then remove every privileged
/// artifact. A failed restore removes nothing, because the helper, the
/// saved settings, and the watchdog are the only things that can still
/// put the system back.
public enum HelperUninstall {
    public struct Artifacts {
        /// Unlinked directly: every parent directory is root-owned.
        public var files: [String]
        /// Unlinked without following directory symlinks: the parent may
        /// be writable by ordinary users (the pre-0.0.60 helper location).
        public var legacyFiles: [String]
        /// Removed recursively.
        public var directories: [String]

        public init(files: [String], legacyFiles: [String], directories: [String]) {
            self.files = files
            self.legacyFiles = legacyFiles
            self.directories = directories
        }

        public static let installed = Artifacts(
            files: [AppConstants.sudoersPath, AppConstants.helperPath, AppConstants.cleanupDaemonPlistPath],
            legacyFiles: [AppConstants.legacyHelperPath],
            directories: [AppConstants.stateDirPath])
    }

    /// Exit status: 0 done, 2 restore failed (nothing removed), 3 some
    /// artifact could not be removed. The job is unloaded last, because
    /// unloading terminates this very process when it is the job.
    public static func run(restore: () -> Bool, removeArtifacts: () -> Bool,
                           unloadDaemon: () -> Void) -> Int32 {
        guard restore() else { return 2 }
        let removed = removeArtifacts()
        unloadDaemon()
        return removed ? 0 : 3
    }

    /// Per-account files, relative to each home directory: preferences
    /// (including the registration), the URL cache and HTTP storage the
    /// update check leaves behind, and saved window state. `purge` and the
    /// cleanup job remove them so an uninstall leaves nothing behind;
    /// `uninstall` and Revoke never do, because the app stays installed.
    public static let userDataPaths = [
        "Library/Preferences/\(AppConstants.appBundleIdentifier).plist",
        "Library/Caches/\(AppConstants.appBundleIdentifier)",
        "Library/HTTPStorages/\(AppConstants.appBundleIdentifier)",
        "Library/Saved Application State/\(AppConstants.appBundleIdentifier).savedState",
    ]

    /// Home directories of the Mac's own accounts (uid 500 and up), as
    /// the directory service lists them.
    public static func localHomeDirectories() -> [String] {
        var homes: [String] = []
        setpwent()
        defer { endpwent() }
        while let entry = getpwent() {
            guard entry.pointee.pw_uid >= 500, let directory = entry.pointee.pw_dir else { continue }
            let home = String(cString: directory)
            guard home.hasPrefix("/"), home != "/var/empty", !homes.contains(home) else { continue }
            homes.append(home)
        }
        return homes
    }

    /// Missing items are fine; a symlink is removed, never followed.
    public static func removeArtifacts(_ artifacts: Artifacts) -> Bool {
        var removed = true
        for file in artifacts.files where unlink(file) != 0 && errno != ENOENT {
            removed = false
        }
        for file in artifacts.legacyFiles
        where !HelperSecurity.removeFileWithoutFollowingDirectories(at: file) {
            removed = false
        }
        for directory in artifacts.directories where !removeIfPresent(directory) {
            removed = false
        }
        return removed
    }

    /// Remove `paths` under every home in `homes`, with the same rules.
    public static func removeUserData(homes: [String], paths: [String] = userDataPaths) -> Bool {
        var removed = true
        for home in homes {
            for path in paths where !removeIfPresent((home as NSString).appendingPathComponent(path)) {
                removed = false
            }
        }
        return removed
    }

    private static func removeIfPresent(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return true }
        do {
            try FileManager.default.removeItem(atPath: path)
            return true
        } catch {
            return false
        }
    }
}
