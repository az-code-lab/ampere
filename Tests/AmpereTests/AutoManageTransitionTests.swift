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
            lastAdapterConnected: Bool? = nil,
            lowerBound: Int = 40,
            upperBound: Int = 60
        ) {
            self.state = BatteryMonitor.AutoManageState(
                chargingPaused: chargingPaused,
                chargeToUpperBound: chargeToUpperBound,
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
            autoManageEnabled: Bool = true
        ) -> BatteryMonitor.AutoManageAction {
            let inputs = BatteryMonitor.AutoManageInputs(
                autoManageEnabled: autoManageEnabled,
                adapterConnected: adapterConnected,
                percentage: percentage,
                lowerBound: lowerBound,
                upperBound: upperBound
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
}
