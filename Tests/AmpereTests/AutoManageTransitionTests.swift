import XCTest
@testable import Ampere
import Shared

/// End-to-end transition tests for the auto-manage state machine.
///
/// These tests simulate sequences of events (plug/unplug, battery drain,
/// battery charge) by repeatedly invoking the pure `evaluateAutoManageStep`
/// function — the same function `refresh()` uses in production — and
/// asserting that the resulting state and issued SMC actions match the
/// documented rules:
///
///   Rule 1 — battery falls below lower bound on AC (or is already below
///            lower bound when AC is reconnected) → charge all the way to
///            the upper bound.
///   Rule 2 — AC disconnected while charging above the lower bound → stop
///            at the point of interruption; do not auto-charge past the
///            lower bound on reconnect unless the user explicitly toggles.
///   Rule 3 — between bounds, never auto-charge to upper unless user asks.
final class AutoManageTransitionTests: XCTestCase {

    /// Thin harness that holds the simulated auto-manage state across steps
    /// and records the SMC commands issued, so assertions can inspect the
    /// exact command sequence a run produced.
    private final class Simulator {
        var state: BatteryMonitor.AutoManageState
        let lowerBound: Int
        let upperBound: Int
        private(set) var issued: [BatteryMonitor.AutoManageAction] = []

        init(
            chargingPaused: Bool,
            chargeToUpperBound: Bool = false,
            chargeToFull: Bool = false,
            lastAdapterConnected: Bool? = nil,
            lowerBound: Int = 40,
            upperBound: Int = 60
        ) {
            self.state = BatteryMonitor.AutoManageState(
                chargingPaused: chargingPaused,
                chargeToUpperBound: chargeToUpperBound,
                chargeToFull: chargeToFull,
                lastAdapterConnected: lastAdapterConnected
            )
            self.lowerBound = lowerBound
            self.upperBound = upperBound
        }

        /// Run one refresh() cycle with the given inputs.
        @discardableResult
        func step(
            percentage: Int,
            adapterConnected: Bool,
            autoManageEnabled: Bool = true,
            fullyCharged: Bool = false
        ) -> BatteryMonitor.AutoManageAction {
            let inputs = BatteryMonitor.AutoManageInputs(
                autoManageEnabled: autoManageEnabled,
                adapterConnected: adapterConnected,
                percentage: percentage,
                lowerBound: lowerBound,
                upperBound: upperBound,
                fullyCharged: fullyCharged
            )
            let decision = BatteryMonitor.evaluateAutoManageStep(state: state, inputs: inputs)
            state = decision.newState
            if decision.action != .none {
                issued.append(decision.action)
            }
            return decision.action
        }

        /// Run refresh() repeatedly until the state stops changing, to model
        /// refresh() calling itself recursively in the production callback.
        func stepUntilSettled(
            percentage: Int,
            adapterConnected: Bool,
            autoManageEnabled: Bool = true,
            maxIterations: Int = 10
        ) {
            var previous = state
            for _ in 0..<maxIterations {
                _ = step(percentage: percentage,
                         adapterConnected: adapterConnected,
                         autoManageEnabled: autoManageEnabled)
                if state == previous { return }
                previous = state
            }
            XCTFail("State did not settle within \(maxIterations) iterations")
        }

        /// Simulate battery charging from current → target, one percent at a
        /// time, running a refresh cycle at each level with AC connected.
        func chargeFrom(_ start: Int, to target: Int) {
            var pct = start
            while pct <= target {
                _ = step(percentage: pct, adapterConnected: true)
                // Apply settling in case the action triggered further state
                // transitions that would re-fire on the next refresh tick.
                stepUntilSettled(percentage: pct, adapterConnected: true)
                pct += 1
            }
        }

        /// Simulate battery draining from current → target on battery power.
        func drainFrom(_ start: Int, to target: Int) {
            var pct = start
            while pct >= target {
                _ = step(percentage: pct, adapterConnected: false)
                pct -= 1
            }
        }
    }

