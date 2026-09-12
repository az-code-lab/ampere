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
    ///
    /// The preferences plist must be removed through the account's `cfprefsd`
    /// (see clearPreferencesCommand), not just unlinked: a logged-in user's
    /// `cfprefsd` caches the domain in memory and rewrites the file, so a
    /// reinstall would read the old registration back. The direct unlink
    /// here still covers accounts that are not logged in, plus the cache,
    /// HTTP storage, and saved-state directories, which no daemon caches.
    public static let userDataPaths = [
        "Library/Preferences/\(AppConstants.appBundleIdentifier).plist",
        "Library/Caches/\(AppConstants.appBundleIdentifier)",
        "Library/HTTPStorages/\(AppConstants.appBundleIdentifier)",
        "Library/Saved Application State/\(AppConstants.appBundleIdentifier).savedState",
    ]

    /// One of the Mac's own accounts (uid 500 and up), as the directory
    /// service lists it.
    public struct Account: Equatable {
        public let uid: uid_t
        public let name: String
        public let home: String

        public init(uid: uid_t, name: String, home: String) {
            self.uid = uid
            self.name = name
            self.home = home
        }
    }

    /// The Mac's own accounts: their uid, short name, and home directory.
    /// System accounts (uid below 500) and the placeholder `/var/empty`
    /// homes of disabled accounts are skipped.
    public static func localAccounts() -> [Account] {
        var accounts: [Account] = []
        setpwent()
        defer { endpwent() }
        while let entry = getpwent() {
            let uid = entry.pointee.pw_uid
            guard uid >= 500, let namePtr = entry.pointee.pw_name,
                  let dirPtr = entry.pointee.pw_dir else { continue }
            let home = String(cString: dirPtr)
            guard home.hasPrefix("/"), home != "/var/empty",
                  !accounts.contains(where: { $0.uid == uid }) else { continue }
            accounts.append(Account(uid: uid, name: String(cString: namePtr), home: home))
        }
        return accounts
    }

    /// The command that clears one account's cached preferences domain, and
    /// its backing file, through that account's `cfprefsd`. `launchctl
    /// asuser` enters the user's GUI bootstrap namespace, where `cfprefsd`
    /// lives; `sudo -n -u` then drops to that user so `cfprefsd` serves
    /// their domain (root never needs a password to switch user, and `-n`
    /// keeps it from ever blocking on a prompt). It reaches only a
    /// logged-in account; for the rest `launchctl` fails harmlessly, and
    /// removeUserData's unlink covers them since no `cfprefsd` is caching.
    public static func clearPreferencesCommand(uid: uid_t, username: String,
                                               domain: String = AppConstants.appBundleIdentifier)
        -> (launchPath: String, arguments: [String]) {
        ("/bin/launchctl",
         ["asuser", String(uid), "/usr/bin/sudo", "-n", "-u", username,
          "/usr/bin/defaults", "delete", domain])
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
