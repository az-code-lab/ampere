import XCTest
import Shared

/// The helper's daemons are started from whatever ran the helper: sudo, a
/// launchd job, or the install script under the administrator prompt. They
/// must come up the same way from each.
final class DetachedSpawnTests: XCTestCase {
    private enum CallerState { case ignoresSIGTERM, blocksSIGTERM }

    /// Starts a sleeper while this process is in `state`, the way a caller
    /// that never started clean would, and puts this process back.
    private func spawnSleeper(whileCaller state: CallerState) -> (status: Int32, pid: pid_t) {
        switch state {
        case .ignoresSIGTERM:
            let previous = signal(SIGTERM, SIG_IGN)
            defer { signal(SIGTERM, previous) }
            return DetachedSpawn.spawn("/bin/sleep", arguments: ["30"])
        case .blocksSIGTERM:
            var blocked = sigset_t()
            sigemptyset(&blocked)
            sigaddset(&blocked, SIGTERM)
            var previous = sigset_t()
            pthread_sigmask(SIG_BLOCK, &blocked, &previous)
            defer { pthread_sigmask(SIG_SETMASK, &previous, nil) }
            return DetachedSpawn.spawn("/bin/sleep", arguments: ["30"])
        }
    }

    /// The signal that ended `pid`, a child of this process, or nil when it
    /// is still running after `timeout` (it is then killed and reaped).
    private func terminatingSignal(of pid: pid_t, timeout: TimeInterval = 3) -> Int32? {
        var status: Int32 = 0
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if waitpid(pid, &status, WNOHANG) == pid {
                // WIFSIGNALED / WTERMSIG: the low seven bits hold the signal.
                let signal = status & 0x7f
                return signal != 0 && signal != 0x7f ? signal : 0
            }
            usleep(10_000)
        }
        kill(pid, SIGKILL)
        waitpid(pid, &status, 0)
        return nil
    }

    /// The signals `pid` ignores, as the kernel reports them.
    private func ignoredSignals(of pid: pid_t) -> UInt32? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return UInt32(bitPattern: Int32(truncatingIfNeeded: info.kp_proc.p_sigignore))
    }

    /// An ignored signal is inherited across posix_spawn. The helper's
    /// install script runs under the administrator prompt, where SIGTERM
    /// is ignored, and the watchdog it started ignored it too: the pkill
    /// that retires watchdogs reported success and left it running, so
    /// every launch that installed the helper ran with two watchdogs
    /// (seen 2026-09-16 and 2026-11-12). A daemon starts with every signal
    /// at its default action whatever its caller ignores.
    func testADaemonEndsOnSIGTERMEvenWhenItsCallerIgnoresIt() throws {
        let sleeper = spawnSleeper(whileCaller: .ignoresSIGTERM)
        XCTAssertEqual(sleeper.status, 0)
        guard sleeper.status == 0 else { return }
        let ignored = try XCTUnwrap(ignoredSignals(of: sleeper.pid))
        XCTAssertEqual(ignored & (1 << UInt32(SIGTERM - 1)), 0, "SIGTERM is not ignored in the daemon")
        XCTAssertEqual(kill(sleeper.pid, SIGTERM), 0)
        XCTAssertEqual(terminatingSignal(of: sleeper.pid), SIGTERM)
    }

    /// The same for a blocked signal: the mask is inherited too, and a
    /// blocked SIGTERM would stay pending for the daemon's whole life.
    func testADaemonEndsOnSIGTERMEvenWhenItsCallerBlocksIt() {
        let sleeper = spawnSleeper(whileCaller: .blocksSIGTERM)
        XCTAssertEqual(sleeper.status, 0)
        guard sleeper.status == 0 else { return }
        XCTAssertEqual(kill(sleeper.pid, SIGTERM), 0)
        XCTAssertEqual(terminatingSignal(of: sleeper.pid), SIGTERM)
    }

    /// The daemon leads its own session, so a signal sent to the caller's
    /// process group (a terminal's Ctrl+C) does not reach it.
    func testADaemonRunsInItsOwnSession() {
        let sleeper = DetachedSpawn.spawn("/bin/sleep", arguments: ["30"])
        XCTAssertEqual(sleeper.status, 0)
        guard sleeper.status == 0 else { return }
        XCTAssertEqual(getsid(sleeper.pid), sleeper.pid)
        XCTAssertNotEqual(getpgid(sleeper.pid), getpgrp())
        XCTAssertEqual(kill(sleeper.pid, SIGTERM), 0)
        XCTAssertEqual(terminatingSignal(of: sleeper.pid), SIGTERM)
    }

    /// A path that cannot be started reports the error and no child.
    func testAMissingExecutableReportsTheError() {
        let missing = DetachedSpawn.spawn("/nonexistent/ampere-daemon", arguments: [])
        XCTAssertEqual(missing.status, ENOENT)
    }
}
