import XCTest
@testable import Ampere

/// Pins the launch-time repair of the persisted charge bounds. didSet doesn't
/// run during init, so this function is the only thing standing between
/// corrupted (or locked-out) saved values and the state machine's first
/// decision.
final class ChargeBoundsRepairTests: XCTestCase {

    private let defaults = (lower: BatteryMonitor.defaultChargeLowerBound,
                            upper: BatteryMonitor.defaultChargeUpperBound)

    func testNeverSaved_UsesDefaults() {
        let bounds = BatteryMonitor.repairedChargeBounds(lower: nil, upper: nil, locked: false)
        XCTAssertEqual(bounds.lower, defaults.lower)
        XCTAssertEqual(bounds.upper, defaults.upper)
    }

    func testUnlocked_KeepsSavedCustomRange() {
        let bounds = BatteryMonitor.repairedChargeBounds(lower: 20, upper: 80, locked: false)
        XCTAssertEqual(bounds.lower, 20)
        XCTAssertEqual(bounds.upper, 80)
    }

    func testUnlocked_ClampsOutOfRangeEnds() {
        let bounds = BatteryMonitor.repairedChargeBounds(lower: -10, upper: 120, locked: false)
        XCTAssertEqual(bounds.lower, 0)
        XCTAssertEqual(bounds.upper, 100)
    }

    func testUnlocked_GapViolationResetsBoth() {
        // Inverted, touching, and just under the minimum gap all reset.
        for (lower, upper) in [(60, 40), (50, 50), (50, 54)] {
            let bounds = BatteryMonitor.repairedChargeBounds(lower: lower, upper: upper, locked: false)
            XCTAssertEqual(bounds.lower, defaults.lower, "\(lower)/\(upper)")
            XCTAssertEqual(bounds.upper, defaults.upper, "\(lower)/\(upper)")
        }
        // Exactly the minimum gap is valid.
        let ok = BatteryMonitor.repairedChargeBounds(lower: 50, upper: 55, locked: false)
        XCTAssertEqual(ok.lower, 50)
        XCTAssertEqual(ok.upper, 55)
    }

    func testLocked_ForcesDefaultsOverSavedCustomRange() {
        // A custom range left behind by a lapsed registration must not
        // survive a relaunch of the now-unregistered copy.
        let bounds = BatteryMonitor.repairedChargeBounds(lower: 20, upper: 80, locked: true)
        XCTAssertEqual(bounds.lower, defaults.lower)
        XCTAssertEqual(bounds.upper, defaults.upper)
    }

    func testLocked_NeverSaved_UsesDefaults() {
        let bounds = BatteryMonitor.repairedChargeBounds(lower: nil, upper: nil, locked: true)
        XCTAssertEqual(bounds.lower, defaults.lower)
        XCTAssertEqual(bounds.upper, defaults.upper)
    }

    func testDefaultsSatisfyTheGapInvariant() {
        // The lock relies on the defaults being a valid pair: the didSet
        // reset assigns them without clamping.
        XCTAssertGreaterThanOrEqual(defaults.upper - defaults.lower, BatteryMonitor.chargeBoundMinGap)
        XCTAssertGreaterThanOrEqual(defaults.lower, 0)
        XCTAssertLessThanOrEqual(defaults.upper, 100)
    }
}
