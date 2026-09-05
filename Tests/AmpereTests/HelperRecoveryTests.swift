import XCTest
import Shared

final class HelperRecoveryTests: XCTestCase {
    func testFailuresNeverRetireTheRecoveryWatchdog() {
        for dischargeOK in [false, true] {
            for chargingOK in [false, true] {
                for sleepOK in [false, true] {
                    var calls: [String] = []
                    let restored = HelperRecovery.restore(
                        clearDischarge: { calls.append("discharge"); return dischargeOK },
                        allowCharging: { calls.append("charging"); return chargingOK },
                        restoreSleep: { calls.append("sleep"); return sleepOK },
                        stopWatchdogs: { calls.append("watchdog"); return true })
                    XCTAssertEqual(restored, dischargeOK && chargingOK && sleepOK)
                    XCTAssertEqual(calls.contains("sleep"), dischargeOK,
                                   "Do not enable clamshell sleep while discharge may remain active")
                    XCTAssertEqual(calls.contains("watchdog"), restored)
                    XCTAssertEqual(Array(calls.prefix(2)), ["discharge", "charging"])
                    if restored { XCTAssertEqual(calls, ["discharge", "charging", "sleep", "watchdog"]) }
                }
            }
        }
    }

    func testFailedSleepRestoreCanBeRetriedWithTheSavedOriginals() {
        var savedSleep: Int? = 17
        var actualSleep = 0
        var watchdogRunning = true
        var attempts = 0
        let restore = {
            HelperRecovery.restore(clearDischarge: { true }, restoreSleep: {
                attempts += 1
                guard attempts > 1, let original = savedSleep else { return false }
                actualSleep = original
                savedSleep = nil
                return true
            }, stopWatchdogs: {
                watchdogRunning = false
                return true
            })
        }
        XCTAssertFalse(restore())
        XCTAssertEqual(savedSleep, 17)
        XCTAssertTrue(watchdogRunning)
        XCTAssertTrue(restore())
        XCTAssertEqual(actualSleep, 17)
        XCTAssertNil(savedSleep)
        XCTAssertFalse(watchdogRunning)
    }

    func testWatchdogRetirementFailureIsReported() {
        XCTAssertFalse(HelperRecovery.restore(clearDischarge: { true },
            restoreSleep: { true }, stopWatchdogs: { false }))
    }
}
