import XCTest
import Shared

final class InstanceGuardTests: XCTestCase {
    func testFindsProcessesByNameWithOwnerAndStartTime() {
        let launchd = InstanceGuard.runningInstances(named: "launchd")
        XCTAssertTrue(launchd.contains { $0.pid == 1 && $0.uid == 0 }, "\(launchd)")

        let me = InstanceGuard.runningInstances(named: ProcessInfo.processInfo.processName)
            .first { $0.pid == getpid() }
        XCTAssertNotNil(me)
        XCTAssertEqual(me?.uid, getuid())
        XCTAssertLessThanOrEqual(me?.startSeconds ?? .max, Int(Date().timeIntervalSince1970))
        XCTAssertEqual(me?.owner, "another copy of Ampere in this account")
    }

    func testEarlierStartWinsAndThePidBreaksTies() {
        let early = InstanceGuard.Instance(pid: 900, uid: 501, startSeconds: 100, startMicroseconds: 5)
        let late = InstanceGuard.Instance(pid: 200, uid: 502, startSeconds: 100, startMicroseconds: 6)
        let tie = InstanceGuard.Instance(pid: 300, uid: 503, startSeconds: 100, startMicroseconds: 5)
        XCTAssertTrue(early.startedBefore(late))
        XCTAssertFalse(late.startedBefore(early))
        XCTAssertFalse(early.startedBefore(tie), "same instant: the lower PID wins")
        XCTAssertTrue(tie.startedBefore(early))
    }

    func testTheTestHostNeverStandsBy() {
        // xctest is not named Ampere, so it cannot find itself among the
        // app's instances and must never yield, whatever else is running.
        XCTAssertNil(InstanceGuard.competingInstance())
    }

    /// The two answers a test can produce: this process runs from a file on
    /// disk, and a process that has exited is reported as such. A moved or
    /// deleted executable needs a long-running process that is not a
    /// platform binary (macOS kills a copied system tool), so those two
    /// answers were verified by hand on macOS 27 (see executableLocation).
    func testExecutableLocationNamesThisProcessAndReportsAnExitedOne() throws {
        guard case .at(let path) = InstanceGuard.executableLocation(of: getpid()) else {
            return XCTFail("the test host's executable is on disk")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), path)
        XCTAssertFalse(CleanupDaemon.isInTrash(path))

        let finished = Process()
        finished.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try finished.run()
        finished.waitUntilExit()
        XCTAssertEqual(InstanceGuard.executableLocation(of: finished.processIdentifier), .exited)
    }
}