    // MARK: - Rule 1: below lower + reconnect → charge to upper

    func testRule1_UnpluggedDrainsBelowLower_Reconnect_ChargesToUpper() {
        // Start: paused between bounds, on AC
        let sim = Simulator(chargingPaused: true, lastAdapterConnected: true)
        sim.stepUntilSettled(percentage: 45, adapterConnected: true)

        // Unplug at 45%
        sim.step(percentage: 45, adapterConnected: false)
        XCTAssertFalse(sim.state.chargeToUpperBound, "chargeToUpperBound should not have been set on battery")

        // Drain overnight to 38% (below lower bound)
        sim.drainFrom(44, to: 38)
        XCTAssertTrue(sim.state.chargingPaused, "Auto-manage keeps CHTE inhibited while on battery")
        XCTAssertFalse(sim.state.chargeToUpperBound)

        // Plug in AC at 38%
        let action = sim.step(percentage: 38, adapterConnected: true)
        XCTAssertEqual(action, .allow, "Below lower bound on reconnect must allow charging")
        XCTAssertFalse(sim.state.chargingPaused)
        XCTAssertTrue(sim.state.chargeToUpperBound, "Rule 1: below-lower trigger must set chargeToUpperBound")

        // Charge through the lower bound — no inhibit should fire between bounds
        sim.chargeFrom(39, to: 59)
        XCTAssertEqual(sim.issued.filter { $0 == .inhibit }.count, 0,
                       "No inhibit must fire while charging between bounds with chargeToUpperBound set")
        XCTAssertTrue(sim.state.chargeToUpperBound)
        XCTAssertFalse(sim.state.chargingPaused)

        // Reach upper bound — inhibit fires, chargeToUpperBound clears
        sim.step(percentage: 60, adapterConnected: true)
        XCTAssertTrue(sim.state.chargingPaused)
        XCTAssertFalse(sim.state.chargeToUpperBound,
                       "Rule 2 analogue: reaching upper bound clears chargeToUpperBound")
    }

    func testRule1_FreshEnableFromManualMode_ChargesToUpper() {
        // Scenario from fix AY: user enables auto-manage from manual mode
        // while battery is below the lower bound on AC. The UI handler sets
        // chargeToUpperBound=true so the eventual charge-to-upper happens
        // (state machine's branch 3 needs chargingPaused which a fresh
        // enable doesn't have). Verify the state machine then doesn't
        // inhibit while charging through the lower bound and inhibits only
        // at upper.
        let sim = Simulator(
            chargingPaused: false,
            chargeToUpperBound: true,  // UI handler set this on fresh enable
            lastAdapterConnected: true
        )
        // Below lower — no inhibit fires (CHTE stays allow from manual mode)
        XCTAssertEqual(sim.step(percentage: 35, adapterConnected: true), .none)
        // Charge through the band — still no inhibit because ctu=true
        sim.chargeFrom(36, to: 59)
        XCTAssertEqual(sim.issued.filter { $0 == .inhibit }.count, 0,
                       "No inhibit fires while charging with chargeToUpperBound set")
        XCTAssertTrue(sim.state.chargeToUpperBound)
        // At upper, branch 1 fires
        XCTAssertEqual(sim.step(percentage: 60, adapterConnected: true), .inhibit)
        XCTAssertFalse(sim.state.chargeToUpperBound)
        XCTAssertTrue(sim.state.chargingPaused)
    }

    func testRule1_AlreadyBelowLowerWhenFirstConnected() {
        // Scenario: app starts or first sees state with battery already below
        // lower bound and AC plugged in (e.g., launched in that condition).
        let sim = Simulator(chargingPaused: true, lastAdapterConnected: nil)
        let action = sim.step(percentage: 35, adapterConnected: true)
        XCTAssertEqual(action, .allow)
        XCTAssertTrue(sim.state.chargeToUpperBound)
    }

