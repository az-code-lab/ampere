import XCTest
@testable import Ampere
import Shared

/// Tests for the pure state-machine logic that decides what SMC state is
/// "correct" for a given combination of mode, bounds, charge level, and
/// toggles. These functions encode the rules that `refresh()` drives the
/// hardware toward, so they are the single source of truth for expected
/// behavior in both manual and auto mode.
final class HealthCheckTests: XCTestCase {

    // MARK: - Manual mode

    func testManualMode_Paused_RequiresInhibit() {
        XCTAssertTrue(BatteryMonitor.healthCheckManualMode(
            pauseButtonPaused: true, chie: SMC.chieNormalInt, chte: SMC.chteInhibitInt))
        XCTAssertFalse(BatteryMonitor.healthCheckManualMode(
            pauseButtonPaused: true, chie: SMC.chieNormalInt, chte: SMC.chteAllowInt))
    }

    func testManualMode_NotPaused_RequiresAllow() {
        XCTAssertTrue(BatteryMonitor.healthCheckManualMode(
            pauseButtonPaused: false, chie: SMC.chieNormalInt, chte: SMC.chteAllowInt))
        XCTAssertFalse(BatteryMonitor.healthCheckManualMode(
            pauseButtonPaused: false, chie: SMC.chieNormalInt, chte: SMC.chteInhibitInt))
    }

    func testManualMode_DischargeState_AlwaysUnhealthy() {
        // Manual mode must never leave CHIE in the discharge state
        XCTAssertFalse(BatteryMonitor.healthCheckManualMode(
            pauseButtonPaused: false, chie: SMC.chieDischargeInt, chte: SMC.chteAllowInt))
        XCTAssertFalse(BatteryMonitor.healthCheckManualMode(
            pauseButtonPaused: true, chie: SMC.chieDischargeInt, chte: SMC.chteInhibitInt))
    }

    // MARK: - Auto mode (discharge disabled)

    private func autoHealthy(
        pct: Int, lower: Int = 40, upper: Int = 60,
        chargeToUpperBound: Bool = false,
        chie: Int, chte: Int
    ) -> Bool {
        BatteryMonitor.healthCheckAutoMode(
            chargeLevel: pct, lowerBound: lower, upperBound: upper,
            dischargeEnabled: false, activeDischarging: false,
            chargeToUpperBound: chargeToUpperBound,
            chie: chie, chte: chte
        )
    }

    func testAutoMode_AboveUpperBound_ExpectsInhibit() {
        XCTAssertTrue(autoHealthy(pct: 65, chie: SMC.chieNormalInt, chte: SMC.chteInhibitInt))
        XCTAssertFalse(autoHealthy(pct: 65, chie: SMC.chieNormalInt, chte: SMC.chteAllowInt))
    }

    func testAutoMode_AtUpperBound_ExpectsInhibit() {
        XCTAssertTrue(autoHealthy(pct: 60, chie: SMC.chieNormalInt, chte: SMC.chteInhibitInt))
        XCTAssertFalse(autoHealthy(pct: 60, chie: SMC.chieNormalInt, chte: SMC.chteAllowInt))
    }

    func testAutoMode_BetweenBounds_NoChargeToUpper_ExpectsInhibit() {
        // Rule 3: between bounds, don't auto-charge unless explicitly requested
        XCTAssertTrue(autoHealthy(pct: 50, chargeToUpperBound: false,
                                  chie: SMC.chieNormalInt, chte: SMC.chteInhibitInt))
        XCTAssertFalse(autoHealthy(pct: 50, chargeToUpperBound: false,
                                   chie: SMC.chieNormalInt, chte: SMC.chteAllowInt))
    }

    func testAutoMode_BetweenBounds_ChargeToUpper_ExpectsAllow() {
        // Rule 1 in effect: user/system requested charge to upper bound
        XCTAssertTrue(autoHealthy(pct: 50, chargeToUpperBound: true,
                                  chie: SMC.chieNormalInt, chte: SMC.chteAllowInt))
        XCTAssertFalse(autoHealthy(pct: 50, chargeToUpperBound: true,
                                   chie: SMC.chieNormalInt, chte: SMC.chteInhibitInt))
    }

    func testAutoMode_AtLowerBound_NoChargeToUpper_ExpectsInhibit() {
        // At exactly lower bound counts as "between bounds" → inhibit
        XCTAssertTrue(autoHealthy(pct: 40, chargeToUpperBound: false,
                                  chie: SMC.chieNormalInt, chte: SMC.chteInhibitInt))
    }

