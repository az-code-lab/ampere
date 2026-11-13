import Foundation

/// Starts the helper's daemons: processes that outlive the command that
/// started them (the crash watchdog, the cleanup job's unload step).
public enum DetachedSpawn {
    /// Start `path` with `arguments` in its own session, detached from this
    /// process and from any terminal: the standard streams on /dev/null,
    /// every signal at its default action, and none blocked. Returns the
    /// posix_spawn error code (0 on success) and the child's PID.
    ///
    /// The session (setsid) keeps a terminal's Ctrl+C away: otherwise the
    /// child inherits the app's process group, and a SIGINT to the whole
    /// foreground group (dev runs via run.sh) would kill a watchdog at the
    /// same instant as the app it exists to clean up after.
    ///
    /// The signal state is reset because ignored and blocked signals are
    /// inherited across posix_spawn, and not every caller starts clean.
    /// The install script runs under the administrator prompt, and the
    /// watchdog it started ignored SIGTERM (the helper sets no signal
    /// dispositions of its own; the watchdog the launch starts through
    /// sudo did not ignore it). The pkill that retires watchdogs
    /// (stopWatchdogs) signalled it, reported success, and left it
    /// running: every launch that installed or updated the helper ran
    /// with two watchdogs, both restored when the app exited, and the
    /// extra one could restore over a new instance that had started
    /// meanwhile. Seen 2026-09-16; explained 2026-11-12 from the ignored
    /// signal masks of the two processes.
    public static func spawn(_ path: String, arguments: [String]) -> (status: Int32, pid: pid_t) {
        var pid: pid_t = 0
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        var everySignal = sigset_t()
        sigfillset(&everySignal)
        posix_spawnattr_setsigdefault(&attributes, &everySignal)
        var noSignal = sigset_t()
        sigemptyset(&noSignal)
        posix_spawnattr_setsigmask(&attributes, &noSignal)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        let argv = ([path] + arguments).map { strdup($0) }
        var args: [UnsafeMutablePointer<CChar>?] = argv + [nil]
        let status = posix_spawn(&pid, path, &fileActions, &attributes, &args, nil)
        posix_spawnattr_destroy(&attributes)
        posix_spawn_file_actions_destroy(&fileActions)
        for pointer in argv { free(pointer) }
        return (status, pid)
    }
}
