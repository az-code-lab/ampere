import XCTest
@testable import Ampere

/// Pins the *target-selection* logic in `displayedTimeRemaining`. The
/// formatting itself is covered by `BatteryETACalculatorTests`; here we
/// verify which target each (autoManage, activeDischarging) combination
/// aims at, since the charge ceiling / discharge floor changes with mode.
final class TimeRemainingRouterTests: XCTestCase {

    // MARK: - Charging targets

    /// Auto-manage on, charging → ETA targets the upper bound (not 100 %).
    /// This is the case that used to read "to full" before the upper-bound
    /// rewiring; pinning it here is the regression guard.
    func testCharging_AutoManage_TargetsUpperBound() {
        // gap = 60-30 = 30%; 5000 mAh; 3000 mA → 30m to 60%
        let label = TimeRemainingRouter.label(
            percentage: 30, maxCapacity: 5000, amperage: 3000.0,
            autoManageEnabled: true, activeDischarging: false, upperBound: 60
        )
        XCTAssertEqual(label, "30m to 60%")
    }

    /// Auto-manage off → target falls back to 100 % ("to full"). This is
    /// the legacy IOKit behavior and the path manual-mode users see.
    func testCharging_Manual_TargetsFull() {
        let label = TimeRemainingRouter.label(
            percentage: 30, maxCapacity: 5000, amperage: 3000.0,
            autoManageEnabled: false, activeDischarging: false, upperBound: 60
        )
        XCTAssertEqual(label, "1h 10m to full")
    }

    /// Even when upper bound is 100 (no cap), auto-manage routes through the
    /// upper-bound target — which lands on "to full" via the formatter's
    /// `target == 100` suffix mapping. The user dragging the slider to 100
    /// must see a "to full" ETA, not "to 100%".
    func testCharging_AutoManage_UpperBound100_RendersToFull() {
        let label = TimeRemainingRouter.label(
            percentage: 30, maxCapacity: 5000, amperage: 3000.0,
            autoManageEnabled: true, activeDischarging: false, upperBound: 100
        )
        XCTAssertEqual(label, "1h 10m to full")
    }

    // MARK: - Discharging targets

    /// Active discharge ("Discharge to Upper Bound") → ETA targets the
    /// upper bound. With auto-manage off this branch should still pick the
    /// upper bound since `activeDischarging` is what's actually running.
    func testDischarging_Active_TargetsUpperBound() {
        // gap = 80-60 = 20%; 5000 mAh; 1000 mA → 60m = 1h 0m to 60%
        let label = TimeRemainingRouter.label(
            percentage: 80, maxCapacity: 5000, amperage: -1000.0,
            autoManageEnabled: true, activeDischarging: true, upperBound: 60
        )
        XCTAssertEqual(label, "1h 0m to 60%")
    }

    /// Natural discharge (on battery or AC-too-weak) → ETA targets 0 %
    /// and uses the "remaining" suffix to match IOKit's `TimeToEmpty`
    /// wording.
    func testDischarging_Natural_TargetsZero_Remaining() {
        // gap = 60; 5000 mAh; 1000 mA → 180m = 3h 0m remaining
        let label = TimeRemainingRouter.label(
            percentage: 60, maxCapacity: 5000, amperage: -1000.0,
            autoManageEnabled: false, activeDischarging: false, upperBound: 60
        )
        XCTAssertEqual(label, "3h 0m remaining")
    }

    // MARK: - Idle / unknown

    /// Zero amperage = no current flow → caller falls back to IOKit's value,
    /// so we report "" here.
    func testZeroAmperage_ReturnsEmpty() {
        let label = TimeRemainingRouter.label(
            percentage: 60, maxCapacity: 5000, amperage: 0.0,
            autoManageEnabled: true, activeDischarging: false, upperBound: 80
        )
        XCTAssertEqual(label, "")
    }

    func testNilAmperage_ReturnsEmpty() {
        let label = TimeRemainingRouter.label(
            percentage: 60, maxCapacity: 5000, amperage: nil,
            autoManageEnabled: true, activeDischarging: false, upperBound: 80
        )
        XCTAssertEqual(label, "")
    }
}