    func testAutoMode_BelowLowerBound_ExpectsAllow() {
        // Rule 1: below lower bound → must allow charging regardless of chargeToUpperBound
        XCTAssertTrue(autoHealthy(pct: 38, chargeToUpperBound: false,
                                  chie: SMC.chieNormalInt, chte: SMC.chteAllowInt))
        XCTAssertTrue(autoHealthy(pct: 38, chargeToUpperBound: true,
                                  chie: SMC.chieNormalInt, chte: SMC.chteAllowInt))
        XCTAssertFalse(autoHealthy(pct: 38, chargeToUpperBound: false,
                                   chie: SMC.chieNormalInt, chte: SMC.chteInhibitInt))
    }

    func testAutoMode_StrayDischargeState_Unhealthy() {
        // If auto-discharge is disabled, CHIE must be normal regardless of level
        XCTAssertFalse(autoHealthy(pct: 50, chie: SMC.chieDischargeInt, chte: SMC.chteInhibitInt))
        XCTAssertFalse(autoHealthy(pct: 65, chie: SMC.chieDischargeInt, chte: SMC.chteInhibitInt))
        XCTAssertFalse(autoHealthy(pct: 38, chie: SMC.chieDischargeInt, chte: SMC.chteAllowInt))
    }

    // MARK: - Auto mode with discharge enabled

    private func autoHealthyDischarge(
        pct: Int, lower: Int = 40, upper: Int = 60,
        activeDischarging: Bool, chargeToUpperBound: Bool = false,
        chie: Int, chte: Int
    ) -> Bool {
        BatteryMonitor.healthCheckAutoMode(
            chargeLevel: pct, lowerBound: lower, upperBound: upper,
            dischargeEnabled: true, activeDischarging: activeDischarging,
            chargeToUpperBound: chargeToUpperBound,
            chie: chie, chte: chte
        )
    }

    func testAutoDischarge_Active_AboveUpper_ExpectsInhibitAndDischarge() {
        XCTAssertTrue(autoHealthyDischarge(
            pct: 75, activeDischarging: true,
            chie: SMC.chieDischargeInt, chte: SMC.chteInhibitInt))
        XCTAssertFalse(autoHealthyDischarge(
            pct: 75, activeDischarging: true,
            chie: SMC.chieNormalInt, chte: SMC.chteInhibitInt))
    }

    func testAutoDischarge_Active_AtUpperBound_StillExpectsDischarge() {
        // Transient: activeDischarging=true and pct=upperBound exactly
        // (battery just reached target but refresh hasn't stopped the daemon
        // yet). The check must still expect CHIE=discharge — the daemon's
        // SMC write persists until we explicitly clear it.
        XCTAssertTrue(autoHealthyDischarge(
            pct: 60, activeDischarging: true,
            chie: SMC.chieDischargeInt, chte: SMC.chteInhibitInt))
        XCTAssertFalse(autoHealthyDischarge(
            pct: 60, activeDischarging: true,
            chie: SMC.chieNormalInt, chte: SMC.chteInhibitInt))
    }

    func testAutoDischarge_Active_AcceptsEitherCHTE() {
        // Apple's SMC firmware on some Macs auto-clears CHTE while CHIE=0x08
        // is active. The health check must accept either CHTE value as long
        // as CHIE=discharge is set — otherwise affected users see a
        // perpetually-failing health check during normal discharge.
        XCTAssertTrue(autoHealthyDischarge(
            pct: 75, activeDischarging: true,
            chie: SMC.chieDischargeInt, chte: SMC.chteAllowInt))
        XCTAssertTrue(autoHealthyDischarge(
            pct: 75, activeDischarging: true,
            chie: SMC.chieDischargeInt, chte: SMC.chteInhibitInt))
        // Still rejects CHIE != discharge while activeDischarging
        XCTAssertFalse(autoHealthyDischarge(
            pct: 75, activeDischarging: true,
            chie: SMC.chieNormalInt, chte: SMC.chteAllowInt))
    }

    func testAutoDischarge_Inactive_BetweenBounds_ExpectsInhibit() {
        // Discharge-enabled but not currently discharging: between bounds → inhibit
        XCTAssertTrue(autoHealthyDischarge(
            pct: 55, activeDischarging: false, chargeToUpperBound: false,
            chie: SMC.chieNormalInt, chte: SMC.chteInhibitInt))
    }

    func testAutoDischarge_Inactive_BetweenBounds_ChargeToUpper_ExpectsAllow() {
        XCTAssertTrue(autoHealthyDischarge(
            pct: 55, activeDischarging: false, chargeToUpperBound: true,
            chie: SMC.chieNormalInt, chte: SMC.chteAllowInt))
    }

    func testAutoDischarge_Inactive_BelowLower_ExpectsAllow() {
        XCTAssertTrue(autoHealthyDischarge(
            pct: 38, activeDischarging: false,
            chie: SMC.chieNormalInt, chte: SMC.chteAllowInt))
    }

    // MARK: - expectedSMCValues