    // MARK: - Rule 2: unplug above lower → stop at interrupt point on reconnect

    func testRule2_InterruptedChargeAboveLower_ReconnectStopsAtInterruptLevel() {
        // Start: charging from below lower, chargeToUpperBound=true, currently 50%
        let sim = Simulator(
            chargingPaused: false,
            chargeToUpperBound: true,
            lastAdapterConnected: true
        )

        // Simulate ongoing charge at 50% (between bounds, chargeToUpperBound on
        // so no inhibit should fire here)
        let preAction = sim.step(percentage: 50, adapterConnected: true)
        XCTAssertEqual(preAction, .none)
        XCTAssertTrue(sim.state.chargeToUpperBound)

        // User unplugs at 50% — this is the "interruption"
        sim.step(percentage: 50, adapterConnected: false)
        XCTAssertFalse(sim.state.chargeToUpperBound,
                       "Rule 2: interruption above lower bound must clear chargeToUpperBound")

        // Battery drains a bit, still above lower
        sim.drainFrom(49, to: 45)
        XCTAssertFalse(sim.state.chargeToUpperBound)

        // Reconnect AC at 45% (between bounds)
        let postAction = sim.step(percentage: 45, adapterConnected: true)
        XCTAssertEqual(postAction, .inhibit,
                       "Between bounds without chargeToUpperBound must inhibit (rule 3)")
        XCTAssertTrue(sim.state.chargingPaused)

        // No further charging fires as battery sits between bounds
        sim.stepUntilSettled(percentage: 45, adapterConnected: true)
        XCTAssertEqual(sim.state.chargingPaused, true)
        XCTAssertFalse(sim.state.chargeToUpperBound)
    }

    func testRule2_InterruptedChargeBelowLower_DoesNotClearChargeToUpper() {
        // Edge: user unplugs while battery is still below lower bound in the
        // middle of a rule-1 recovery charge. The toggle should NOT be cleared
        // because the battery is below the lower bound — rule 2 applies only
        // to interruptions above the lower bound.
        let sim = Simulator(
            chargingPaused: false,
            chargeToUpperBound: true,
            lastAdapterConnected: true
        )

        sim.step(percentage: 38, adapterConnected: true)   // charging at 38%
        sim.step(percentage: 39, adapterConnected: false)  // unplug at 39% (still < 40)

        XCTAssertTrue(sim.state.chargeToUpperBound,
                       "Rule 2 must NOT clear the toggle when interruption is below lower bound")
    }

    func testRule2_UserToggleWhileOnBattery_Preserved() {
        // If the user explicitly toggles chargeToUpperBound ON while already on
        // battery, a subsequent refresh must NOT revert it. Rule 2 fires only
        // on the connected→disconnected transition.
        let sim = Simulator(
            chargingPaused: true,
            chargeToUpperBound: false,
            lastAdapterConnected: false  // already on battery
        )

        // User sets chargeToUpperBound=true via UI
        sim.state.chargeToUpperBound = true

        // Next refresh while still on battery
        sim.step(percentage: 50, adapterConnected: false)
        XCTAssertTrue(sim.state.chargeToUpperBound,
                      "Toggle set on battery must be preserved — rule 2 is transition-only")

        // Plug in AC — rule-1 path not taken (pct >= lower), but chargeToUpperBound
        // should drive the allow branch
        let action = sim.step(percentage: 50, adapterConnected: true)
        XCTAssertEqual(action, .allow)
        XCTAssertFalse(sim.state.chargingPaused)
        XCTAssertTrue(sim.state.chargeToUpperBound)
    }

    // MARK: - Rule 3: between bounds never auto-charges

