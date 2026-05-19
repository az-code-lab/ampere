import XCTest
@testable import Ampere

/// `BatteryMonitor.amperageDirection` is the predicate behind
/// `publishStateIfNeeded`'s menu-bar gating decision. After making the menu
/// bar's animation direction sensitive to amperage sign (not just IOKit's
/// `isCharging`), the gate must invalidate on amperage sign flips too —
/// otherwise the discharge-startup transient would silently skip a menu-bar
/// re-render until `isCharging` finally caught up (up to a full slow poll
/// interval = 60 s).
final class AmperageDirectionTests: XCTestCase {

    func testPositiveAmperage_Returns1() {
        XCTAssertEqual(BatteryMonitor.amperageDirection(5.0), 1)
    }

    func testNegativeAmperage_ReturnsMinus1() {
        XCTAssertEqual(BatteryMonitor.amperageDirection(-5.0), -1)
    }

    func testZeroAmperage_Returns0() {
        XCTAssertEqual(BatteryMonitor.amperageDirection(0.0), 0)
    }

    func testNilAmperage_Returns0() {
        XCTAssertEqual(BatteryMonitor.amperageDirection(nil), 0)
    }

    /// The function must distinguish sign-flip events so the gating logic
    /// can detect them. These pairings simulate the transient we care about.
    func testSignFlip_DetectableByInequality() {
        XCTAssertNotEqual(
            BatteryMonitor.amperageDirection(5.0),
            BatteryMonitor.amperageDirection(-5.0)
        )
        XCTAssertNotEqual(
            BatteryMonitor.amperageDirection(5.0),
            BatteryMonitor.amperageDirection(0.0)
        )
        XCTAssertNotEqual(
            BatteryMonitor.amperageDirection(-5.0),
            BatteryMonitor.amperageDirection(nil)
        )
    }

    /// Within a single direction, magnitude changes don't matter — the
    /// menu bar only needs to re-render on direction *changes*. Pinning
    /// this prevents accidentally upgrading the function to return the
    /// raw amperage and triggering a noisy update on every poll.
    func testSameDirection_DifferentMagnitude_CompareEqual() {
        XCTAssertEqual(
            BatteryMonitor.amperageDirection(5.0),
            BatteryMonitor.amperageDirection(50.0)
        )
        XCTAssertEqual(
            BatteryMonitor.amperageDirection(-5.0),
            BatteryMonitor.amperageDirection(-50.0)
        )
        XCTAssertEqual(
            BatteryMonitor.amperageDirection(0.0),
            BatteryMonitor.amperageDirection(nil)
        )
    }
}
