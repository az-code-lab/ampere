import XCTest
@testable import Ampere

/// Pins the invariant that drives stat-card tint colors: the chosen
/// `BatteryMode` must match the actual current direction so the cards
/// don't tint orange (discharge) while the Sankey diagram is showing
/// green ribbons (charging) — the inconsistency that surfaced during
/// the "Discharge to Upper Bound" startup transient.
final class BatteryModeRouterTests: XCTestCase {

    // MARK: - Amperage-driven branches (the source of truth)

    func testPositiveAmperage_AlwaysCharging() {
        // Even with isCharging false and activeDischarging true (the
        // discharge-startup transient), positive amperage means the
        // battery is gaining charge — tint must reflect that.
        XCTAssertEqual(
            BatteryModeRouter.compute(
                amperage: 5.0,
                isCharging: false,
                activeDischarging: true,
                adapterConnected: true
            ),
            .charging
        )
    }

    func testNegativeAmperage_OnAC_TintsAsDischarging() {
        // Battery is supplying power while AC is plugged (weak-adapter
        // case) — should tint as if discharging, matching the orange
        // ribbon the diagram draws.
        XCTAssertEqual(
            BatteryModeRouter.compute(
                amperage: -3.0,
                isCharging: false,
                activeDischarging: false,
                adapterConnected: true
            ),
            .discharging
        )
    }

    func testNegativeAmperage_NoAC_OnBattery() {
        XCTAssertEqual(
            BatteryModeRouter.compute(
                amperage: -8.0,
                isCharging: false,
                activeDischarging: false,
                adapterConnected: false
            ),
            .onBattery
        )
    }

    // MARK: - Fallback when amperage is unknown

    /// When amperage is unreadable (nil), fall back to the legacy flag-based
    /// branches. This is the path old Macs without telemetry hit, and where
    /// `isCharging` / `activeDischarging` are the only signal we have.
    func testNilAmperage_FallsBackToIsCharging() {
        XCTAssertEqual(
            BatteryModeRouter.compute(
                amperage: nil,
                isCharging: true,
                activeDischarging: false,
                adapterConnected: true
            ),
            .charging
        )
    }

    func testNilAmperage_FallsBackToActiveDischarging() {
        XCTAssertEqual(
            BatteryModeRouter.compute(
                amperage: nil,
                isCharging: false,
                activeDischarging: true,
                adapterConnected: true
            ),
            .discharging
        )
    }

    func testNilAmperage_AdapterButIdle_OnACNotCharging() {
        XCTAssertEqual(
            BatteryModeRouter.compute(
                amperage: nil,
                isCharging: false,
                activeDischarging: false,
                adapterConnected: true
            ),
            .onACNotCharging
        )
    }

    func testNilAmperage_NoAdapter_OnBattery() {
        XCTAssertEqual(
            BatteryModeRouter.compute(
                amperage: nil,
                isCharging: false,
                activeDischarging: false,
                adapterConnected: false
            ),
            .onBattery
        )
    }

    /// Zero amperage with adapter connected falls through to the flag-based
    /// branch and ends up as `.onACNotCharging` (steady state, AC supplies
    /// computer, no battery flow).
    func testZeroAmperage_OnAC_OnACNotCharging() {
        XCTAssertEqual(
            BatteryModeRouter.compute(
                amperage: 0.0,
                isCharging: false,
                activeDischarging: false,
                adapterConnected: true
            ),
            .onACNotCharging
        )
    }
}