    /// Tests branch 1 of `evaluateAutoManageStep` (`!chargingPaused && pct >= upper`),
    /// which lives in the "rule 3" MARK section because it's the same inhibit
    /// outcome — the rule-3 / branch-1 distinction is internal to the state
    /// machine; the user-visible behavior is "stop at upper".
    func testAtUpperBound_Inhibits() {
        let sim = Simulator(chargingPaused: false, lastAdapterConnected: true)
        let action = sim.step(percentage: 60, adapterConnected: true)
        XCTAssertEqual(action, .inhibit)
        XCTAssertTrue(sim.state.chargingPaused)
        XCTAssertFalse(sim.state.chargeToUpperBound)
    }

    func testRule3_BetweenBoundsAfterRestart_Inhibits() {
        // App restart between bounds with AC plugged in. The init path sets
        // chargingPaused based on percentage (50 >= 40 → paused), so the first
        // refresh sees chargingPaused=true, chargeToUpperBound=false.
        let sim = Simulator(
            chargingPaused: true,
            chargeToUpperBound: false,
            lastAdapterConnected: nil
        )
        sim.stepUntilSettled(percentage: 50, adapterConnected: true)
        XCTAssertTrue(sim.state.chargingPaused)
        XCTAssertFalse(sim.state.chargeToUpperBound)
        XCTAssertEqual(sim.issued.count, 0, "No SMC action should fire for a valid paused state")
    }

    func testStaleChargeToUpperAtOrAboveUpperBound_ClearsWithoutAllow() {
        // Race: the user flips "Charge to Upper Bound" from a UI rendered
        // against the previous poll's reading, just as the battery crosses
        // the upper bound. The next refresh then sees paused=true, ctu=true,
        // pct >= upper. Without the staleness repair, the paused branch
        // would issue a spurious allow at the bound, immediately reverted by
        // an inhibit on the next cycle. The repair must clear the toggle
        // with NO SMC action — CHTE is already in the correct inhibit state.
        for pct in [60, 65] {  // exactly at the bound, and above it
            let sim = Simulator(
                chargingPaused: true,
                chargeToUpperBound: true,
                lastAdapterConnected: true
            )
            let action = sim.step(percentage: pct, adapterConnected: true)
            XCTAssertEqual(action, .none,
                           "Stale ctu at \(pct)% must not issue an SMC action")
            XCTAssertFalse(sim.state.chargeToUpperBound,
                           "Stale ctu at \(pct)% must be cleared")
            XCTAssertTrue(sim.state.chargingPaused,
                          "Inhibited state must be preserved at \(pct)%")
            sim.stepUntilSettled(percentage: pct, adapterConnected: true)
            XCTAssertEqual(sim.issued.count, 0,
                           "The repair must not trigger any allow/inhibit churn")
        }
    }

    func testChargeToUpperJustBelowUpperBound_StillAllows() {
        // Complement of the staleness repair: one percent below the bound
        // the toggle is legitimate and must still drive the allow branch.
        let sim = Simulator(
            chargingPaused: true,
            chargeToUpperBound: true,
            lastAdapterConnected: true
        )
        let action = sim.step(percentage: 59, adapterConnected: true)
        XCTAssertEqual(action, .allow)
        XCTAssertFalse(sim.state.chargingPaused)
        XCTAssertTrue(sim.state.chargeToUpperBound)
    }

    func testRule3_UserExplicitToggleBetweenBounds_ChargesToUpper() {
        // User in the between-bounds state explicitly sets chargeToUpperBound
        // → must charge to upper bound, then clear the toggle on arrival.
        let sim = Simulator(
            chargingPaused: true,
            chargeToUpperBound: false,
            lastAdapterConnected: true
        )
        sim.stepUntilSettled(percentage: 50, adapterConnected: true)
        XCTAssertTrue(sim.state.chargingPaused)

        // User toggles via UI
        sim.state.chargeToUpperBound = true

        // First refresh after toggle
        let action = sim.step(percentage: 50, adapterConnected: true)
        XCTAssertEqual(action, .allow)
        XCTAssertFalse(sim.state.chargingPaused)
        XCTAssertTrue(sim.state.chargeToUpperBound)

        // Charge to 59
        sim.chargeFrom(51, to: 59)
        XCTAssertTrue(sim.state.chargeToUpperBound)
        XCTAssertFalse(sim.state.chargingPaused)

        // Reach upper — clears toggle
        sim.step(percentage: 60, adapterConnected: true)
        XCTAssertTrue(sim.state.chargingPaused)
        XCTAssertFalse(sim.state.chargeToUpperBound)
    }

