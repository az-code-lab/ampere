import XCTest
@testable import Ampere

/// Pins the shared "reached the bound" predicate used by both the state
/// machine and the launch-time crash repairs in init. The 100%-only BMS
/// carve-out is the load-bearing part: fullyCharged must complete a 100%
/// target on worn batteries, but must never count toward a lower bound.
final class ReachedBoundTests: XCTestCase {

    func testPercentageComparison_AtAndAroundBound() {
        XCTAssertFalse(BatteryMonitor.reachedBound(60, percentage: 59, fullyCharged: false))
        XCTAssertTrue(BatteryMonitor.reachedBound(60, percentage: 60, fullyCharged: false))
        XCTAssertTrue(BatteryMonitor.reachedBound(60, percentage: 61, fullyCharged: false))
    }

    func testFullyCharged_CompletesA100Target_BelowDisplayed100() {
        XCTAssertTrue(BatteryMonitor.reachedBound(100, percentage: 97, fullyCharged: true))
        XCTAssertFalse(BatteryMonitor.reachedBound(100, percentage: 97, fullyCharged: false))
    }

    func testFullyCharged_NeverCountsTowardBoundsBelow100() {
        XCTAssertFalse(BatteryMonitor.reachedBound(60, percentage: 55, fullyCharged: true))
        XCTAssertFalse(BatteryMonitor.reachedBound(99, percentage: 55, fullyCharged: true))
    }
}