    func testExpectedSMC_ManualMode_Paused() {
        let v = BatteryMonitor.expectedSMCValues(
            autoManageEnabled: false, pauseButtonPaused: true,
            chargeLevel: 50, lowerBound: 40, upperBound: 60,
            dischargeEnabled: false, activeDischarging: false,
            chargeToUpperBound: false)
        XCTAssertEqual(v.chte, SMC.chteInhibitHex)
        XCTAssertEqual(v.chie, SMC.chieNormalHex)
    }

    func testExpectedSMC_ManualMode_NotPaused() {
        let v = BatteryMonitor.expectedSMCValues(
            autoManageEnabled: false, pauseButtonPaused: false,
            chargeLevel: 50, lowerBound: 40, upperBound: 60,
            dischargeEnabled: false, activeDischarging: false,
            chargeToUpperBound: false)
        XCTAssertEqual(v.chte, SMC.chteAllowHex)
        XCTAssertEqual(v.chie, SMC.chieNormalHex)
    }

    func testExpectedSMC_AutoMode_BelowLower() {
        let v = BatteryMonitor.expectedSMCValues(
            autoManageEnabled: true, pauseButtonPaused: false,
            chargeLevel: 38, lowerBound: 40, upperBound: 60,
            dischargeEnabled: false, activeDischarging: false,
            chargeToUpperBound: false)
        XCTAssertEqual(v.chte, SMC.chteAllowHex)
        XCTAssertEqual(v.chie, SMC.chieNormalHex)
    }

    func testExpectedSMC_AutoMode_BetweenBounds_NoChargeToUpper() {
        let v = BatteryMonitor.expectedSMCValues(
            autoManageEnabled: true, pauseButtonPaused: false,
            chargeLevel: 50, lowerBound: 40, upperBound: 60,
            dischargeEnabled: false, activeDischarging: false,
            chargeToUpperBound: false)
        XCTAssertEqual(v.chte, SMC.chteInhibitHex)
    }

    func testExpectedSMC_AutoMode_BetweenBounds_ChargeToUpper() {
        let v = BatteryMonitor.expectedSMCValues(
            autoManageEnabled: true, pauseButtonPaused: false,
            chargeLevel: 50, lowerBound: 40, upperBound: 60,
            dischargeEnabled: false, activeDischarging: false,
            chargeToUpperBound: true)
        XCTAssertEqual(v.chte, SMC.chteAllowHex)
    }

    func testExpectedSMC_AutoMode_AboveUpper() {
        let v = BatteryMonitor.expectedSMCValues(
            autoManageEnabled: true, pauseButtonPaused: false,
            chargeLevel: 65, lowerBound: 40, upperBound: 60,
            dischargeEnabled: false, activeDischarging: false,
            chargeToUpperBound: false)
        XCTAssertEqual(v.chte, SMC.chteInhibitHex)
    }

    func testExpectedSMC_AutoMode_ActivelyDischarging() {
        let v = BatteryMonitor.expectedSMCValues(
            autoManageEnabled: true, pauseButtonPaused: false,
            chargeLevel: 75, lowerBound: 40, upperBound: 60,
            dischargeEnabled: true, activeDischarging: true,
            chargeToUpperBound: false)
        XCTAssertEqual(v.chte, SMC.chteInhibitHex)
        XCTAssertEqual(v.chie, SMC.chieDischargeHex)
    }

    // MARK: - Rule cross-check: health check and expectedSMCValues agree

    func testRuleConsistency_AutoMode_Sweep() {
        // For every (level, chargeToUpperBound) combination in auto mode, the
        // values returned by expectedSMCValues must be exactly the values that
        // healthCheckAutoMode considers healthy. A mismatch would mean the UI
        // and the state machine disagree on what "correct" looks like.
        for pct in [10, 39, 40, 45, 50, 59, 60, 75] {
            for ctu in [false, true] {
                let expected = BatteryMonitor.expectedSMCValues(
                    autoManageEnabled: true, pauseButtonPaused: false,
                    chargeLevel: pct, lowerBound: 40, upperBound: 60,
                    dischargeEnabled: false, activeDischarging: false,
                    chargeToUpperBound: ctu)
                let chteInt = (expected.chte == SMC.chteInhibitHex) ? SMC.chteInhibitInt : SMC.chteAllowInt
                let chieInt = SMC.chieNormalInt
                XCTAssertTrue(
                    BatteryMonitor.healthCheckAutoMode(
                        chargeLevel: pct, lowerBound: 40, upperBound: 60,
                        dischargeEnabled: false, activeDischarging: false,
                        chargeToUpperBound: ctu,
                        chie: chieInt, chte: chteInt),
                    "expectedSMCValues and healthCheckAutoMode disagree at pct=\(pct) ctu=\(ctu)")
            }
        }
    }