    // MARK: - Full lifecycle integration

    func testFullLifecycle_Rule1Then2Then1() {
        // A realistic multi-day sequence: below-lower recovery → battery →
        // interrupted mid-charge → reconnect → drains low → reconnect again.
        let sim = Simulator(chargingPaused: true, lastAdapterConnected: true)
        sim.stepUntilSettled(percentage: 55, adapterConnected: true)

        // Day 1 evening: unplug at 55%, drain to 35% overnight
        sim.step(percentage: 55, adapterConnected: false)
        sim.drainFrom(54, to: 35)

        // Day 2 morning: plug in at 35% → rule 1 charges to upper
        sim.step(percentage: 35, adapterConnected: true)
        XCTAssertTrue(sim.state.chargeToUpperBound, "Rule 1 fires on reconnect below lower")
        sim.chargeFrom(36, to: 50)
        XCTAssertFalse(sim.state.chargingPaused)
        XCTAssertTrue(sim.state.chargeToUpperBound)

        // Mid-charge at 50% user unplugs (rule 2 interruption)
        sim.step(percentage: 50, adapterConnected: false)
        XCTAssertFalse(sim.state.chargeToUpperBound, "Rule 2 clears the toggle on mid-charge unplug")

        // Drains slightly to 47%, still above lower
        sim.drainFrom(49, to: 47)

        // Plug in at 47% — must inhibit (rule 3), not continue to upper
        let reconnectAction = sim.step(percentage: 47, adapterConnected: true)
        XCTAssertEqual(reconnectAction, .inhibit)
        XCTAssertTrue(sim.state.chargingPaused)
        XCTAssertFalse(sim.state.chargeToUpperBound)

        // Unplug again, drain all the way below lower again
        sim.step(percentage: 47, adapterConnected: false)
        sim.drainFrom(46, to: 36)

        // Plug in below lower → rule 1 again
        let secondRecoveryAction = sim.step(percentage: 36, adapterConnected: true)
        XCTAssertEqual(secondRecoveryAction, .allow)
        XCTAssertTrue(sim.state.chargeToUpperBound)
    }

    // MARK: - Auto-manage disabled: no-ops

    func testAutoManageDisabled_NoActionsIssued() {
        let sim = Simulator(chargingPaused: false, lastAdapterConnected: true)
        for pct in [30, 45, 65] {
            for connected in [true, false] {
                _ = sim.step(percentage: pct, adapterConnected: connected, autoManageEnabled: false)
            }
        }
        XCTAssertEqual(sim.issued.count, 0, "Auto-manage disabled must not issue any SMC action")
    }

    // MARK: - Rule 2 details

    func testRule2_OnlyFiresOnTransition_NotOnEveryRefreshWhileOnBattery() {
        // If chargeToUpperBound is true and user is already on battery, rule 2
        // must NOT clear it just because adapterConnected is false — it only
        // clears on the connected→disconnected edge.
        let sim = Simulator(
            chargingPaused: false,
            chargeToUpperBound: true,
            lastAdapterConnected: false
        )

        // Several refreshes while already on battery, above lower
        for pct in [50, 49, 48] {
            sim.step(percentage: pct, adapterConnected: false)
        }
        XCTAssertTrue(sim.state.chargeToUpperBound,
                      "Rule 2 must be transition-only, not apply on every tick")
    }

