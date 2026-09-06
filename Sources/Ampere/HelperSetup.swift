import Foundation
import Shared

/// The migration runs inside the existing administrator prompt. Stage and
/// verify the replacement before retiring the old helper; never run the
/// legacy executable from its potentially writable directory as root.
///
/// The sudoers file holds one line per account that has granted access.
/// Installing rewrites every existing line with the new digest and path,
/// so an upgrade prompts only the first account to launch it; revoking
/// drops only the current account's line and deletes the helper once no
/// account remains.
enum HelperSetup {
    /// awk condition selecting the lines this app wrote for accounts other
    /// than `user`: exactly our rule shape, for the current or the legacy
    /// helper path, first occurrence per account. Everything else is
    /// dropped when the file is rewritten, so it stays canonical.
    private static let otherAccountRules = "NF == 5 && $1 != user"
        + " && $1 ~ /^[A-Za-z0-9_][A-Za-z0-9_.-]*$/"
        + " && $2 == \"ALL=(root)\" && $3 == \"NOPASSWD:\""
        + " && length($4) == 71 && $4 ~ /^sha256:[0-9a-f]+$/"
        + " && ($5 == helper || $5 == legacy) && !seen[$1]++"

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
        {
            if [ -f \(quote(paths.sudoers)) ]; then
                /usr/bin/awk -v user=\(quote(username)) -v digest=\(quote(digest)) -v helper="$helper" -v legacy=\(quote(paths.legacy)) '\(otherAccountRules) { print $1 " ALL=(root) NOPASSWD: sha256:" digest " " helper }' \(quote(paths.sudoers))
            fi
            /usr/bin/printf '%s' \(quote(rule))
        } > "$stage/sudoers"
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

    static func removalScript(username: String, paths: Paths = Paths(),
                              stateDirectory: String = AppConstants.stateDirPath,
                              legacyMarkers: [String] = [AppConstants.legacySavedSleepPath,
                                                         AppConstants.legacySavedDisplaySleepPath]) -> String {
        let sudoersDirectory = (paths.sudoers as NSString).deletingLastPathComponent
        return """
        set -eu
        umask 022
        helper=\(quote(paths.helper))
        sudoers=\(quote(paths.sudoers))
        # A restore failure stops here, keeping the executable, the saved
        # settings, and the still-running watchdog for a retry.
        "$helper" restore
        "$helper" remove-legacy
        remaining=''
        if [ -f "$sudoers" ]; then
            remaining=$(/usr/bin/awk -v user=\(quote(username)) -v helper="$helper" -v legacy=\(quote(paths.legacy)) '\(otherAccountRules) { print }' "$sudoers")
        fi
        if [ -n "$remaining" ]; then
            # Other accounts still use the helper: drop only this account's
            # line. sudo ignores the dotted staging name until it is moved.
            stage=$(/usr/bin/mktemp \(quote(sudoersDirectory + "/.az-ampere.XXXXXX")))
            trap '/bin/rm -f "$stage"' EXIT
            /usr/bin/printf '%s\\n' "$remaining" > "$stage"
            /bin/chmod 0440 "$stage"
            /usr/sbin/chown root:wheel "$stage"
            /usr/sbin/visudo -cf "$stage"
            /bin/mv -f "$stage" "$sudoers"
        else
            /bin/rm -f "$sudoers" "$helper"\(legacyMarkers.map { " " + quote($0) }.joined())
            /bin/rm -rf \(quote(stateDirectory))
        fi
        """
    }
}
