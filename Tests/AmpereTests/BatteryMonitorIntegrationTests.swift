import XCTest
@testable import Ampere
import Shared

final class MemoryBatteryPreferences: BatteryPreferences {
    var values: [String: Any] = ["autoManageEnabled": true]
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
}

/// Drives the actual monitor, including its background queue and main-queue
/// completions. Every privileged operation and hardware read is replaced.
final class BatteryMonitorIntegrationTests: XCTestCase {
    private final class Hardware {
        final class Gate {
            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
        }
        var percentage = 50
        var connected = true
        var full = false
        var authorized = true
        var stale = false
        var installed = true
        var installs = 0
        /// False: the administrator prompt is cancelled.
        var installSucceeds = true
        /// Non-nil: an earlier Ampere process holds charge control.
        var competing: String?
        let preferences = MemoryBatteryPreferences()
        private let lock = NSLock()
        private var commands: [String] = []
        private var gate: (String, Gate)?
        private var chte: UInt8 = 1
        private var chie: UInt8 = 0
        private var held = false
        private var failingCommands: Set<String> = []

        var writes: [String] {
            lock.lock(); defer { lock.unlock() }
            return commands
        }

        func blockNext(_ command: String) -> Gate {
            let next = Gate()
            lock.lock(); defer { lock.unlock() }
            gate = (command, next)
            return next
        }

        func fail(_ command: String) {
            lock.lock(); defer { lock.unlock() }
            failingCommands.insert(command)
        }

        func resetChargingKey() {
            lock.lock(); defer { lock.unlock() }
            chte = 0
        }

        func write(_ command: String) -> Bool {
            lock.lock()
            let waiting = gate?.0 == command ? gate?.1 : nil
            if waiting != nil { gate = nil }
            lock.unlock()
            if let waiting {
                waiting.entered.signal()
                guard waiting.release.wait(timeout: .now() + 3) == .success else { return false }
            }
            lock.lock(); defer { lock.unlock() }
            commands.append(command)
            guard !failingCommands.contains(command) else { return false }
            switch command {
            case "inhibit": chte = 1
            case "allow": chte = 0
            case "nodischarge": chie = 0; held = false
            case "restore": chte = 0; chie = 0; held = false
            case "hold-sleep": held = true
            case "release-sleep-hold": held = false
            default:
                if command.hasPrefix("discharge:") { chie = 8; held = true }
            }
            return true
        }

        func reading() -> BatteryState {
            BatteryState(percentage: percentage, cycleCount: 1, isCharging: false,
                adapterConnected: connected, health: "100%", temperature: 20,
                timeRemaining: "", designCapacity: 5000, maxCapacity: 5000,
                currentCapacity: 2500, amperage: 0, voltage: 12, adapterWatts: 20,
                adapterAmperage: 1000, adapterVoltage: 20, electronicsWatts: 20,
                batteryWatts: 0, batteryAgeYears: "", batteryAgeDays: "", fullyCharged: full)
        }

        func monitor(startMonitoring: Bool = false, locked: Bool = true) -> BatteryMonitor {
            var io = BatteryMonitor.IO()
            io.battery = { self.reading() }
            io.lidClosed = { false }
            io.sleepDisabled = {
                self.lock.lock(); defer { self.lock.unlock() }
                return self.held
            }
            io.readKey = { key in
                self.lock.lock(); defer { self.lock.unlock() }
                return key == SMC.keyChargeTerminate ? [self.chte, 0, 0, 0] : [self.chie]
            }
            io.writeHelper = write
            io.helperInstalled = { self.installed }
            io.helperAuthorized = { self.authorized }
            io.helperStale = { self.stale }
            io.installHelper = {
                self.installs += 1
                guard self.installSucceeds else { return false }
                self.authorized = true
                self.installed = true
                self.stale = false
                return true
            }
            io.runAsAdmin = { _ in XCTFail("Unexpected administrator command"); return false }
            io.setupRefusal = { nil }
            io.competingInstance = { self.competing }
            return BatteryMonitor(chargeBoundsLocked: locked, defaults: preferences,
                                  io: io, startMonitoring: startMonitoring)
        }
    }