    func testRule2_FiresAtLowerBoundExactly() {
        // Edge: unplug exactly at lower bound. pct >= lower includes equality,
        // so rule 2 DOES fire at exactly the lower bound.
        let sim = Simulator(
            chargingPaused: false,
            chargeToUpperBound: true,
            lastAdapterConnected: true
        )
        sim.step(percentage: 40, adapterConnected: false)
        XCTAssertFalse(sim.state.chargeToUpperBound,
                       "Rule 2 fires at exactly the lower bound (pct >= lowerBound)")
    }

    // MARK: - Charge to 100% (one-shot full charge)

    func testChargeToFull_BetweenBounds_ChargesTo100AndClears() {
        // Parked between bounds; user toggles "Charge to 100%". Must allow,
        // sail past the configured upper bound WITHOUT inhibiting, then
        // inhibit and self-clear at 100. Exactly two SMC writes total.
        let sim = Simulator(chargingPaused: true, lastAdapterConnected: true)
        sim.stepUntilSettled(percentage: 50, adapterConnected: true)

        sim.state.chargeToFull = true  // UI toggle

        let action = sim.step(percentage: 50, adapterConnected: true)
        XCTAssertEqual(action, .allow)
        XCTAssertFalse(sim.state.chargingPaused)

        // Crossing the configured upper bound (60) must not stop the charge.
        sim.chargeFrom(51, to: 99)
        XCTAssertFalse(sim.state.chargingPaused,
                       "Charge-to-full must not inhibit at the configured upper bound")
        XCTAssertTrue(sim.state.chargeToFull)

        sim.step(percentage: 100, adapterConnected: true)
        XCTAssertTrue(sim.state.chargingPaused)
        XCTAssertFalse(sim.state.chargeToFull, "Reaching 100% clears the override")
        XCTAssertFalse(sim.state.chargeToUpperBound)
        sim.stepUntilSettled(percentage: 100, adapterConnected: true)
        XCTAssertEqual(sim.issued, [.allow, .inhibit],
                       "The whole journey is one allow and one inhibit")
    }

    func testChargeToFull_ActivatedAboveUpperBound_Allows() {
        // Inhibited above the configured upper bound (85% with upper 60).
        // Charge-to-full is the only toggle offered there once discharge is
        // off, and it must un-pause charging.
        let sim = Simulator(chargingPaused: true, lastAdapterConnected: true)
        sim.stepUntilSettled(percentage: 85, adapterConnected: true)
        XCTAssertEqual(sim.issued.count, 0)

        sim.state.chargeToFull = true  // UI toggle

        let action = sim.step(percentage: 85, adapterConnected: true)
        XCTAssertEqual(action, .allow)
        sim.chargeFrom(86, to: 99)
        sim.step(percentage: 100, adapterConnected: true)
        XCTAssertTrue(sim.state.chargingPaused)
        XCTAssertFalse(sim.state.chargeToFull)
        XCTAssertEqual(sim.issued, [.allow, .inhibit])
    }

    func testChargeToFull_UnplugAboveLower_ClearsWithoutDowngrade() {
        // Unplug mid-full-charge above the lower bound: the one-shot dies
        // with the AC session and nothing replaces it — reconnect parks at
        // the current level (rule 3), same as an interrupted charge-to-upper.
        let sim = Simulator(chargingPaused: true, lastAdapterConnected: true)
        sim.stepUntilSettled(percentage: 50, adapterConnected: true)
        sim.state.chargeToFull = true
        sim.step(percentage: 50, adapterConnected: true)  // allow

        sim.step(percentage: 55, adapterConnected: false)
        XCTAssertFalse(sim.state.chargeToFull, "Unplug cancels charge-to-full")
        XCTAssertFalse(sim.state.chargeToUpperBound, "No downgrade at/above lower")

        let reconnect = sim.step(percentage: 55, adapterConnected: true)
        XCTAssertEqual(reconnect, .inhibit, "Reconnect parks at the interruption level")
    }

