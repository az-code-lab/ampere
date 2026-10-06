import XCTest
@testable import Ampere

/// Pins the predicate that drops adapter telemetry macOS published before
/// the SMC had sampled the input rail. The AppleSmartBattery registry entry
/// is rewritten about once a minute, and the first snapshot after a wake
/// can say 0 W in while the battery supplies nothing, which no running Mac
/// can do. Seen on a Mac that had just woken: every adapter card at zero
/// and the diagram showing the Mac on battery while it was on AC. The
/// reading a dead adapter gives, 0 W in with the battery draining, must
/// survive, as must an unplugged Mac's real 0 W.
final class AdapterTelemetryTests: XCTestCase {

    func testZeroInput_BatteryIdle_IsUnmeasured() {
        XCTAssertTrue(BatteryMonitor.adapterTelemetryUnmeasured(pluggedIn: true, adapterWatts: 0, amperage: 0))
    }

    func testZeroInput_BatteryUnknown_IsUnmeasured() {
        XCTAssertTrue(BatteryMonitor.adapterTelemetryUnmeasured(pluggedIn: true, adapterWatts: 0, amperage: nil))
    }

    func testZeroInput_BatteryCharging_IsUnmeasured() {
        XCTAssertTrue(BatteryMonitor.adapterTelemetryUnmeasured(pluggedIn: true, adapterWatts: 0, amperage: 1200))
    }

    func testZeroInput_BatteryDraining_IsADeadAdapter() {
        XCTAssertFalse(BatteryMonitor.adapterTelemetryUnmeasured(pluggedIn: true, adapterWatts: 0, amperage: -800))
    }

    func testMeasuredInput_IsKept() {
        XCTAssertFalse(BatteryMonitor.adapterTelemetryUnmeasured(pluggedIn: true, adapterWatts: 12.0, amperage: 0))
    }

    func testUnplugged_ZeroInputIsReal() {
        XCTAssertFalse(BatteryMonitor.adapterTelemetryUnmeasured(pluggedIn: false, adapterWatts: 0, amperage: 0))
    }

    func testNoTelemetry_NothingToDrop() {
        XCTAssertFalse(BatteryMonitor.adapterTelemetryUnmeasured(pluggedIn: true, adapterWatts: nil, amperage: 0))
    }
}
