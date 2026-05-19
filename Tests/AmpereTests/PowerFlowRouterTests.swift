import XCTest
@testable import Ampere

/// Pins the Sankey diagram's flow-routing invariant.
///
/// The router decides which of the four cases the diagram renders (and
/// therefore which nodes appear). Two regressions are worth nailing down:
///
/// 1. **AC dead but plugged in** — when the adapter is reported connected
///    but delivering exactly 0 W, the AC node must not render; routing
///    must collapse to `.batteryOnly` so we don't draw a dangling "0 W"
///    plug. (Originally surfaced as a stuck 0 W adapter node next to a
///    battery that was actually draining.)
///
/// 2. **`isCharging` vs current sign disagreement** — during the
///    "Discharge to Upper Bound" startup transient, IOKit's `isCharging`
///    reads false while the battery is still receiving current. The
///    router must not rely on `isCharging`; it should use `batteryWatts`'s
///    sign so the diagram stays consistent with the Battery Load card.
final class PowerFlowRouterTests: XCTestCase {

    // MARK: - Basic case selection

    func testOnBattery_NoAdapter() {
        XCTAssertEqual(
            PowerFlowRouter.compute(adapterConnected: false, adapterWatts: nil, batteryWatts: -12.0),
            .batteryOnly
        )
    }

    func testCharging_AcAndPositiveBatteryWatts() {
        XCTAssertEqual(
            PowerFlowRouter.compute(adapterConnected: true, adapterWatts: 60.0, batteryWatts: 40.0),
            .acToBoth
        )
    }

    func testAcAndBattery_WeakAdapter() {
        XCTAssertEqual(
            PowerFlowRouter.compute(adapterConnected: true, adapterWatts: 18.0, batteryWatts: -12.0),
            .acAndBattery
        )
    }

    func testAcOnly_BatteryIdle() {
        XCTAssertEqual(
            PowerFlowRouter.compute(adapterConnected: true, adapterWatts: 22.0, batteryWatts: 0.0),
            .acOnly
        )
    }

    // MARK: - Regressions

    /// Regression: with the adapter plugged in but reading 0 W, the router
    /// must collapse to `.batteryOnly` rather than `.acAndBattery`. Otherwise
    /// the diagram renders a useless "0 W" AC plug next to a real battery
    /// discharge ribbon.
    func testDeadAdapter_PluggedButZeroWatts_RoutesToBatteryOnly() {
        XCTAssertEqual(
            PowerFlowRouter.compute(adapterConnected: true, adapterWatts: 0.0, batteryWatts: -8.0),
            .batteryOnly
        )
    }

    /// Regression: the startup transient for "Discharge to Upper Bound"
    /// (IOKit `isCharging` is false, but battery is still gaining current
    /// because the SMC hasn't engaged yet) must still classify as
    /// `.acToBoth` based on the positive `batteryWatts` reading. The diagram
    /// would otherwise fall to `.acOnly` and the battery branch would vanish
    /// even though the cards still show the battery being charged.
    func testDischargeStartupTransient_PositiveBatteryWatts_RoutesToAcToBoth() {
        XCTAssertEqual(
            PowerFlowRouter.compute(adapterConnected: true, adapterWatts: 86.9, batteryWatts: 64.7),
            .acToBoth
        )
    }

    // MARK: - Sub-watt readings

    /// Sub-watt readings like 0.3 W are real flows and must not get rounded
    /// down to "no flow". The router uses strict-zero comparisons rather
    /// than a noise floor for this reason — small positive `batteryWatts`
    /// still routes to `.acToBoth`.
    func testSubWatt_PositiveBatteryWatts_RoutesToAcToBoth() {
        XCTAssertEqual(
            PowerFlowRouter.compute(adapterConnected: true, adapterWatts: 22.0, batteryWatts: 0.3),
            .acToBoth
        )
    }

    /// Sub-watt negative `batteryWatts` likewise routes to `.acAndBattery`.
    func testSubWatt_NegativeBatteryWatts_RoutesToAcAndBattery() {
        XCTAssertEqual(
            PowerFlowRouter.compute(adapterConnected: true, adapterWatts: 22.0, batteryWatts: -0.3),
            .acAndBattery
        )
    }

    // MARK: - nil handling

    /// Old Macs without PowerTelemetryData report `adapterWatts == nil`.
    /// The router assumes the cable is delivering an unknown but non-zero
    /// amount and falls through to the standard battery-sign branching.
    func testNilAdapterWatts_TreatedAsDelivering() {
        XCTAssertEqual(
            PowerFlowRouter.compute(adapterConnected: true, adapterWatts: nil, batteryWatts: 12.0),
            .acToBoth
        )
        XCTAssertEqual(
            PowerFlowRouter.compute(adapterConnected: true, adapterWatts: nil, batteryWatts: -12.0),
            .acAndBattery
        )
        XCTAssertEqual(
            PowerFlowRouter.compute(adapterConnected: true, adapterWatts: nil, batteryWatts: 0.0),
            .acOnly
        )
    }

    /// nil `batteryWatts` (rare — voltage or amperage unreadable) is treated
    /// as zero flow rather than rerouted, so an AC-connected machine with
    /// unknown battery telemetry still shows `.acOnly`.
    func testNilBatteryWatts_OnAC_RoutesToAcOnly() {
        XCTAssertEqual(
            PowerFlowRouter.compute(adapterConnected: true, adapterWatts: 22.0, batteryWatts: nil),
            .acOnly
        )
    }
}
