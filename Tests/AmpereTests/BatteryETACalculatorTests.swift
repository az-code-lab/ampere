import XCTest
@testable import Ampere

/// Pins the ETA-label format and the sanity-cap behavior. Two flavors:
/// charge-to-target ("Xm to NN%" / "Xm to full") and discharge-to-target
/// ("Xm to NN%" / "Xm remaining"). The cap on absurdly long answers prevents
/// near-zero amperage readings during state transitions from producing
/// "5000h 0m to full"-style nonsense labels.
final class BatteryETACalculatorTests: XCTestCase {

    // MARK: - chargingETA: format & target suffix

    /// Default scenario: gap = 30%, capacity 5000 mAh, charging at 3000 mA
    /// → 50 mAh per percent × 30% = 1500 mAh / 3000 mA = 0.5 h = 30 min.
    func testChargingETA_BasicMinutes() {
        XCTAssertEqual(
            BatteryETACalculator.chargingETA(
                percentage: 30, maxCapacity: 5000, amperage: 3000.0, target: 60
            ),
            "30m to 60%"
        )
    }

    /// target = 100 substitutes the "to full" suffix matching IOKit's
    /// historical wording.
    func testChargingETA_Target100_RendersToFull() {
        XCTAssertEqual(
            BatteryETACalculator.chargingETA(
                percentage: 30, maxCapacity: 5000, amperage: 3000.0, target: 100
            ),
            "1h 10m to full"
        )
    }

    /// Trickle charging near the cap: 1% gap, 5000 mAh battery, 2400 mA
    /// → 50 / 2400 h × 60 ≈ 1.25 min ⇒ rounds to 1 min.
    func testChargingETA_TinyGap_StillRenders() {
        XCTAssertEqual(
            BatteryETACalculator.chargingETA(
                percentage: 59, maxCapacity: 5000, amperage: 2400.0, target: 60
            ),
            "1m to 60%"
        )
    }

    /// Sub-minute answers use the "<1m" prefix rather than rounding to 0.
    func testChargingETA_SubMinute_Renders_LT1m() {
        // 1% gap, 5000 mAh, 6240 mA → 50 / 6240 × 60 ≈ 0.48 min → rounds to 0
        XCTAssertEqual(
            BatteryETACalculator.chargingETA(
                percentage: 59, maxCapacity: 5000, amperage: 6240.0, target: 60
            ),
            "<1m to 60%"
        )
    }

    // MARK: - chargingETA: guards

    func testChargingETA_AlreadyAtTarget_ReturnsEmpty() {
        XCTAssertEqual(
            BatteryETACalculator.chargingETA(
                percentage: 60, maxCapacity: 5000, amperage: 3000.0, target: 60
            ),
            ""
        )
    }

    func testChargingETA_NegativeAmperage_DischargeReading_ReturnsEmpty() {
        // Negative amperage means battery is actually draining; the
        // charging-ETA path is the wrong code path and must bail rather
        // than report nonsense.
        XCTAssertEqual(
            BatteryETACalculator.chargingETA(
                percentage: 30, maxCapacity: 5000, amperage: -3000.0, target: 60
            ),
            ""
        )
    }

    func testChargingETA_NilAmperage_ReturnsEmpty() {
        XCTAssertEqual(
            BatteryETACalculator.chargingETA(
                percentage: 30, maxCapacity: 5000, amperage: nil, target: 60
            ),
            ""
        )
    }

    func testChargingETA_ZeroCapacity_ReturnsEmpty() {
        XCTAssertEqual(
            BatteryETACalculator.chargingETA(
                percentage: 30, maxCapacity: 0, amperage: 3000.0, target: 60
            ),
            ""
        )
    }

    // MARK: - chargingETA: sanity cap

    /// Regression: a near-zero positive amperage (e.g. sensor artifact during
    /// transition) used to produce labels like "5000h 0m to full". The
    /// 7-day cap inside `safeMinutes` collapses those to "" so we fall back
    /// to IOKit's value or no display.
    func testChargingETA_AbsurdlySmallAmperage_CapsToEmpty() {
        // 50% gap, 5000 mAh, 0.1 mA → 2500 / 0.1 × 60 = 1.5M minutes.
        // Way over the 7-day (10,080 min) ceiling — must return "".
        XCTAssertEqual(
            BatteryETACalculator.chargingETA(
                percentage: 50, maxCapacity: 5000, amperage: 0.1, target: 100
            ),
            ""
        )
    }

    // MARK: - dischargeETA: format & target suffix

    /// Default scenario: gap = 30%, capacity 5000 mAh, draining at 1000 mA
    /// → 1500 mAh / 1000 mA = 1.5 h = 90 min.
    func testDischargeETA_BasicMinutes() {
        XCTAssertEqual(
            BatteryETACalculator.dischargeETA(
                percentage: 60, maxCapacity: 5000, amperage: -1000.0, target: 30
            ),
            "1h 30m to 30%"
        )
    }

    /// target = 0 substitutes the "remaining" suffix matching IOKit's
    /// `TimeToEmpty` formatting for the on-battery path.
    func testDischargeETA_Target0_RendersRemaining() {
        XCTAssertEqual(
            BatteryETACalculator.dischargeETA(
                percentage: 60, maxCapacity: 5000, amperage: -1000.0, target: 0
            ),
            "3h 0m remaining"
        )
    }

    // MARK: - dischargeETA: guards

    func testDischargeETA_AlreadyAtTarget_ReturnsEmpty() {
        XCTAssertEqual(
            BatteryETACalculator.dischargeETA(
                percentage: 30, maxCapacity: 5000, amperage: -1000.0, target: 30
            ),
            ""
        )
    }

    func testDischargeETA_PositiveAmperage_ChargingReading_ReturnsEmpty() {
        // Positive amperage means the battery is actually charging — the
        // discharge-ETA path is the wrong code path.
        XCTAssertEqual(
            BatteryETACalculator.dischargeETA(
                percentage: 60, maxCapacity: 5000, amperage: 1000.0, target: 30
            ),
            ""
        )
    }

    func testDischargeETA_NilAmperage_ReturnsEmpty() {
        XCTAssertEqual(
            BatteryETACalculator.dischargeETA(
                percentage: 60, maxCapacity: 5000, amperage: nil, target: 30
            ),
            ""
        )
    }

    // MARK: - formatMinutes

    func testFormatMinutes_Boundary_0Min_RendersLT1m() {
        XCTAssertEqual(BatteryETACalculator.formatMinutes(0, suffix: "to 60%"), "<1m to 60%")
    }

    func testFormatMinutes_Boundary_59Min_RendersAsMinutes() {
        XCTAssertEqual(BatteryETACalculator.formatMinutes(59, suffix: "to 60%"), "59m to 60%")
    }

    func testFormatMinutes_Boundary_60Min_RendersAs1h0m() {
        XCTAssertEqual(BatteryETACalculator.formatMinutes(60, suffix: "to 60%"), "1h 0m to 60%")
    }

    func testFormatMinutes_HoursAndMinutes() {
        XCTAssertEqual(BatteryETACalculator.formatMinutes(127, suffix: "remaining"), "2h 7m remaining")
    }
}