    func testRuleConsistency_ManualMode_Sweep() {
        for paused in [false, true] {
            let expected = BatteryMonitor.expectedSMCValues(
                autoManageEnabled: false, pauseButtonPaused: paused,
                chargeLevel: 50, lowerBound: 40, upperBound: 60,
                dischargeEnabled: false, activeDischarging: false,
                chargeToUpperBound: false)
            let chteInt = (expected.chte == SMC.chteInhibitHex) ? SMC.chteInhibitInt : SMC.chteAllowInt
            XCTAssertTrue(
                BatteryMonitor.healthCheckManualMode(
                    pauseButtonPaused: paused, chie: SMC.chieNormalInt, chte: chteInt),
                "expectedSMCValues and healthCheckManualMode disagree at paused=\(paused)")
        }
    }

    func testRuleConsistency_AutoMode_DischargeEnabled_Sweep() {
        // Same idea as the discharge-disabled sweep, but with discharge enabled
        // and active/inactive permutations. Guards against drift between the
        // discharge-enabled branches of expectedSMCValues and healthCheckAutoMode.
        for pct in [10, 39, 40, 45, 50, 59, 60, 65, 75] {
            for ctu in [false, true] {
                for active in [false, true] {
                    let expected = BatteryMonitor.expectedSMCValues(
                        autoManageEnabled: true, pauseButtonPaused: false,
                        chargeLevel: pct, lowerBound: 40, upperBound: 60,
                        dischargeEnabled: true, activeDischarging: active,
                        chargeToUpperBound: ctu)
                    let chteInt = (expected.chte == SMC.chteInhibitHex) ? SMC.chteInhibitInt : SMC.chteAllowInt
                    let chieInt = (expected.chie == SMC.chieDischargeHex) ? SMC.chieDischargeInt : SMC.chieNormalInt
                    XCTAssertTrue(
                        BatteryMonitor.healthCheckAutoMode(
                            chargeLevel: pct, lowerBound: 40, upperBound: 60,
                            dischargeEnabled: true, activeDischarging: active,
                            chargeToUpperBound: ctu,
                            chie: chieInt, chte: chteInt),
                        "expectedSMCValues and healthCheckAutoMode disagree at pct=\(pct) ctu=\(ctu) active=\(active)")
                }
            }
        }
    }

    // MARK: - chteRepairOp (health check self-repair)

    func testChteRepair_DriftToAllowWhilePaused_RepairsInhibit() {
        // The field case: firmware/PD renegotiation reset CHTE to allow
        // while the app is holding at/above the upper bound. The state
        // machine is edge-triggered and won't re-issue the inhibit; the
        // health check must.
        XCTAssertEqual(
            BatteryMonitor.chteRepairOp(
                chteMatch: false, chieMatch: true, chie: SMC.chieNormalInt,
                expectedChte: SMC.chteInhibitHex, activeDischarging: false),
            .inhibit)
    }

    func testChteRepair_DriftToInhibitMidCharge_RepairsAllow() {
        // The reverse drift: CHTE flipped to inhibit while a charge-to-upper
        // is supposed to be running — without repair the charge silently
        // never finishes.
        XCTAssertEqual(
            BatteryMonitor.chteRepairOp(
                chteMatch: false, chieMatch: true, chie: SMC.chieNormalInt,
                expectedChte: SMC.chteAllowHex, activeDischarging: false),
            .allow)
    }

    func testChteRepair_CHTEMatches_NoRepair() {
        XCTAssertNil(BatteryMonitor.chteRepairOp(
            chteMatch: true, chieMatch: true, chie: SMC.chieNormalInt,
            expectedChte: SMC.chteInhibitHex, activeDischarging: false))
    }

    func testChteRepair_CHIEMismatch_NoRepair() {
        // A CHIE problem means a discharge failed to start or stop — that
        // belongs to the state machine (sleep overrides, watchdog), not to
        // a bare SMC write from the health check.
        XCTAssertNil(BatteryMonitor.chteRepairOp(
            chteMatch: false, chieMatch: false, chie: SMC.chieNormalInt,
            expectedChte: SMC.chteInhibitHex, activeDischarging: false))
    }

    func testChteRepair_DischargeCHIE_NoRepair() {
        // chieMatch=true with chie=discharge (expected discharge, matching)
        // must still not repair: during discharge CHTE is firmware noise.
        XCTAssertNil(BatteryMonitor.chteRepairOp(
            chteMatch: false, chieMatch: true, chie: SMC.chieDischargeInt,
            expectedChte: SMC.chteInhibitHex, activeDischarging: false))
    }

    func testChteRepair_ActiveDischarging_NoRepair() {
        XCTAssertNil(BatteryMonitor.chteRepairOp(
            chteMatch: false, chieMatch: true, chie: SMC.chieNormalInt,
            expectedChte: SMC.chteInhibitHex, activeDischarging: true))
    }
}