    private func awaitCondition(_ condition: @escaping () -> Bool,
                                file: StaticString = #filePath, line: UInt = #line) {
        let ready = expectation(for: NSPredicate { _, _ in condition() }, evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 3), .completed, file: file, line: line)
    }

    private func drainCallbacks() {
        let done = expectation(description: "main queue drained")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { done.fulfill() }
        wait(for: [done], timeout: 3)
    }

    func testCancelFullChargeWhileAllowIsInFlight() {
        let hw = Hardware(), monitor = hw.monitor()
        monitor.chargingPaused = true
        let gate = hw.blockNext("allow")
        monitor.setChargeToFull(true)
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 3), .success)
        monitor.setChargeToFull(false)
        gate.release.signal()
        awaitCondition { monitor.chargingPaused && hw.writes.count >= 2 }
        XCTAssertFalse(monitor.chargeToFull)
        XCTAssertEqual(hw.writes, ["allow", "inhibit"])
        XCTAssertEqual(hw.preferences.values["chargeToFull"] as? Bool, false)
    }

    func testCancelChargeToUpperWhileAllowIsInFlight() {
        let hw = Hardware(), monitor = hw.monitor()
        monitor.chargingPaused = true
        let gate = hw.blockNext("allow")
        monitor.chargeToUpperBound = true
        monitor.refresh()
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 3), .success)
        monitor.chargeToUpperBound = false
        monitor.inhibitCharging()
        gate.release.signal()
        awaitCondition { monitor.chargingPaused && hw.writes.count >= 2 }
        XCTAssertFalse(monitor.chargeToUpperBound)
        XCTAssertEqual(hw.writes, ["allow", "inhibit"])
    }

    func testUnplugAndReconnectDuringAllowDoesNotResurrectFullCharge() {
        let hw = Hardware(), monitor = hw.monitor()
        monitor.chargingPaused = true
        let gate = hw.blockNext("allow")
        monitor.setChargeToFull(true)
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 3), .success)
        hw.connected = false
        monitor.refresh()
        hw.connected = true
        monitor.refresh()
        gate.release.signal()
        awaitCondition { monitor.chargingPaused && hw.writes.count >= 2 }
        XCTAssertFalse(monitor.chargeToFull)
        XCTAssertEqual(hw.writes, ["allow", "inhibit"])
    }

    func testDisableAutoWhileInhibitIsInFlightResumesManualCharging() {
        let hw = Hardware(), monitor = hw.monitor()
        let gate = hw.blockNext("inhibit")
        monitor.refresh()
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 3), .success)
        monitor.autoManageEnabled = false
        monitor.refresh()
        gate.release.signal()
        awaitCondition { !monitor.chargingPaused && hw.writes.count >= 2 }
        XCTAssertEqual(hw.writes, ["inhibit", "allow"])
    }

    func testNewFullChargeRequestSurvivesAnEarlierInhibit() {
        let hw = Hardware(), monitor = hw.monitor()
        let gate = hw.blockNext("inhibit")
        monitor.refresh()
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 3), .success)
        monitor.setChargeToFull(true)
        gate.release.signal()
        awaitCondition { !monitor.chargingPaused && hw.writes.count >= 2 }
        XCTAssertTrue(monitor.chargeToFull)
        XCTAssertEqual(hw.writes, ["inhibit", "allow"])
    }

    func testSleepWaitsForPendingAllowAndInhibitsLastUntilWake() {
        let hw = Hardware(), monitor = hw.monitor()
        monitor.chargingPaused = true
        let gate = hw.blockNext("allow")
        monitor.chargeToUpperBound = true
        monitor.refresh()
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 3), .success)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) { gate.release.signal() }
        monitor.prepareForSleep()
        XCTAssertEqual(hw.writes, ["allow", "inhibit"])
        drainCallbacks()
        monitor.refresh()
        XCTAssertEqual(hw.writes, ["allow", "inhibit"], "Callbacks cannot undo the sleep pause")
        monitor.resumeAfterWake()
        awaitCondition { hw.writes.count == 3 }
        XCTAssertEqual(hw.writes.last, "allow")
        XCTAssertTrue(monitor.chargeToUpperBound)
    }

    func testWakeBeforeEarlierCompletionStillReassertsCharging() {
        let hw = Hardware(), monitor = hw.monitor()
        monitor.chargingPaused = true
        monitor.chargeToUpperBound = true
        monitor.refresh()
        monitor.prepareForSleep() // drains writes; the main callback is still queued
        monitor.resumeAfterWake()
        awaitCondition { hw.writes.count == 3 }
        XCTAssertEqual(hw.writes, ["allow", "inhibit", "allow"])
    }

    func testFullChargeContinuesThroughSleep() {
        let hw = Hardware(), monitor = hw.monitor()
        monitor.chargingPaused = true
        monitor.setChargeToFull(true)
        awaitCondition { !monitor.chargingPaused }
        monitor.prepareForSleep()
        XCTAssertEqual(hw.writes, ["allow", "allow"])
        monitor.resumeAfterWake()
        awaitCondition { hw.writes.count == 3 }
        XCTAssertEqual(hw.writes, ["allow", "allow", "allow"])
        XCTAssertTrue(monitor.chargeToFull)
    }

    func testFullChargeRequestedDuringInhibitIsAllowedBeforeSleep() {
        let hw = Hardware(), monitor = hw.monitor()
        let gate = hw.blockNext("inhibit")
        monitor.refresh()
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 3), .success)
        monitor.setChargeToFull(true)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) { gate.release.signal() }
        monitor.prepareForSleep()
        drainCallbacks()
        XCTAssertEqual(hw.writes, ["inhibit", "allow"])
        XCTAssertTrue(monitor.chargeToFull)
    }

    func testAutoDisabledDuringInhibitResumesBeforeSleep() {
        let hw = Hardware(), monitor = hw.monitor()
        let gate = hw.blockNext("inhibit")
        monitor.refresh()
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 3), .success)
        monitor.autoManageEnabled = false
        monitor.refresh()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) { gate.release.signal() }
        monitor.prepareForSleep()
        drainCallbacks()
        XCTAssertEqual(hw.writes, ["inhibit", "allow"])
    }

    func testQuitRestoresAfterAnInFlightWriteAndKeepsPersistedIntent() {
        let hw = Hardware(), monitor = hw.monitor()
        monitor.chargingPaused = true
        let gate = hw.blockNext("allow")
        monitor.setChargeToFull(true)
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 3), .success)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) { gate.release.signal() }
        monitor.restoreBeforeTermination()
        drainCallbacks()
        monitor.refresh()
        XCTAssertEqual(hw.writes, ["allow", "restore"])
        XCTAssertEqual(hw.preferences.values["chargeToFull"] as? Bool, true)
    }

    func testFailedPauseDuringWakeDoesNotRetryContinuously() {
        let hw = Hardware()
        hw.preferences.values["autoManageEnabled"] = false
        let monitor = hw.monitor()
        hw.fail("inhibit")
        let gate = hw.blockNext("inhibit")
        monitor.toggleCharging()
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 3), .success)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) { gate.release.signal() }
        monitor.prepareForSleep()
        monitor.resumeAfterWake()
        awaitCondition { hw.writes.count >= 3 }
        drainCallbacks()
        XCTAssertEqual(hw.writes, ["inhibit", "inhibit", "allow"],
                       "One attempt for the request and one pre-sleep pause; the failed request is dropped, so wake re-asserts the unpaused state")
        XCTAssertNotNil(monitor.lastError)
        XCTAssertFalse(monitor.chargingPaused)
    }

    func testFailedManualRequestIsNotRetriedOnLaterPolls() {
        let hw = Hardware()
        hw.preferences.values["autoManageEnabled"] = false
        let monitor = hw.monitor()
        monitor.toggleCharging()
        awaitCondition { monitor.chargingPaused }
        hw.fail("allow")
        monitor.toggleCharging()
        awaitCondition { monitor.lastError != nil }
        for _ in 0..<3 { monitor.refresh() }
        drainCallbacks()
        XCTAssertEqual(hw.writes, ["inhibit", "allow"])
        XCTAssertTrue(monitor.chargingPaused)
    }

    /// The Auto Charge toggle's rollback after a cancelled admin prompt
    /// turns auto-manage off with no usable helper. That must not queue a
    /// resume: it could never succeed, and each attempt would replace the
    /// accurate error with advice to revoke access the app does not have.
    func testCancelledAdminPromptDuringEnableQueuesNoResume() {
        let hw = Hardware()
        hw.installed = false
        let monitor = hw.monitor()
        monitor.autoManageEnabled = false
        monitor.lastError = "Admin access required for auto charge"
        for _ in 0..<3 { monitor.refresh() }
        drainCallbacks()
        XCTAssertEqual(hw.writes, [])
        XCTAssertEqual(monitor.lastError, "Admin access required for auto charge")
    }

    func testWakeDuringHealthRepairStillReassertsAfterSleep() {
        let hw = Hardware(), monitor = hw.monitor()
        monitor.chargingPaused = true
        hw.resetChargingKey()
        let gate = hw.blockNext("inhibit")
        for _ in 0..<5 { monitor.refresh() }
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 3), .success)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) { gate.release.signal() }
        monitor.prepareForSleep()
        monitor.resumeAfterWake()
        awaitCondition { hw.writes.count >= 3 }
        XCTAssertEqual(hw.writes, ["inhibit", "inhibit", "inhibit"])
    }

    func testFullChargeRequestedDuringHealthRepairStartsAfterItCompletes() {
        let hw = Hardware(), monitor = hw.monitor()
        monitor.chargingPaused = true
        hw.resetChargingKey()
        let gate = hw.blockNext("inhibit")
        for _ in 0..<5 { monitor.refresh() }
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 3), .success)
        monitor.setChargeToFull(true)
        gate.release.signal()
        awaitCondition { !monitor.chargingPaused && hw.writes.count >= 2 }
        XCTAssertEqual(hw.writes, ["inhibit", "allow"])
        XCTAssertTrue(monitor.chargeToFull)
    }

    func testFullBatteryBelowLowerBoundSettlesAndHealthCheckDoesNotReopenIt() {
        let hw = Hardware()
        hw.percentage = 94
        hw.full = true
        hw.preferences.values["chargeLowerBound"] = 95
        hw.preferences.values["chargeUpperBound"] = 100
        let monitor = hw.monitor(locked: false)
        monitor.chargeToUpperBound = true
        monitor.refresh()
        awaitCondition { monitor.chargingPaused }
        for _ in 0..<5 { monitor.refresh() }
        drainCallbacks()
        XCTAssertFalse(monitor.chargeToUpperBound)
        XCTAssertFalse(monitor.sleepHoldActive)
        XCTAssertEqual(hw.writes, ["inhibit"])
        XCTAssertEqual(monitor.lastHealthCheckStatus, "pass")
    }

    func testStandsByForAnEarlierInstanceAndTakesOverWhenItQuits() {
        let hw = Hardware()
        hw.competing = "Ampere running as alice"
        let monitor = hw.monitor(startMonitoring: true)
        XCTAssertEqual(monitor.chargeControlHold, .otherInstance("Ampere running as alice"))
        XCTAssertTrue(monitor.standingBy)
        XCTAssertEqual(hw.installs, 0)
        XCTAssertFalse(monitor.accountAuthorized)
        monitor.refresh()
        monitor.prepareForSleep()
        monitor.resumeAfterWake()
        monitor.toggleCharging()
        drainCallbacks()
        XCTAssertEqual(hw.writes, [], "standing by never writes")
        XCTAssertNil(monitor.lastError)

        hw.competing = nil
        monitor.refresh()
        drainCallbacks()
        XCTAssertNil(monitor.chargeControlHold)
        XCTAssertTrue(monitor.accountAuthorized)
        let pid = ProcessInfo.processInfo.processIdentifier
        XCTAssertEqual(Array(hw.writes.prefix(3)), ["nodischarge", "inhibit", "spawn-watchdog:\(pid)"],
                       "takeover runs the same reconciliation as a launch")
        XCTAssertTrue(monitor.chargingPaused)
    }

    func testTakeoverByAnUnauthorizedAccountPromptsOnceAndThenManages() {
        let hw = Hardware()
        hw.competing = "Ampere running as alice"
        hw.authorized = false
        let monitor = hw.monitor(startMonitoring: true)
        XCTAssertEqual(hw.installs, 0, "standing by never prompts")
        hw.competing = nil
        monitor.refresh()
        drainCallbacks()
        XCTAssertEqual(hw.installs, 1)
        XCTAssertTrue(monitor.accountAuthorized)
        XCTAssertNil(monitor.chargeControlHold)
        XCTAssertEqual(Array(hw.writes.prefix(2)), ["nodischarge", "inhibit"])
    }

    func testDeclinedTakeoverPromptHoldsChargeControlUntilTheNextGrant() {
        let hw = Hardware()
        hw.competing = "Ampere running as alice"
        hw.authorized = false
        hw.installSucceeds = false
        let monitor = hw.monitor(startMonitoring: true)
        hw.competing = nil
        monitor.refresh()
        monitor.refresh()
        monitor.prepareForSleep()
        monitor.resumeAfterWake()
        drainCallbacks()
        XCTAssertEqual(hw.installs, 1, "one prompt per takeover, not one per poll")
        XCTAssertEqual(monitor.chargeControlHold, .accessDeclined)
        XCTAssertFalse(monitor.standingBy, "the controls stay available so a click can grant access")
        XCTAssertFalse(monitor.accountAuthorized)
        XCTAssertEqual(hw.writes, [])

        hw.installSucceeds = true
        monitor.toggleCharging()
        awaitCondition { monitor.chargingPaused }
        XCTAssertEqual(hw.installs, 2)
        XCTAssertNil(monitor.chargeControlHold)
        XCTAssertTrue(monitor.accountAuthorized)
        XCTAssertEqual(hw.writes.first, "inhibit")
    }

    func testStandingByBlocksRevokeAndTheRestoreAtQuit() {
        let hw = Hardware()
        hw.competing = "Ampere running as alice"
        let monitor = hw.monitor(startMonitoring: true)
        monitor.removeSudoRule()
        drainCallbacks()
        XCTAssertEqual(monitor.lastError, "Charge control is in use by Ampere running as alice; revoke from that account")
        monitor.restoreBeforeTermination()
        XCTAssertEqual(hw.writes, [])
    }

    func testLaunchWithFullBatteryBelowLowerBoundDoesNotAllowCharging() {
        let hw = Hardware()
        hw.percentage = 94
        hw.full = true
        hw.preferences.values["chargeLowerBound"] = 95
        hw.preferences.values["chargeUpperBound"] = 100
        hw.preferences.values["chargeToUpperBound"] = true
        let monitor = hw.monitor(startMonitoring: true, locked: false)
        XCTAssertTrue(monitor.chargingPaused)
        XCTAssertFalse(monitor.chargeToUpperBound)
        XCTAssertFalse(hw.writes.contains("allow"))
    }

    func testExistingHelperForAnotherAccountTriggersSetup() {
        let hw = Hardware()
        hw.authorized = false
        let monitor = hw.monitor(startMonitoring: true)
        XCTAssertEqual(hw.installs, 1)
        XCTAssertTrue(monitor.chargingPaused)
    }

    func testExistingAuthorizedHelperDoesNotTriggerSetup() {
        let hw = Hardware()
        let monitor = hw.monitor(startMonitoring: true)
        XCTAssertEqual(hw.installs, 0)
        XCTAssertTrue(monitor.chargingPaused)
    }
}