    func testChargeToFull_UnplugBelowLower_DowngradesToChargeToUpper() {
        // Unplug mid-full-charge below the lower bound: downgrade to
        // charge-to-upper so reconnect behaves exactly like rule 1 (charge
        // to the configured upper), instead of charging to the lower bound
        // and parking there.
        let sim = Simulator(
            chargingPaused: false,
            chargeToUpperBound: false,
            chargeToFull: true,
            lastAdapterConnected: true
        )
        sim.step(percentage: 35, adapterConnected: false)
        XCTAssertFalse(sim.state.chargeToFull)
        XCTAssertTrue(sim.state.chargeToUpperBound,
                      "Below lower the session one-shot downgrades to the rule-1 intent")

        // Reconnect: continues to the configured upper bound and stops there.
        sim.step(percentage: 37, adapterConnected: true)
        sim.chargeFrom(38, to: 59)
        XCTAssertFalse(sim.state.chargingPaused)
        sim.step(percentage: 60, adapterConnected: true)
        XCTAssertTrue(sim.state.chargingPaused)
        XCTAssertFalse(sim.state.chargeToUpperBound)
    }

    func testChargeToFull_StaleOnBattery_ClearsWithoutDowngrade() {
        // A persisted chargeToFull that wakes up already on battery (crash
        // inside the unplug window) is session-stale: it must clear on the
        // first battery tick and must NOT plant a charge-to-upper intent —
        // the downgrade only applies at the fresh unplug edge.
        let sim = Simulator(
            chargingPaused: false,
            chargeToUpperBound: false,
            chargeToFull: true,
            lastAdapterConnected: false
        )
        sim.step(percentage: 35, adapterConnected: false)
        XCTAssertFalse(sim.state.chargeToFull, "Session-stale flag clears on battery")
        XCTAssertFalse(sim.state.chargeToUpperBound, "No downgrade without the unplug edge")
        XCTAssertEqual(sim.issued.count, 0)
    }

    func testChargeToFull_At100WhilePaused_PureClearNoAction() {
        // Crash-window analog of the ctu staleness repair: paused with
        // chargeToFull=true at 100% must clear the flag with no SMC action —
        // CHTE is already in the correct inhibit state.
        let sim = Simulator(
            chargingPaused: true,
            chargeToUpperBound: false,
            chargeToFull: true,
            lastAdapterConnected: true
        )
        let action = sim.step(percentage: 100, adapterConnected: true)
        XCTAssertEqual(action, .none)
        XCTAssertFalse(sim.state.chargeToFull)
        XCTAssertTrue(sim.state.chargingPaused)
        XCTAssertEqual(sim.issued.count, 0)
    }

    func testChargeToFull_RestartOnACMidCharge_ContinuesWithoutAction() {
        // Quit/crash + relaunch mid-full-charge, already past the configured
        // upper bound (70% with upper 60). Launch restores chargeToFull with
        // chargingPaused=false and CHTE=allow. The first refresh must issue
        // NOTHING — in particular not the at/above-upper inhibit — so the
        // in-progress full charge resumes seamlessly.
        let sim = Simulator(
            chargingPaused: false,
            chargeToUpperBound: false,
            chargeToFull: true,
            lastAdapterConnected: true
        )
        sim.stepUntilSettled(percentage: 70, adapterConnected: true)
        XCTAssertEqual(sim.issued.count, 0,
                       "Resumed full charge must not be interrupted at the configured bound")
        XCTAssertTrue(sim.state.chargeToFull)
        XCTAssertFalse(sim.state.chargingPaused)
    }

