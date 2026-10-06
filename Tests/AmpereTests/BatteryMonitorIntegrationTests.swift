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
        /// True: the battery cannot be read this tick (IOKit failure).
        var unreadable = false
        var full = false
        var authorized = true
        var stale = false
        var installed = true
        var installs = 0
        /// False: the administrator prompt is cancelled.
        var installSucceeds = true
        /// Non-nil: an earlier Ampere process holds charge control.
        var competing: String?
        /// Non-nil: an installed copy the cleanup job should watch.
        var bundlePath: String?
        var daemonRegistered = false
        /// True: the SMC has no CHTE key (macOS 27 firmware), so the
        /// monitor takes the macOS charge-limit path.
        var chteMissing = false
        /// How many CHTE probes the SMC leaves unanswered (a transient
        /// IOKit failure) before it answers.
        var chteUnansweredProbes = 0
        /// True: this macOS has no charge limit (the PowerUI client class
        /// behind it is missing), as on macOS 15.
        var nativeClientMissing = false
        /// False: `pmset -g battlimit` fails, as it does where the getter
        /// does not exist.
        var limitsReadable = true
        /// The targets "powerd" enforces, as the native commands leave them.
        var registered: [Int] = []
        /// False: the helper's native-limit writes succeed but powerd never
        /// applies them (`registered` stays as it is).
        var enforcesLimits = true
        /// True: powerd's charge-to-full override is set (macOS is charging
        /// to full to calibrate the battery and ignores every limit).
        var chargeToFullOverride = false
        var clock = Date()
        /// What the owner answers at the authentication prompt behind the
        /// display option; nil leaves the prompt up until answerPrompt.
        var ownerAnswer: OwnerAuthentication.Outcome? = .granted
        /// The reason given to each prompt, in order.
        var prompts: [String] = []
        private var pendingPrompt: ((OwnerAuthentication.Outcome) -> Void)?
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

        func stopFailing(_ command: String) {
            lock.lock(); defer { lock.unlock() }
            failingCommands.remove(command)
        }

        func resetChargingKey() {
            lock.lock(); defer { lock.unlock() }
            chte = 0
        }

        /// The owner answers the prompt that `ownerAnswer = nil` left up.
        func answerPrompt(_ outcome: OwnerAuthentication.Outcome,
                          file: StaticString = #filePath, line: UInt = #line) {
            guard let reply = pendingPrompt else { return XCTFail("No prompt is up", file: file, line: line) }
            pendingPrompt = nil
            reply(outcome)
        }

        /// Someone else (System Settings, another tool) cleared the limit.
        func clearRegisteredLimits() {
            lock.lock(); defer { lock.unlock() }
            registered = []
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
            case "restore": chte = 0; chie = 0; held = false; registered = []
            case "native-limit-release": registered = []
            case "hold-sleep": held = true
            case "release-sleep-hold": held = false
            default:
                if command.hasPrefix("discharge:") { chie = 8; held = true }
                if command.hasPrefix("register-daemon:") { daemonRegistered = true }
                if command.hasPrefix("native-limit:"), enforcesLimits,
                   let n = Int(command.dropFirst("native-limit:".count)) {
                    registered = [n]
                }
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
            io.battery = { self.unreadable ? nil : self.reading() }
            io.lidClosed = { false }
            io.sleepDisabled = {
                self.lock.lock(); defer { self.lock.unlock() }
                return self.held
            }
            io.readKey = { key in
                self.lock.lock(); defer { self.lock.unlock() }
                if key == SMC.keyChargeTerminate { return self.chteMissing ? nil : [self.chte, 0, 0, 0] }
                return [self.chie]
            }
            io.chargeTerminateKey = {
                self.lock.lock(); defer { self.lock.unlock() }
                if self.chteUnansweredProbes > 0 {
                    self.chteUnansweredProbes -= 1
                    return .unknown
                }
                return self.chteMissing ? .missing : .present
            }
            io.nativeLimitClientAvailable = { !self.nativeClientMissing }
            io.registeredNativeLimits = {
                self.lock.lock(); defer { self.lock.unlock() }
                return self.limitsReadable ? self.registered : nil
            }
            io.chargeToFullOverride = { self.chargeToFullOverride }
            io.now = { self.clock }
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
            io.cleanupDaemonBundlePath = { self.bundlePath }
            io.cleanupDaemonRegistered = { _ in self.daemonRegistered }
            io.authenticateOwner = { reason, reply in
                self.prompts.append(reason)
                if let answer = self.ownerAnswer { reply(answer) } else { self.pendingPrompt = reply }
            }
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

    /// Charge to Full started on top of a charge to the upper bound (armed by
    /// rule 1 at a plug-in below the lower bound, or by its toggle) and
    /// cancelled between the bounds: the cancel clears the earlier intent
    /// too, so the inhibit holds. Left armed, the cycle after the inhibit
    /// would allow again and charging would resume toward the upper bound.
    func testCancelFullChargeClearsAnEarlierChargeToUpper() {
        let hw = Hardware(), monitor = hw.monitor()
        monitor.chargeToUpperBound = true
        monitor.setChargeToFull(true)
        drainCallbacks()
        XCTAssertEqual(hw.writes, [], "charging is already allowed; the full charge only raises the target")
        monitor.setChargeToFull(false)
        awaitCondition { monitor.chargingPaused && hw.writes.count >= 1 }
        for _ in 0..<2 { monitor.refresh() }
        drainCallbacks()
        XCTAssertEqual(hw.writes, ["inhibit"])
        XCTAssertTrue(monitor.chargingPaused)
        XCTAssertFalse(monitor.chargeToUpperBound)
        XCTAssertFalse(monitor.chargeToFull)
        XCTAssertEqual(hw.preferences.values["chargeToUpperBound"] as? Bool, false)
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

    func testSleepHoldWaitsForAWatchdogAndRetriesTheSpawn() {
        let hw = Hardware()
        hw.percentage = 30
        let spawn = "spawn-watchdog:\(pid)"
        hw.fail(spawn)
        let monitor = hw.monitor(startMonitoring: true)
        awaitCondition { hw.writes.count >= 4 }
        drainCallbacks()
        XCTAssertEqual(hw.writes, ["nodischarge", "allow", spawn, spawn],
                       "The launch spawn failed: the hold retries it once, then waits rather than block sleep with no crash net")
        XCTAssertTrue(monitor.chargeToUpperBound)
        XCTAssertFalse(monitor.sleepHoldActive)
        hw.stopFailing(spawn)
        monitor.refresh()
        awaitCondition { hw.writes.contains("hold-sleep") }
        XCTAssertEqual(Array(hw.writes.suffix(2)), [spawn, "hold-sleep"])
        XCTAssertTrue(monitor.sleepHoldActive)
        for _ in 0..<2 { monitor.refresh() }
        drainCallbacks()
        XCTAssertEqual(hw.writes.count, 6, "A running watchdog is not spawned again")
    }

    /// The hold's "spawn first" decision reads this table, so a wrong entry
    /// means either a hold with no crash net or a duplicate watchdog.
    func testWatchdogTrackingFollowsTheHelperCommands() {
        XCTAssertEqual(BatteryMonitor.watchdogSpawned(after: "spawn-watchdog:42", ok: true), true)
        XCTAssertEqual(BatteryMonitor.watchdogSpawned(after: "spawn-watchdog:42", ok: false), false)
        XCTAssertEqual(BatteryMonitor.watchdogSpawned(after: "discharge:42", ok: true), true,
                       "The discharge command spawns its own watchdog")
        XCTAssertEqual(BatteryMonitor.watchdogSpawned(after: "discharge:42", ok: false), false,
                       "A failed discharge rolls its watchdog back; the preceding nodischarge retired the old one")
        XCTAssertEqual(BatteryMonitor.watchdogSpawned(after: "nodischarge", ok: true), false)
        XCTAssertEqual(BatteryMonitor.watchdogSpawned(after: "restore", ok: true), false)
        XCTAssertNil(BatteryMonitor.watchdogSpawned(after: "nodischarge", ok: false),
                     "Watchdogs are retired last, so a failed restore leaves them running")
        XCTAssertNil(BatteryMonitor.watchdogSpawned(after: "restore", ok: false))
        for untouched in ["inhibit", "allow", "hold-sleep", "release-sleep-hold", "native-limit:60",
                          "native-limit-release", "register-daemon:/Applications/Ampere.app"] {
            XCTAssertNil(BatteryMonitor.watchdogSpawned(after: untouched, ok: true), untouched)
            XCTAssertNil(BatteryMonitor.watchdogSpawned(after: untouched, ok: false), untouched)
        }
    }

    func testSleepHoldNeedsNoSpawnWhenTheLaunchWatchdogIsRunning() {
        let hw = Hardware()
        hw.percentage = 30
        let monitor = hw.monitor(startMonitoring: true)
        awaitCondition { hw.writes.contains("hold-sleep") }
        XCTAssertEqual(hw.writes, ["nodischarge", "allow", "spawn-watchdog:\(pid)", "hold-sleep"])
        XCTAssertTrue(monitor.sleepHoldActive)
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

    func testLaunchRegistersTheCleanupJobForAnInstalledCopy() {
        let hw = Hardware()
        hw.bundlePath = "/Applications/Ampere.app"
        let monitor = hw.monitor(startMonitoring: true)
        let pid = ProcessInfo.processInfo.processIdentifier
        XCTAssertEqual(Array(hw.writes.prefix(4)), ["nodischarge", "inhibit", "spawn-watchdog:\(pid)",
                                                     "register-daemon:/Applications/Ampere.app"],
                       "registered over the passwordless rule, after the launch cleanup")
        XCTAssertTrue(hw.daemonRegistered)
        XCTAssertTrue(monitor.accountAuthorized)
    }

    func testLaunchLeavesARegisteredCleanupJobAlone() {
        let hw = Hardware()
        hw.bundlePath = "/Applications/Ampere.app"
        hw.daemonRegistered = true
        _ = hw.monitor(startMonitoring: true)
        XCTAssertFalse(hw.writes.contains { $0.hasPrefix("register-daemon:") })
    }

    func testADebugBuildOrTranslocatedCopyRegistersNoCleanupJob() {
        let hw = Hardware()
        XCTAssertNil(hw.bundlePath)
        _ = hw.monitor(startMonitoring: true)
        XCTAssertFalse(hw.writes.contains { $0.hasPrefix("register-daemon:") })
    }

    func testGrantingAccessAgainRegistersTheCleanupJob() {
        let hw = Hardware()
        hw.bundlePath = "/Applications/Ampere.app"
        hw.competing = "Ampere running as alice"
        hw.authorized = false
        hw.installSucceeds = false
        let monitor = hw.monitor(startMonitoring: true)
        hw.competing = nil
        monitor.refresh()
        drainCallbacks()
        XCTAssertEqual(monitor.chargeControlHold, .accessDeclined)
        XCTAssertFalse(hw.daemonRegistered, "a declined prompt registers nothing")

        hw.installSucceeds = true
        monitor.toggleCharging()
        awaitCondition { monitor.chargingPaused }
        XCTAssertTrue(hw.daemonRegistered)
        XCTAssertEqual(hw.writes, ["register-daemon:/Applications/Ampere.app", "inhibit"])
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

    // MARK: - Native charge limit (firmware without CHTE)

    private var pid: Int32 { ProcessInfo.processInfo.processIdentifier }

    /// A monitor that took charge control on CHTE-less firmware: launch
    /// cleanup skips the inhibit write and the first poll hands the macOS
    /// charge limit its target.
    private func nativeMonitor(_ hw: Hardware) -> BatteryMonitor {
        hw.chteMissing = true
        let monitor = hw.monitor(startMonitoring: true)
        XCTAssertTrue(monitor.nativeLimitMode)
        awaitCondition { hw.writes.count >= 4 }
        return monitor
    }

    func testNativeMode_LaunchBetweenBoundsHoldsAtTheCurrentLevel() {
        let hw = Hardware()
        hw.percentage = 50
        let monitor = nativeMonitor(hw)
        XCTAssertEqual(hw.writes, ["nodischarge", "native-limit-release", "spawn-watchdog:\(pid)", "native-limit:50"],
                       "Launch cleanup releases whatever a crashed session left, then the first poll sets the target")
        XCTAssertTrue(monitor.chargingPaused)
        // The firmware may let the level tick up before the target applies:
        // the hold follows it up, once per new level, so nothing is drained
        // back to 50.
        hw.percentage = 51
        monitor.refresh()
        awaitCondition { hw.writes.last == "native-limit:51" }
        for _ in 0..<3 { monitor.refresh() }
        drainCallbacks()
        XCTAssertEqual(hw.writes.count, 5, "The same level is not written twice")
        // A dip under load on AC is not followed; the firmware charges it back.
        hw.percentage = 50
        for _ in 0..<2 { monitor.refresh() }
        drainCallbacks()
        XCTAssertEqual(hw.writes.count, 5)
        XCTAssertFalse(hw.writes.contains("inhibit"))
        XCTAssertFalse(hw.writes.contains("allow"))
    }

    func testNativeMode_BelowLowerChargesToUpperThenHoldsThere() {
        let hw = Hardware()
        hw.percentage = 30
        let monitor = nativeMonitor(hw)
        XCTAssertEqual(hw.writes.last, "native-limit:60")
        XCTAssertTrue(monitor.chargeToUpperBound)
        XCTAssertFalse(monitor.chargingPaused)
        hw.percentage = 60
        monitor.refresh()
        drainCallbacks()
        XCTAssertTrue(monitor.chargingPaused)
        XCTAssertFalse(monitor.chargeToUpperBound)
        XCTAssertEqual(hw.writes.filter { $0.hasPrefix("native-limit:") }, ["native-limit:60"],
                       "Reaching the bound turns the target into a hold without another write")
    }

    func testNativeMode_UnplugTracksTheLevelDownSoAReconnectDoesNotCharge() {
        let hw = Hardware()
        hw.percentage = 50
        let monitor = nativeMonitor(hw)
        hw.connected = false
        hw.percentage = 45
        monitor.refresh()
        awaitCondition { hw.writes.last == "native-limit:45" }
        hw.percentage = 44
        monitor.refresh()
        awaitCondition { hw.writes.last == "native-limit:44" }
        hw.connected = true
        for _ in 0..<2 { monitor.refresh() }
        drainCallbacks()
        XCTAssertEqual(hw.writes.last, "native-limit:44", "Reconnecting between the bounds parks at the current level")
        XCTAssertTrue(monitor.chargingPaused)
    }

    func testNativeMode_DischargeToUpperIsTheFirmwareDrain() {
        let hw = Hardware()
        hw.percentage = 80
        hw.preferences.values["autoDischargeEnabled"] = true
        let monitor = nativeMonitor(hw)
        XCTAssertEqual(hw.writes.last, "native-limit:60")
        XCTAssertTrue(monitor.activeDischarging)
        XCTAssertFalse(hw.writes.contains { $0.hasPrefix("discharge:") }, "CHIE is never written in native mode")
        hw.percentage = 60
        monitor.refresh()
        drainCallbacks()
        XCTAssertFalse(monitor.activeDischarging)
        XCTAssertEqual(hw.writes.filter { $0.hasPrefix("native-limit:") }, ["native-limit:60"])
    }

    /// macOS's own calibration charge: powerd sets its charge-to-full
    /// override, charges the battery to 100%, and ignores the limit
    /// meanwhile, while still registering every target it is handed. The
    /// panel must not call that a hold (the status line and the ETA read
    /// the published flag and chargingTarget), the health check must not
    /// pass on a limit nobody enforces, and the hold must keep following
    /// the level up so that when the override clears the limit is where
    /// the battery is and the hold resumes there, as after Charge to Full.
    /// Full does not end the override (powerd lifts it by the clock, about
    /// 12 hours after it began): the panel then says the charge is done
    /// and the wait is on (nativeCalibrationChargeDone), still suspended.
    func testNativeMode_MacOSCalibrationChargeOverridesTheHold() {
        let hw = Hardware()
        hw.percentage = 47
        let monitor = nativeMonitor(hw)
        XCTAssertEqual(hw.writes.last, "native-limit:47")
        XCTAssertTrue(monitor.chargingPaused)
        for _ in 0..<5 { monitor.refresh() }
        drainCallbacks()
        XCTAssertEqual(monitor.lastHealthCheckStatus, "pass")
        XCTAssertEqual(monitor.lastHealthCheckSMC, "macOS limit=47%\nCHIE=0x00")
        XCTAssertFalse(monitor.nativeChargeToFullOverride)
        XCTAssertFalse(monitor.chargeLimitOverridden)
        XCTAssertFalse(monitor.nativeCalibrationChargeDone)
        XCTAssertEqual(monitor.chargingTarget, 60)

        // The override begins and the level starts climbing.
        hw.chargeToFullOverride = true
        hw.percentage = 48
        monitor.refresh()
        XCTAssertTrue(monitor.nativeChargeToFullOverride, "Read on the poll that saw it")
        XCTAssertTrue(monitor.chargeLimitOverridden)
        XCTAssertEqual(monitor.chargingTarget, 100, "The ETA aims at full")
        XCTAssertFalse(monitor.nativeCalibrationChargeDone, "Not full yet")
        awaitCondition { hw.writes.last == "native-limit:48" }
        drainCallbacks()
        monitor.refresh()
        drainCallbacks()
        XCTAssertEqual(monitor.lastHealthCheckStatus, "suspended")
        XCTAssertEqual(monitor.lastHealthCheckSMC, "macOS limit=48% (ignored by macOS)\nCHIE=0x00")
        XCTAssertEqual(monitor.lastHealthCheckExpected, "")
        XCTAssertNil(monitor.healthWarning)
        XCTAssertTrue(monitor.chargingPaused, "The state machine's hold stands; only macOS ignores it")
        XCTAssertFalse(monitor.chargeToUpperBound)

        // Full. The hold has followed the level there.
        hw.percentage = 100
        monitor.refresh()
        awaitCondition { hw.writes.last == "native-limit:100" }
        drainCallbacks()
        monitor.refresh()
        drainCallbacks()
        XCTAssertEqual(monitor.lastHealthCheckSMC, "macOS limit=100% (ignored by macOS)\nCHIE=0x00")
        XCTAssertEqual(monitor.lastHealthCheckStatus, "suspended", "Full battery or not, nobody enforces the limit")
        XCTAssertTrue(monitor.nativeChargeToFullOverride, "Full does not end the override; powerd lifts it by the clock")
        XCTAssertTrue(monitor.chargeLimitOverridden)
        XCTAssertTrue(monitor.nativeCalibrationChargeDone, "The charge is done and the wait is on")

        // The override clears: the limit applies again, at the level the
        // battery is at, and the hold resumes there with discharge off.
        hw.chargeToFullOverride = false
        monitor.refresh()
        drainCallbacks()
        XCTAssertFalse(monitor.nativeChargeToFullOverride)
        XCTAssertFalse(monitor.chargeLimitOverridden)
        XCTAssertFalse(monitor.nativeCalibrationChargeDone)
        XCTAssertEqual(monitor.chargingTarget, 60)
        XCTAssertEqual(monitor.lastHealthCheckStatus, "pass")
        XCTAssertEqual(monitor.lastHealthCheckSMC, "macOS limit=100%\nCHIE=0x00")
        XCTAssertTrue(monitor.chargingPaused)
        XCTAssertFalse(monitor.activeDischarging)
        XCTAssertEqual(hw.writes.filter { $0.hasPrefix("native-limit:") },
                       ["native-limit:47", "native-limit:48", "native-limit:100"])
    }

    /// A Charge to Full is not overridden by the calibration charge: both
    /// go to 100, so the panel keeps describing the user's own request.
    func testNativeMode_CalibrationChargeDoesNotOverrideAChargeToFull() {
        let hw = Hardware()
        hw.percentage = 50
        let monitor = nativeMonitor(hw)
        monitor.setChargeToFull(true)
        awaitCondition { hw.writes.last == "native-limit:100" }
        drainCallbacks()
        hw.chargeToFullOverride = true
        monitor.refresh()
        drainCallbacks()
        XCTAssertTrue(monitor.nativeChargeToFullOverride)
        XCTAssertFalse(monitor.chargeLimitOverridden)
        XCTAssertEqual(monitor.chargingTarget, 100)
    }

    /// A worn battery's BMS can end the calibration charge below a
    /// displayed 100%: the gauge's fully-charged flag, not the percentage,
    /// says the charge is done, as for every other bound at 100.
    func testNativeMode_CalibrationChargeDoneWhenFullyChargedBelow100() {
        let hw = Hardware()
        hw.percentage = 50
        let monitor = nativeMonitor(hw)
        hw.chargeToFullOverride = true
        hw.percentage = 99
        monitor.refresh()
        awaitCondition { hw.writes.last == "native-limit:99" }
        drainCallbacks()
        XCTAssertTrue(monitor.chargeLimitOverridden)
        XCTAssertFalse(monitor.nativeCalibrationChargeDone)
        hw.full = true
        monitor.refresh()
        drainCallbacks()
        XCTAssertTrue(monitor.nativeCalibrationChargeDone)
        XCTAssertTrue(monitor.chargeLimitOverridden, "Done is not over: the override stands until powerd's next check")
    }

    func testNativeMode_AboveUpperWithoutDischargeHoldsWhereItIs() {
        let hw = Hardware()
        hw.percentage = 80
        let monitor = nativeMonitor(hw)
        XCTAssertEqual(hw.writes.last, "native-limit:80")
        XCTAssertFalse(monitor.activeDischarging)
    }

    func testNativeMode_ManualPauseHoldsAndResumeReleases() {
        let hw = Hardware()
        hw.preferences.values["autoManageEnabled"] = false
        hw.percentage = 50
        hw.chteMissing = true
        let monitor = hw.monitor(startMonitoring: true)
        drainCallbacks()
        XCTAssertEqual(hw.writes, ["nodischarge", "native-limit-release", "spawn-watchdog:\(pid)"],
                       "Manual mode leaves the macOS setting alone once launch cleanup has released any leftover")
        monitor.toggleCharging()
        awaitCondition { hw.writes.last == "native-limit:50" }
        XCTAssertTrue(monitor.chargingPaused)
        monitor.toggleCharging()
        awaitCondition { hw.writes.last == "native-limit-release" }
        XCTAssertFalse(monitor.chargingPaused)
    }

    func testNativeMode_HealthCheckPassesThenRepairsADriftedLimit() {
        let hw = Hardware()
        hw.percentage = 50
        let monitor = nativeMonitor(hw)
        for _ in 0..<5 { monitor.refresh() }
        drainCallbacks()
        XCTAssertEqual(monitor.lastHealthCheckStatus, "pass")
        XCTAssertEqual(monitor.lastHealthCheckSMC, "macOS limit=50%\nCHIE=0x00")
        // Someone else cleared the limit. Inside the settle window nothing is
        // reported; past it the check fails silently and re-issues the target.
        hw.clearRegisteredLimits()
        monitor.refresh()
        drainCallbacks()
        XCTAssertEqual(monitor.lastHealthCheckStatus, "pass", "Still settling: no verdict yet")
        hw.clock = hw.clock.addingTimeInterval(200)
        monitor.refresh()
        drainCallbacks()
        XCTAssertEqual(monitor.lastHealthCheckStatus, "FAIL")
        XCTAssertNil(monitor.healthWarning, "The first repair is silent")
        monitor.refresh()
        awaitCondition { hw.writes.filter { $0 == "native-limit:50" }.count == 2 }
        hw.clock = hw.clock.addingTimeInterval(200)
        for _ in 0..<2 { monitor.refresh() }
        drainCallbacks()
        XCTAssertEqual(monitor.lastHealthCheckStatus, "pass")
        XCTAssertNil(monitor.healthWarning)
    }

    func testNativeMode_ALimitThatNeverSticksWarnsAfterOneSilentRepair() {
        let hw = Hardware()
        hw.percentage = 50
        let monitor = nativeMonitor(hw)
        for _ in 0..<5 { monitor.refresh() }
        drainCallbacks()
        XCTAssertEqual(monitor.lastHealthCheckStatus, "pass")
        // powerd drops the limit and applies none of the re-issued targets.
        hw.enforcesLimits = false
        hw.clearRegisteredLimits()
        hw.clock = hw.clock.addingTimeInterval(200)
        monitor.refresh()
        drainCallbacks()
        XCTAssertEqual(monitor.lastHealthCheckStatus, "FAIL")
        XCTAssertNil(monitor.healthWarning, "The first repair is silent")
        monitor.refresh()
        awaitCondition { hw.writes.filter { $0 == "native-limit:50" }.count == 2 }
        hw.clock = hw.clock.addingTimeInterval(200)
        monitor.refresh()
        drainCallbacks()
        XCTAssertEqual(monitor.lastHealthCheckStatus, "FAIL")
        XCTAssertNotNil(monitor.healthWarning,
                        "A mismatch that survives a repair shows the warning; the repair write landing proves nothing")
        // Enforcement returns: the next repair sticks and the warning clears.
        hw.enforcesLimits = true
        monitor.refresh()
        awaitCondition { hw.writes.filter { $0 == "native-limit:50" }.count == 3 }
        hw.clock = hw.clock.addingTimeInterval(200)
        for _ in 0..<2 { monitor.refresh() }
        drainCallbacks()
        XCTAssertEqual(monitor.lastHealthCheckStatus, "pass")
        XCTAssertNil(monitor.healthWarning)
    }

    /// The same cancel through the macOS charge limit: a full charge started
    /// on top of a charge to the upper bound settles on a hold at the
    /// current level, not on the upper bound.
    func testNativeMode_CancelFullChargeClearsAnEarlierChargeToUpper() {
        let hw = Hardware()
        hw.percentage = 50
        let monitor = nativeMonitor(hw)
        monitor.chargeToUpperBound = true
        monitor.refresh()
        awaitCondition { hw.writes.last == "native-limit:60" }
        monitor.setChargeToFull(true)
        awaitCondition { hw.writes.last == "native-limit:100" }
        monitor.setChargeToFull(false)
        awaitCondition { hw.writes.last == "native-limit:50" }
        for _ in 0..<2 { monitor.refresh() }
        drainCallbacks()
        XCTAssertEqual(Array(hw.writes.suffix(3)), ["native-limit:60", "native-limit:100", "native-limit:50"])
        XCTAssertTrue(monitor.chargingPaused)
        XCTAssertFalse(monitor.chargeToUpperBound)
        XCTAssertFalse(monitor.chargeToFull)
    }

    func testNativeMode_CancelledFullChargeIsHeldWhenItsWriteCompletes() {
        let hw = Hardware()
        hw.percentage = 50
        let monitor = nativeMonitor(hw)
        let gate = hw.blockNext("native-limit:100")
        monitor.setChargeToFull(true)
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 3), .success)
        monitor.setChargeToFull(false)
        gate.release.signal()
        awaitCondition { hw.writes.last == "native-limit:50" }
        XCTAssertEqual(Array(hw.writes.suffix(2)), ["native-limit:100", "native-limit:50"],
                       "The hold lands from the write's own completion, not at the next poll")
        XCTAssertTrue(monitor.chargingPaused)
        XCTAssertFalse(monitor.chargeToFull)
        for _ in 0..<2 { monitor.refresh() }
        drainCallbacks()
        XCTAssertEqual(hw.writes.filter { $0 == "native-limit:50" }.count, 2, "Later polls find the hold current")
    }

    func testNativeMode_FullChargeCancelledDuringItsWriteIsSettledBeforeSleep() {
        let hw = Hardware()
        hw.percentage = 50
        let monitor = nativeMonitor(hw)
        let gate = hw.blockNext("native-limit:100")
        monitor.setChargeToFull(true)
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 3), .success)
        monitor.setChargeToFull(false)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) { gate.release.signal() }
        monitor.prepareForSleep()
        XCTAssertEqual(Array(hw.writes.suffix(2)), ["native-limit:100", "native-limit:50"],
                       "The hold lands before sleep; refresh is blocked until wake")
        drainCallbacks() // the taken-over write's queued completion runs and changes nothing
        monitor.refresh()
        XCTAssertEqual(hw.writes.last, "native-limit:50")
        monitor.resumeAfterWake()
        drainCallbacks()
        XCTAssertEqual(hw.writes.filter { $0 == "native-limit:50" }.count, 2, "Wake finds the target current")
        XCTAssertTrue(monitor.chargingPaused)
        XCTAssertFalse(monitor.chargeToFull)
    }

    func testNativeMode_SleepHooksWriteNothingAndQuitRestores() {
        let hw = Hardware()
        hw.percentage = 50
        let monitor = nativeMonitor(hw)
        let before = hw.writes.count
        monitor.prepareForSleep()
        monitor.resumeAfterWake()
        drainCallbacks()
        XCTAssertEqual(hw.writes.count, before, "No pre-sleep pause and no wake re-assert: the firmware holds the target")
        monitor.restoreBeforeTermination()
        XCTAssertEqual(hw.writes.last, "restore")
    }

    // MARK: - No mechanism (firmware without CHTE under a macOS without the charge limit)

    func testNoMechanism_MonitorsOnlyWithoutInstallingOrWritingAnything() {
        let hw = Hardware()
        hw.chteMissing = true
        hw.nativeClientMissing = true
        hw.installed = false
        hw.authorized = false
        let monitor = hw.monitor(startMonitoring: true)
        drainCallbacks()
        XCTAssertEqual(monitor.chargeControlHold, .noMechanism)
        XCTAssertFalse(monitor.nativeLimitMode)
        XCTAssertTrue(monitor.controlsUnavailable)
        XCTAssertFalse(monitor.accountAuthorized)
        XCTAssertEqual(hw.installs, 0, "No admin prompt for a helper that could do nothing")
        XCTAssertEqual(hw.writes, [])
        XCTAssertNotNil(monitor.state, "Battery information still flows")
        // Every control path declines without a misleading error, and the
        // sleep hooks and quit write nothing: nothing of ours is in force.
        monitor.toggleCharging()
        for _ in 0..<3 { monitor.refresh() }
        monitor.prepareForSleep()
        monitor.resumeAfterWake()
        monitor.restoreBeforeTermination()
        drainCallbacks()
        XCTAssertEqual(hw.writes, [])
        XCTAssertEqual(hw.installs, 0)
        XCTAssertNil(monitor.lastError)
    }

    func testNoMechanism_WhenPmsetCannotReportLimits_KeepsALeftoverHelperRevocable() {
        let hw = Hardware()
        hw.chteMissing = true
        hw.limitsReadable = false
        let monitor = hw.monitor(startMonitoring: true)
        drainCallbacks()
        XCTAssertEqual(monitor.chargeControlHold, .noMechanism)
        XCTAssertFalse(monitor.nativeLimitMode)
        XCTAssertEqual(hw.writes, [], "No launch cleanup, no watchdog")
        XCTAssertTrue(monitor.accountAuthorized, "A helper an earlier version installed is still this account's to revoke")
    }

    func testMechanism_CHTEWinsWhereBothExist() {
        let hw = Hardware()
        hw.percentage = 50
        let monitor = hw.monitor(startMonitoring: true)
        awaitCondition { hw.writes.count >= 3 }
        XCTAssertFalse(monitor.nativeLimitMode)
        XCTAssertNil(monitor.chargeControlHold)
        XCTAssertEqual(hw.writes.prefix(3), ["nodischarge", "inhibit", "spawn-watchdog:\(pid)"])
    }

    func testMechanism_AnUnansweredProbeIsRepeatedBeforeTheMechanismIsDecided() {
        let hw = Hardware()
        hw.percentage = 50
        hw.chteUnansweredProbes = 2
        let monitor = hw.monitor(startMonitoring: true)
        awaitCondition { hw.writes.count >= 3 }
        XCTAssertNil(monitor.chargeControlHold)
        XCTAssertFalse(monitor.nativeLimitMode, "Two failed reads did not pass for firmware without CHTE")
        XCTAssertEqual(hw.writes.prefix(3), ["nodischarge", "inhibit", "spawn-watchdog:\(pid)"])
    }

    func testMechanism_AnSMCThatKeepsNotAnsweringHoldsChargeControlUntilItDoes() {
        let hw = Hardware()
        hw.percentage = 50
        hw.installed = false
        hw.authorized = false
        // Three probes per activation: the launch's, then the first poll's,
        // which asks again at once.
        hw.chteUnansweredProbes = 6
        let monitor = hw.monitor(startMonitoring: true)
        drainCallbacks()
        XCTAssertEqual(monitor.chargeControlHold, .mechanismUnknown)
        XCTAssertTrue(monitor.controlsUnavailable)
        XCTAssertFalse(monitor.nativeLimitMode)
        XCTAssertEqual(hw.installs, 0, "No admin prompt while nothing could be written")
        XCTAssertEqual(hw.writes, [])
        monitor.toggleCharging()
        drainCallbacks()
        XCTAssertEqual(hw.writes, [])
        XCTAssertEqual(hw.installs, 0)
        XCTAssertNil(monitor.lastError, "The status line already explains the hold")
        // The SMC answers at a later poll: activation runs as it would have
        // at launch, prompt and cleanup included.
        monitor.refresh()
        awaitCondition { hw.writes.count >= 3 }
        XCTAssertNil(monitor.chargeControlHold)
        XCTAssertEqual(hw.installs, 1)
        XCTAssertEqual(hw.writes.prefix(3), ["nodischarge", "inhibit", "spawn-watchdog:\(pid)"])
        XCTAssertTrue(monitor.chargingPaused)
    }

    // MARK: - Launch cleanup retry

    func testLaunchCleanup_AFailedRestoreIsRetriedUntilItSucceeds() {
        let hw = Hardware()
        hw.percentage = 50
        hw.fail("nodischarge")
        let monitor = hw.monitor(startMonitoring: true)
        drainCallbacks()
        XCTAssertEqual(hw.writes, ["nodischarge", "inhibit", "spawn-watchdog:\(pid)"])
        XCTAssertEqual(monitor.recoveryWarning, BatteryMonitor.launchCleanupWarning)
        // The next polls run the state machine, not the retry.
        for _ in 0..<2 { monitor.refresh() }
        drainCallbacks()
        XCTAssertEqual(hw.writes.count, 3)
        // Past the interval: one attempt, which fails; the warning stays.
        hw.clock = hw.clock.addingTimeInterval(130)
        monitor.refresh()
        awaitCondition { hw.writes.count == 4 }
        drainCallbacks()
        XCTAssertEqual(hw.writes.last, "nodischarge")
        XCTAssertEqual(monitor.recoveryWarning, BatteryMonitor.launchCleanupWarning)
        monitor.refresh()
        drainCallbacks()
        XCTAssertEqual(hw.writes.count, 4, "Not again before the next interval")
        // pmset answers again: the restore lands, a watchdog replaces the
        // one it retired, and the warning clears.
        hw.stopFailing("nodischarge")
        hw.clock = hw.clock.addingTimeInterval(130)
        monitor.refresh()
        awaitCondition { hw.writes.count >= 6 && monitor.recoveryWarning == nil }
        XCTAssertEqual(Array(hw.writes.suffix(2)), ["nodischarge", "spawn-watchdog:\(pid)"])
        for _ in 0..<2 { monitor.refresh() }
        drainCallbacks()
        XCTAssertEqual(hw.writes.count, 6)
    }

    // MARK: - Native mode: unconfirmed limits and a missing watchdog

    func testNativeMode_TurningAutoChargeOffAfterADriftedLimitStillReleases() {
        let hw = Hardware()
        hw.percentage = 50
        let monitor = nativeMonitor(hw)
        for _ in 0..<5 { monitor.refresh() }
        drainCallbacks()
        XCTAssertEqual(monitor.lastHealthCheckStatus, "pass")
        // Something else moved the limit; past the settle window the check
        // forgets the target so the next poll re-issues it.
        hw.registered = [40]
        hw.clock = hw.clock.addingTimeInterval(200)
        monitor.refresh()
        drainCallbacks()
        XCTAssertEqual(monitor.lastHealthCheckStatus, "FAIL")
        // Auto Charge goes off before that poll: nothing cached is not the
        // same as released, so the release is still issued.
        monitor.autoManageEnabled = false
        monitor.refresh()
        awaitCondition { hw.writes.count == 5 && hw.writes.last == "native-limit-release" }
        XCTAssertEqual(hw.registered, [])
        XCTAssertFalse(monitor.chargingPaused)
        hw.clock = hw.clock.addingTimeInterval(200)
        for _ in 0..<2 { monitor.refresh() }
        drainCallbacks()
        XCTAssertEqual(monitor.lastHealthCheckStatus, "pass")
        XCTAssertEqual(hw.writes.count, 5, "One release at launch, one now, nothing more")
    }

    func testNativeMode_ALaunchReleaseThatFailedIsRetriedByTheFirstPollEvenWithAutoChargeOff() {
        let hw = Hardware()
        hw.preferences.values["autoManageEnabled"] = false
        hw.percentage = 50
        hw.chteMissing = true
        hw.registered = [40]   // a crashed session's hold, still enforced
        hw.fail("native-limit-release")
        let monitor = hw.monitor(startMonitoring: true)
        awaitCondition { hw.writes.count >= 4 }
        drainCallbacks()
        XCTAssertEqual(hw.writes, ["nodischarge", "native-limit-release", "spawn-watchdog:\(pid)", "native-limit-release"],
                       "Nothing cached is not the same as released: the first poll releases again")
        XCTAssertNotNil(monitor.lastError)
        // The helper recovers: the release lands and the polls go quiet.
        hw.stopFailing("native-limit-release")
        monitor.refresh()
        awaitCondition { hw.writes.count == 5 && monitor.lastError == nil }
        XCTAssertEqual(hw.registered, [])
        for _ in 0..<3 { monitor.refresh() }
        drainCallbacks()
        XCTAssertEqual(hw.writes.count, 5)
        XCTAssertEqual(monitor.lastHealthCheckStatus, "pass")
    }

    func testNativeMode_AFailedWatchdogSpawnIsRetriedBeforeEachWriteAndReported() {
        let hw = Hardware()
        hw.percentage = 50
        hw.chteMissing = true
        hw.fail("spawn-watchdog:\(pid)")
        let monitor = hw.monitor(startMonitoring: true)
        awaitCondition { hw.writes.count >= 5 }
        drainCallbacks()
        XCTAssertEqual(hw.writes, ["nodischarge", "native-limit-release", "spawn-watchdog:\(pid)",
                                   "spawn-watchdog:\(pid)", "native-limit:50"],
                       "The limit is written without the safety net rather than withheld")
        XCTAssertTrue(monitor.chargingPaused)
        monitor.refresh()
        drainCallbacks()
        XCTAssertEqual(monitor.recoveryWarning, BatteryMonitor.watchdogMissingWarning)
        // The helper manages a spawn again: the next write is covered and
        // the warning clears.
        hw.stopFailing("spawn-watchdog:\(pid)")
        hw.percentage = 51
        monitor.refresh()
        awaitCondition { hw.writes.last == "native-limit:51" }
        monitor.refresh()
        drainCallbacks()
        XCTAssertEqual(Array(hw.writes.suffix(2)), ["spawn-watchdog:\(pid)", "native-limit:51"])
        XCTAssertNil(monitor.recoveryWarning)
        hw.percentage = 52
        monitor.refresh()
        awaitCondition { hw.writes.last == "native-limit:52" }
        XCTAssertEqual(hw.writes.count, 8, "A running watchdog is not spawned again")
    }

    // MARK: - Keep Awake display option

    func testKeepAwakeDisplay_PersistsAcrossRestartWithItsSessionAndDefaultsToOff() {
        let hw = Hardware()
        XCTAssertFalse(hw.monitor().keepAwakeDisplay, "Off until the user confirms it")
        hw.preferences.values["keepAwakeEnabled"] = true
        hw.preferences.values["keepAwakeDisplay"] = true
        let monitor = hw.monitor()
        XCTAssertTrue(monitor.keepAwakeEnabled)
        XCTAssertTrue(monitor.keepAwakeDisplay, "A restart mid-session resumes the same kind of hold")
        XCTAssertEqual(hw.prompts, [], "Resuming the owner's own choice asks nothing")
        monitor.turnOffKeepAwakeDisplay()
        XCTAssertEqual(hw.preferences.values["keepAwakeDisplay"] as? Bool, false)
        XCTAssertFalse(hw.monitor().keepAwakeDisplay)
    }

    func testKeepAwakeDisplay_RefusedWhileTheToggleIsOff() {
        let hw = Hardware(), monitor = hw.monitor()
        var ends: [BatteryMonitor.KeepAwakeDisplayRequest] = []
        monitor.requestKeepAwakeDisplay { ends.append($0) }
        XCTAssertEqual(ends, [.noSession], "An option of the running session only")
        XCTAssertFalse(monitor.keepAwakeDisplay)
        XCTAssertNil(hw.preferences.values["keepAwakeDisplay"])
        XCTAssertEqual(hw.prompts, [], "Nothing to turn on, so the owner is not asked")
        monitor.setKeepAwake(true)
        monitor.requestKeepAwakeDisplay { ends.append($0) }
        XCTAssertEqual(ends, [.noSession, .on])
        XCTAssertTrue(monitor.keepAwakeDisplay)
        XCTAssertEqual(hw.prompts, [BatteryMonitor.keepAwakeDisplayReason])
    }

    func testKeepAwakeDisplay_TurnsOnOnlyWhenTheOwnerAuthenticates() {
        let hw = Hardware(), monitor = hw.monitor()
        monitor.setKeepAwake(true)
        var ends: [BatteryMonitor.KeepAwakeDisplayRequest] = []
        hw.ownerAnswer = .cancelled
        monitor.requestKeepAwakeDisplay { ends.append($0) }
        XCTAssertEqual(ends, [.declined])
        XCTAssertFalse(monitor.keepAwakeDisplay)
        XCTAssertNil(hw.preferences.values["keepAwakeDisplay"], "A declined prompt persists nothing")
        hw.ownerAnswer = .failed("Passcode not set.")
        monitor.requestKeepAwakeDisplay { ends.append($0) }
        XCTAssertEqual(ends, [.declined, .failed("Passcode not set.")])
        XCTAssertFalse(monitor.keepAwakeDisplay)
        hw.ownerAnswer = .granted
        monitor.requestKeepAwakeDisplay { ends.append($0) }
        XCTAssertEqual(ends, [.declined, .failed("Passcode not set."), .on])
        XCTAssertTrue(monitor.keepAwakeDisplay)
        XCTAssertEqual(hw.preferences.values["keepAwakeDisplay"] as? Bool, true)
        XCTAssertFalse(monitor.keepAwakeDisplayAuthenticating)
        XCTAssertEqual(hw.prompts.count, 3, "Every request prompts afresh")
        // Already on there is nothing to confirm, and the way off never asks.
        monitor.requestKeepAwakeDisplay { ends.append($0) }
        XCTAssertEqual(ends.last, .on)
        monitor.turnOffKeepAwakeDisplay()
        XCTAssertFalse(monitor.keepAwakeDisplay)
        XCTAssertEqual(hw.preferences.values["keepAwakeDisplay"] as? Bool, false)
        XCTAssertEqual(hw.prompts.count, 3)
    }

    func testKeepAwakeDisplay_PromptOutlivingTheSessionTurnsNothingOn() {
        let hw = Hardware(), monitor = hw.monitor()
        monitor.refresh()
        monitor.setKeepAwake(true)
        hw.ownerAnswer = nil
        var ends: [BatteryMonitor.KeepAwakeDisplayRequest] = []
        monitor.requestKeepAwakeDisplay { ends.append($0) }
        XCTAssertTrue(monitor.keepAwakeDisplayAuthenticating)
        XCTAssertEqual(ends, [])
        // A second request while the prompt is up gets no second prompt.
        monitor.requestKeepAwakeDisplay { ends.append($0) }
        XCTAssertEqual(ends, [.declined])
        XCTAssertEqual(hw.prompts.count, 1)
        // Unplugged before the owner answers: the session is over, and a
        // confirmation that arrives now turns nothing on.
        hw.connected = false
        monitor.refresh()
        XCTAssertFalse(monitor.keepAwakeEnabled)
        hw.answerPrompt(.granted)
        XCTAssertEqual(ends, [.declined, .noSession])
        XCTAssertFalse(monitor.keepAwakeDisplay)
        XCTAssertFalse(monitor.keepAwakeDisplayAuthenticating)
        XCTAssertNotEqual(hw.preferences.values["keepAwakeDisplay"] as? Bool, true)
        // The next session asks again from scratch.
        hw.connected = true
        monitor.refresh()
        monitor.setKeepAwake(true)
        hw.ownerAnswer = .granted
        monitor.requestKeepAwakeDisplay { ends.append($0) }
        XCTAssertEqual(ends.last, .on)
        XCTAssertTrue(monitor.keepAwakeDisplay)
        XCTAssertEqual(hw.prompts.count, 2)
    }

    func testKeepAwakeDisplay_OffWithoutASessionAtLaunch() {
        // A build that persisted the option on its own may leave it on with
        // the toggle off; the invariant is restored at launch.
        let hw = Hardware()
        hw.preferences.values["keepAwakeDisplay"] = true
        XCTAssertFalse(hw.monitor().keepAwakeDisplay)
        XCTAssertEqual(hw.preferences.values["keepAwakeDisplay"] as? Bool, false)
        // Same for a session that expired while the app was not running.
        hw.preferences.values["keepAwakeEnabled"] = true
        hw.preferences.values["keepAwakeDeadline"] = Date().addingTimeInterval(-60).timeIntervalSince1970
        hw.preferences.values["keepAwakeDisplay"] = true
        let monitor = hw.monitor()
        XCTAssertFalse(monitor.keepAwakeEnabled)
        XCTAssertFalse(monitor.keepAwakeDisplay)
        XCTAssertEqual(hw.preferences.values["keepAwakeDisplay"] as? Bool, false)
    }

    func testKeepAwake_TurningTheToggleOffTurnsTheDisplayOptionOff() {
        let hw = Hardware(), monitor = hw.monitor()
        monitor.setKeepAwake(true)
        monitor.requestKeepAwakeDisplay { _ in }
        monitor.setKeepAwake(false)
        XCTAssertFalse(monitor.keepAwakeDisplay)
        XCTAssertEqual(hw.preferences.values["keepAwakeDisplay"] as? Bool, false)
        XCTAssertEqual(hw.preferences.values["keepAwakeEnabled"] as? Bool, false)
    }

    func testKeepAwake_ExpiryTurnsBothOff() {
        let hw = Hardware()
        hw.preferences.values["keepAwakeEnabled"] = true
        hw.preferences.values["keepAwakeDisplay"] = true
        hw.preferences.values["keepAwakeDeadline"] = Date().addingTimeInterval(0.3).timeIntervalSince1970
        let monitor = hw.monitor()
        XCTAssertTrue(monitor.keepAwakeEnabled)
        monitor.refresh() // arms the expiry timer the init could not
        awaitCondition { !monitor.keepAwakeEnabled }
        XCTAssertFalse(monitor.keepAwakeDisplay)
        XCTAssertNil(monitor.keepAwakeDeadline)
        XCTAssertEqual(hw.preferences.values["keepAwakeDisplay"] as? Bool, false)
        XCTAssertNil(hw.preferences.values["keepAwakeDeadline"])
    }

    func testKeepAwake_UnpluggingEndsTheSessionAndReconnectingStartsNothing() {
        let hw = Hardware(), monitor = hw.monitor()
        monitor.refresh()
        monitor.setKeepAwake(true)
        monitor.requestKeepAwakeDisplay { _ in }
        hw.connected = false
        monitor.refresh()
        XCTAssertFalse(monitor.keepAwakeEnabled)
        XCTAssertFalse(monitor.keepAwakeDisplay)
        XCTAssertNil(monitor.keepAwakeDeadline)
        XCTAssertEqual(hw.preferences.values["keepAwakeEnabled"] as? Bool, false)
        XCTAssertEqual(hw.preferences.values["keepAwakeDisplay"] as? Bool, false)
        hw.connected = true
        monitor.refresh()
        XCTAssertFalse(monitor.keepAwakeEnabled, "Plugging back in starts nothing")
        XCTAssertFalse(monitor.keepAwakeDisplay)
    }

    func testKeepAwake_LaunchOnBatteryEndsAPersistedSession() {
        // The app crashed mid-session and relaunches unplugged: the first
        // poll does what the unplug would have done.
        let hw = Hardware()
        hw.connected = false
        hw.preferences.values["keepAwakeEnabled"] = true
        hw.preferences.values["keepAwakeDisplay"] = true
        let monitor = hw.monitor()
        XCTAssertTrue(monitor.keepAwakeEnabled, "Init cannot tell yet; the first poll decides")
        monitor.refresh()
        XCTAssertFalse(monitor.keepAwakeEnabled)
        XCTAssertFalse(monitor.keepAwakeDisplay)
        XCTAssertEqual(hw.preferences.values["keepAwakeEnabled"] as? Bool, false)
        XCTAssertEqual(hw.preferences.values["keepAwakeDisplay"] as? Bool, false)
    }

    func testKeepAwake_AFailedBatteryReadKeepsTheSession() {
        let hw = Hardware(), monitor = hw.monitor()
        monitor.refresh()
        monitor.setKeepAwake(true)
        monitor.requestKeepAwakeDisplay { _ in }
        hw.unreadable = true
        monitor.refresh()
        XCTAssertTrue(monitor.keepAwakeEnabled, "Unknown is not unplugged")
        XCTAssertTrue(monitor.keepAwakeDisplay)
        hw.unreadable = false
        monitor.refresh()
        XCTAssertTrue(monitor.keepAwakeEnabled)
    }
}
