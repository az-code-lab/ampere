import XCTest
@testable import Ampere
import Shared

/// The macOS charge-limit path used on firmware without CHTE: marker
/// format, `pmset -g battlimit` parsing, and the pure intent/target rules.
final class NativeChargeLimitTests: XCTestCase {
    func testMarkerRoundTrip() {
        let originals = NativeChargeLimit.Originals(featureState: 0, limit: 100)
        XCTAssertEqual(NativeChargeLimit.markerString(originals), "0 100")
        XCTAssertEqual(NativeChargeLimit.parseMarker("0 100"), originals)
        let absent = NativeChargeLimit.Originals(featureState: nil, limit: nil)
        XCTAssertEqual(NativeChargeLimit.markerString(absent), "- -")
        XCTAssertEqual(NativeChargeLimit.parseMarker("- -\n"), absent)
        XCTAssertEqual(NativeChargeLimit.parseMarker("1 -"), NativeChargeLimit.Originals(featureState: 1, limit: nil))
        XCTAssertTrue(NativeChargeLimit.parseMarker("1 80")!.featureWasOn)
        XCTAssertFalse(NativeChargeLimit.parseMarker("0 80")!.featureWasOn)
    }

    func testMarkerParseRejectsGarbage() {
        XCTAssertNil(NativeChargeLimit.parseMarker(""))
        XCTAssertNil(NativeChargeLimit.parseMarker("1"))
        XCTAssertNil(NativeChargeLimit.parseMarker("on 80"))
        XCTAssertNil(NativeChargeLimit.parseMarker("1 80 extra"))
    }

    func testValidLimitRange() {
        XCTAssertTrue(NativeChargeLimit.validLimit(1))
        XCTAssertTrue(NativeChargeLimit.validLimit(60))
        XCTAssertTrue(NativeChargeLimit.validLimit(100))
        XCTAssertFalse(NativeChargeLimit.validLimit(0))
        XCTAssertFalse(NativeChargeLimit.validLimit(101))
    }

    func testBattlimitParsing() {
        let engaged = """
        Battery level limits:
        (
                {
                Terminated = 0;
                chargeSocLimitDrain = 1;
                chargeSocLimitOwner = 471;
                chargeSocLimitReason = manualChargeLimit;
                chargeSocLimitSoc = 60;
            },
                {
                chargeSocLimitOwner = 0;
                chargeSocLimitSoc = 60;
            }
        )
        """
        XCTAssertEqual(NativeChargeLimit.registeredLimits(inBattlimitOutput: engaged), [60, 60])
        XCTAssertEqual(NativeChargeLimit.registeredLimits(inBattlimitOutput: "No battery level limits set\n"), [])
        XCTAssertEqual(NativeChargeLimit.registeredLimits(inBattlimitOutput: ""), [])
    }

    // MARK: - Intent

    private func intent(auto: Bool = true, ac: Bool = true, pct: Int, paused: Bool = true,
                        ctu: Bool = false, ctf: Bool = false, discharge: Bool = false) -> BatteryMonitor.NativeLimitIntent {
        BatteryMonitor.nativeLimitIntent(
            autoManageEnabled: auto, adapterConnected: ac, percentage: pct, upperBound: 60,
            chargingPaused: paused, chargeToUpperBound: ctu, chargeToFull: ctf, dischargeEnabled: discharge)
    }

    func testIntent_AutoModeOnAC() {
        XCTAssertEqual(intent(pct: 50), .hold)
        XCTAssertEqual(intent(pct: 50, paused: false, ctu: true), .chargeTo(60))
        XCTAssertEqual(intent(pct: 50, paused: false, ctf: true), .chargeTo(100))
        XCTAssertEqual(intent(pct: 80), .hold, "Above upper without the discharge preference holds where it is")
        XCTAssertEqual(intent(pct: 80, discharge: true), .drainTo(60))
        XCTAssertEqual(intent(pct: 60, discharge: true), .hold, "At the bound there is nothing to drain")
        XCTAssertEqual(intent(pct: 90, paused: false, ctf: true, discharge: true), .chargeTo(100),
                       "A full charge outranks the discharge preference")
    }

    func testIntent_AutoModeOnBatteryKeepsTheNextPlugInReady() {
        XCTAssertEqual(intent(ac: false, pct: 50), .hold)
        XCTAssertEqual(intent(ac: false, pct: 30, paused: false, ctu: true), .chargeTo(60))
        XCTAssertEqual(intent(ac: false, pct: 80, discharge: true), .hold, "No drain off AC")
    }

    func testIntent_ManualMode() {
        XCTAssertEqual(intent(auto: false, pct: 50, paused: true), .hold)
        XCTAssertEqual(intent(auto: false, pct: 50, paused: false), .release)
        XCTAssertEqual(intent(auto: false, ac: false, pct: 50, paused: true), .release,
                       "A manual pause only holds while on AC")
    }

    // MARK: - Target

    private func target(_ intent: BatteryMonitor.NativeLimitIntent, pct: Int, ac: Bool = true,
                        previous: BatteryMonitor.NativeLimitIntent? = nil, written: Int? = nil) -> Int? {
        BatteryMonitor.nativeLimitTarget(intent: intent, percentage: pct, adapterConnected: ac,
                                         previousIntent: previous, previousTarget: written)
    }

    func testTarget_ChargeDrainAndRelease() {
        XCTAssertEqual(target(.chargeTo(60), pct: 30), 60)
        XCTAssertEqual(target(.chargeTo(100), pct: 30), 100)
        XCTAssertEqual(target(.drainTo(60), pct: 80), 60)
        XCTAssertNil(target(.release, pct: 50, previous: .hold, written: 50))
    }

    func testTarget_HoldIsStickyOnACAndTracksDownOffAC() {
        XCTAssertEqual(target(.hold, pct: 50), 50, "A fresh hold pins the current level")
        XCTAssertEqual(target(.hold, pct: 51, previous: .hold, written: 50), 50,
                       "A level that ticks up while the firmware settles is not chased")
        XCTAssertEqual(target(.hold, pct: 70, previous: .drainTo(60), written: 60), 70,
                       "Turning discharge off mid-drain holds where the battery is now")
        XCTAssertEqual(target(.hold, pct: 45, ac: false, previous: .hold, written: 50), 45,
                       "Off AC the hold follows the level down")
        XCTAssertEqual(target(.hold, pct: 47, ac: false, previous: .hold, written: 45), 45,
                       "...and never back up")
    }
}