    func testChargeToFull_WornBattery_CompletesOnBMSFullSignal() {
        // A worn battery can terminate its charge below a displayed 100%.
        // The BMS fully-charged flag must complete the one-shot exactly like
        // reaching 100 — otherwise CHTE stays allow forever and the battery
        // micro-charges at the top for as long as it stays plugged in.
        let sim = Simulator(chargingPaused: true, lastAdapterConnected: true)
        sim.stepUntilSettled(percentage: 50, adapterConnected: true)
        sim.state.chargeToFull = true
        sim.step(percentage: 50, adapterConnected: true)  // allow
        sim.chargeFrom(51, to: 97)

        // BMS says done at 97% displayed.
        let action = sim.step(percentage: 97, adapterConnected: true, fullyCharged: true)
        XCTAssertEqual(action, .inhibit)
        XCTAssertFalse(sim.state.chargeToFull, "BMS full completes the one-shot")
        XCTAssertTrue(sim.state.chargingPaused)
        XCTAssertEqual(sim.issued, [.allow, .inhibit])
    }

    func testChargeToUpper_UpperBoundAt100_WornBattery_InhibitsOnBMSFullSignal() {
        // Same worn-battery defect existed for a configured upper bound of
        // 100: the percentage never reaches it, so without the BMS signal the
        // allow state would never terminate.
        let sim = Simulator(chargingPaused: true, lastAdapterConnected: true, upperBound: 100)
        let recovery = sim.step(percentage: 35, adapterConnected: true)
        XCTAssertEqual(recovery, .allow)
        XCTAssertTrue(sim.state.chargeToUpperBound)

        sim.chargeFrom(36, to: 99)
        XCTAssertFalse(sim.state.chargingPaused)

        let action = sim.step(percentage: 99, adapterConnected: true, fullyCharged: true)
        XCTAssertEqual(action, .inhibit)
        XCTAssertFalse(sim.state.chargeToUpperBound)
        XCTAssertTrue(sim.state.chargingPaused)
    }

    func testChargeToFull_SpuriousFullSignalMidRange_FailsSafe() {
        // A glitched fully-charged reading far from the top must fail SAFE:
        // the one-shot clears and charging inhibits (rule 3 for the current
        // level). Stopping early is recoverable by re-toggling; the opposite
        // failure (charging forever) is not self-limiting.
        let sim = Simulator(chargingPaused: true, lastAdapterConnected: true)
        sim.stepUntilSettled(percentage: 50, adapterConnected: true)
        sim.state.chargeToFull = true
        sim.step(percentage: 50, adapterConnected: true)  // allow

        let action = sim.step(percentage: 55, adapterConnected: true, fullyCharged: true)
        XCTAssertEqual(action, .inhibit)
        XCTAssertFalse(sim.state.chargeToFull)
        XCTAssertTrue(sim.state.chargingPaused)
    }

    func testChargeToFull_WithChargeToUpperAlsoSet_UpperCrossingClearsOnlyCtu() {
        // Below lower, rule 1 has already armed charge-to-upper; the user
        // then asks for a full charge. Crossing the configured upper bound
        // retires the (now stale) charge-to-upper flag but the full charge
        // continues to 100 with no extra SMC writes.
        let sim = Simulator(chargingPaused: true, lastAdapterConnected: true)
        let recovery = sim.step(percentage: 35, adapterConnected: true)
        XCTAssertEqual(recovery, .allow)
        XCTAssertTrue(sim.state.chargeToUpperBound, "Rule 1 arms charge-to-upper")

        sim.state.chargeToFull = true  // UI toggle mid-charge

        sim.chargeFrom(36, to: 59)
        XCTAssertTrue(sim.state.chargeToUpperBound)
        sim.step(percentage: 60, adapterConnected: true)
        XCTAssertFalse(sim.state.chargeToUpperBound,
                       "Configured-upper crossing retires the charge-to-upper flag")
        XCTAssertTrue(sim.state.chargeToFull)
        XCTAssertFalse(sim.state.chargingPaused, "The full charge keeps going")

        sim.chargeFrom(61, to: 99)
        sim.step(percentage: 100, adapterConnected: true)
        XCTAssertTrue(sim.state.chargingPaused)
        XCTAssertFalse(sim.state.chargeToFull)
        XCTAssertEqual(sim.issued, [.allow, .inhibit],
                       "35% → 100% is still exactly one allow and one inhibit")
    }
}
