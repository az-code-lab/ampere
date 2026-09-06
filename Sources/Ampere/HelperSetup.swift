import Foundation
import Shared

/// The migration runs inside the existing administrator prompt. Stage and
/// verify the replacement before retiring the old helper; never run the
/// legacy executable from its potentially writable directory as root.
enum HelperSetup {
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    struct Paths {
        var directory = AppConstants.helperDirectory
        var helper = AppConstants.helperPath
        var legacy = AppConstants.legacyHelperPath
        var sudoers = AppConstants.sudoersPath
    }

    static func installScript(writer: String, digest: String, username: String,
                              appPID: Int32, paths: Paths = Paths()) -> String {
        let rule = "\(username) ALL=(root) NOPASSWD: sha256:\(digest) \(paths.helper)\n"
        return """
        set -eu
        umask 022
        helper=\(quote(paths.helper))
        installed=0
        if [ ! -d \(quote(paths.directory)) ]; then
            /bin/mkdir -m 0755 \(quote(paths.directory))
        fi
        stage=$(/usr/bin/mktemp -d \(quote(paths.directory + "/.az-ampere-install.XXXXXX")))
        finish() {
            result=$?
            /bin/rm -rf "$stage" || true
            if [ "$installed" = 1 ]; then
                if ! "$helper" spawn-watchdog:\(appPID); then result=1; fi
            fi
            exit "$result"
        }
        trap finish EXIT
        /bin/cp \(quote(writer)) "$stage/helper"
        /usr/bin/xattr -c "$stage/helper"
        /bin/chmod -N "$stage/helper"
        /bin/chmod 0755 "$stage/helper"
        /usr/sbin/chown root:wheel "$stage/helper"
        actual=$(/usr/bin/shasum -a 256 "$stage/helper" | /usr/bin/awk '{print $1}')
        [ "$actual" = \(quote(digest)) ]
        /usr/bin/printf '%s' \(quote(rule)) > "$stage/sudoers"
        /bin/chmod 0440 "$stage/sudoers"
        /usr/sbin/chown root:wheel "$stage/sudoers"
        /usr/sbin/visudo -cf "$stage/sudoers"
        /bin/mv -f "$stage/helper" "$helper"
        installed=1
        /bin/mkdir -p \(quote((paths.sudoers as NSString).deletingLastPathComponent))
        /bin/mv -f "$stage/sudoers" \(quote(paths.sudoers))
        # Best effort: the launch cleanup and the watchdog spawned on exit
        # retry a failed restore. Failing the install instead would leave
        # the new helper without its rule, and every later launch would
        # prompt, fail the same way, and quit.
        "$helper" restore || true
        "$helper" remove-legacy
        """
    }

    static func removalScript(paths: Paths = Paths(),
                              stateDirectory: String = AppConstants.stateDirPath,
                              legacyMarkers: [String] = [AppConstants.legacySavedSleepPath,
                                                         AppConstants.legacySavedDisplaySleepPath]) -> String {
        // && is intentional: a restore failure retains both the executable
        // and the saved settings, along with its still-running watchdog.
        return "\(quote(paths.helper)) restore"
            + " && \(quote(paths.helper)) remove-legacy"
            + " && /bin/rm -f \(quote(paths.sudoers)) \(quote(paths.helper))"
            + legacyMarkers.map { " " + quote($0) }.joined()
            + " && /bin/rm -rf \(quote(stateDirectory))"
    }
}
