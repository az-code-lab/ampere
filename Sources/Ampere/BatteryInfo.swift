import Foundation
import AppKit
import CryptoKit
import IOKit.ps
import IOKit.pwr_mgt
import Shared

/// Persistence is injected so integration tests can exercise real callbacks
/// without changing the user's settings or invoking privileged operations.
protocol BatteryPreferences: AnyObject {
    func bool(forKey key: String) -> Bool
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
}

extension UserDefaults: BatteryPreferences {}

struct BatteryState: Equatable {
    let percentage: Int
    let cycleCount: Int
    let isCharging: Bool
    let adapterConnected: Bool
    let health: String
    let temperature: Double
    let timeRemaining: String
    let designCapacity: Int
    let maxCapacity: Int
    let currentCapacity: Int
    /// Battery current in mA. Sign convention: positive = into battery
    /// (charging), negative = out of battery (discharging). Several
    /// downstream consumers (`PowerFlowRouter`, `BatteryModeRouter`,
    /// `BatteryETACalculator`, `effectivelyCharging`) treat this sign as
    /// the source of truth for direction, ahead of `isCharging`.
    let amperage: Double?
    let voltage: Double?
    let adapterWatts: Double?
    let adapterAmperage: Double?
    let adapterVoltage: Double?
    let electronicsWatts: Double?
    /// Battery power in W (= `voltage * amperage / 1000`). Same sign
    /// convention as `amperage`: positive = charging, negative = draining.
    let batteryWatts: Double?
    let batteryAgeYears: String   // e.g. "4y 6m"
    let batteryAgeDays: String    // e.g. "1643d"
    /// BMS "charge terminated at full" flag. Worn batteries can terminate
    /// below a displayed 100%, so any 100%-targeting logic (Charge to Full,
    /// an upper bound of 100) must treat this as "target reached" or it
    /// would hold CHTE=allow forever, trickle-charging at the top.
    let fullyCharged: Bool
}

final class BatteryMonitor: ObservableObject {
    struct IO {
        var battery: () -> BatteryState? = BatteryMonitor.readBattery
        var lidClosed: () -> Bool = BatteryMonitor.readClamshellClosed
        var sleepDisabled: () -> Bool = readSleepDisabledFlag
        var readKey: (String) -> [UInt8]? = BatteryMonitor.smcReadKey
        var writeHelper: (String) -> Bool = BatteryMonitor.executeHelper
        var helperInstalled: () -> Bool = {
            FileManager.default.fileExists(atPath: AppConstants.sudoersPath)
                && HelperSecurity.isProtected(path: AppConstants.helperPath)
        }
        var helperAuthorized: () -> Bool = BatteryMonitor.checkHelperAuthorization
        var helperStale: () -> Bool = BatteryMonitor.helperNeedsUpdate
        var installHelper: () -> Bool = BatteryMonitor.installSudo
        var runAsAdmin: (String) -> Bool = BatteryMonitor.runAsAdmin
    }

    private let defaults: BatteryPreferences
    private let io: IO
    /// Changes to user intent or the AC session invalidate an in-flight
    /// decision's saved intentions, but not the hardware write it completed.
    private var controlRevision: UInt64 = 0
    private var requestedChargingPaused: Bool? {
        didSet { if oldValue != requestedChargingPaused { controlRevision &+= 1 } }
    }
    private var preparingForSleep = false
    private var terminating = false
    private var wakeReassertPending = false
    @Published var state: BatteryState?
    @Published var chargingPaused: Bool = false
    @Published var activeDischarging: Bool = false
    /// True while the helper's sleep hold (pmset override) is actually
    /// applied — the status line warns while the Mac is being kept awake.
    /// Distinct from the persisted intent (`sleepHoldIntent`): intent is
    /// what the state machine wants, this is what the helper has done;
    /// refresh() reconciles the two, retrying failed ops every tick.
    @Published var sleepHoldActive: Bool = false
    @Published var autoDischargeEnabled: Bool {
        didSet {
            if oldValue != autoDischargeEnabled { controlRevision &+= 1 }
            defaults.set(autoDischargeEnabled, forKey: "autoDischargeEnabled")
        }
    }
    @Published var chargeToUpperBound: Bool {
        didSet {
            if oldValue != chargeToUpperBound { controlRevision &+= 1 }
            defaults.set(chargeToUpperBound, forKey: "chargeToUpperBound")
        }
    }
    /// One-shot "Charge to Full" override. While set, the effective upper
    /// bound is 100 — the configured bounds are untouched. Cleared by the
    /// state machine when the battery is full (100% or the BMS says so) or
    /// the adapter disconnects, and by the UI when toggled off or
    /// auto-manage is disabled. Persisted so an in-progress full charge
    /// resumes across restart/crash.
    @Published var chargeToFull: Bool {
        didSet {
            if oldValue != chargeToFull { controlRevision &+= 1 }
            defaults.set(chargeToFull, forKey: "chargeToFull")
        }
    }
    /// The charge ceiling currently in force: 100 while "Charge to Full" is
    /// active, otherwise the configured upper bound. UI labels and ETA/
    /// animation targets read this so they can never disagree with the
    /// state machine about where charging will stop.
    var effectiveUpperBound: Int { chargeToFull ? 100 : chargeUpperBound }
    /// Show the "77%" text beside the menu bar battery icon; off = icon
    /// only, halving the menu bar footprint. Lives here rather than in
    /// @AppStorage because AppDelegate (not the SwiftUI tree) renders the
    /// menu bar item and needs a change signal via objectWillChange.
    @Published var showMenuBarPercent: Bool {
        didSet { defaults.set(showMenuBarPercent, forKey: "showMenuBarPercent") }
    }
    /// Keep-awake toggle: hold a powerd assertion (the caffeinate
    /// mechanism) that prevents idle system sleep while the adapter is
    /// connected. Deliberately NOT the helper's pmset sleep hold: an
    /// assertion needs no root, is refcounted per process, and the kernel
    /// drops it on crash/quit, so it can never strand the system. The
    /// trade-off is that it cannot absorb lid-close sleep — that remains
    /// exclusive to the charge/discharge overrides. On battery the intent
    /// persists but the assertion is released (see
    /// keepAwakeAssertionDesired); the display still sleeps normally.
    @Published var keepAwakeEnabled: Bool {
        didSet { defaults.set(keepAwakeEnabled, forKey: "keepAwakeEnabled") }
    }
    /// Session length in minutes; 0 = no deadline (hold until toggled off).
    @Published var keepAwakeMinutes: Int {
        didSet { defaults.set(keepAwakeMinutes, forKey: "keepAwakeMinutes") }
    }
    /// Wall-clock end of the current keep-awake session; nil while off or
    /// for a Forever session. Persisted as an absolute date so a restart
    /// mid-session resumes the remaining time rather than a fresh window,
    /// and time on battery counts against it (the promise is "awake until
    /// 3:45", not "3 hours of awake time"). Written only via
    /// setKeepAwakeDeadline so the stored value and the expiry timer can't
    /// diverge.
    @Published private(set) var keepAwakeDeadline: Date?
    @Published var lastError: String?
    @Published var pinned: Bool = false
    @Published var healthWarning: String?
    @Published var lastHealthCheckStatus: String = "pending"
    @Published var lastHealthCheckSMC: String = ""
    @Published var lastHealthCheckExpected: String = ""
    @Published var lastHealthCheckCHTEMatch: Bool = true
    @Published var lastHealthCheckCHIEMatch: Bool = true
    @Published var lastHealthCheckTime: Date?
    /// nil = no update; otherwise the newer release advertised by the
    /// Homebrew cask, carrying everything installUpdate needs to fetch and
    /// verify the DMG (see Updater.swift).
    @Published var updateAvailable: AvailableUpdate?
    /// Lifecycle of an in-flight click-to-update install (see Updater.swift).
    @Published var updateState: UpdateState = .idle
    /// Feedback for a user-initiated "Check for Updates" click. Automatic
    /// (daily) checks stay silent and never touch this.
    enum ManualUpdateCheck { case none, checking, upToDate, failed }
    @Published var manualUpdateCheck: ManualUpdateCheck = .none
    /// Invalidates the delayed reset of an outcome when a newer manual
    /// check starts before the previous outcome's text has cleared.
    private var manualCheckGeneration = 0
    @Published var isPopoverVisible: Bool = false
    /// True while a sheet (About) is presented over the panel.
    /// Pure UI state like `isPopoverVisible` — not persisted. While true the
    /// popover must not close: tearing down an NSPopover underneath an
    /// attached SwiftUI sheet strands the sheet's presentation state, and
    /// the reopened panel sits behind an invisible modal, dead to clicks.
    @Published var sheetVisible: Bool = false
    /// True while the settings rows are shown below the panel footer.
    /// Pure UI state like `isPopoverVisible` — not persisted, and lives here
    /// rather than as ContentView @State because AppDelegate must fold the
    /// section whenever the panel closes (popover or detached window): the
    /// hidden view isn't recreated on reopen, and offscreen SwiftUI onChange
    /// delivery is not guaranteed.
    @Published var settingsExpanded: Bool = false

    @Published var autoManageEnabled: Bool {
        didSet {
            if oldValue != autoManageEnabled { controlRevision &+= 1 }
            if oldValue && !autoManageEnabled {
                chargeToUpperBound = false
                chargeToFull = false
                // Queue a resume even if an in-flight inhibit has not yet
                // updated chargingPaused. refresh() serializes the request.
                requestedChargingPaused = false
            }
            defaults.set(autoManageEnabled, forKey: "autoManageEnabled")
        }
    }
    /// Minimum gap between charge bounds, matches the slider's `minGap`.
    static let chargeBoundMinGap = 5
    /// The range every copy starts with, and the only range an unregistered
    /// copy runs (see `chargeBoundsLocked`).
    static let defaultChargeLowerBound = 40
    static let defaultChargeUpperBound = 60

    /// True while the bounds are pinned to the defaults because the copy is
    /// unregistered. Custom charge bounds are the licensed feature:
    /// AppDelegate mirrors `!RegistrationManager.isRegistered` here, at
    /// launch through the init parameter (so the launch-time inhibit/allow
    /// decision already reads the locked range) and on every later change,
    /// whether from the registration window or a daily verify that finds
    /// the license revoked or moved to another Mac. Engaging the lock
    /// resets both bounds to the defaults, and while it holds, any other
    /// assignment is undone by the bounds' didSets, so the persisted values
    /// never diverge from the range in force. Not persisted itself: the
    /// registration state it derives from is.
    @Published var chargeBoundsLocked: Bool {
        didSet {
            if chargeBoundsLocked { resetChargeBoundsToDefaults() }
        }
    }

    @Published var chargeLowerBound: Int {
        didSet {
            if oldValue != chargeLowerBound { controlRevision &+= 1 }
            if chargeBoundsLocked && chargeLowerBound != Self.defaultChargeLowerBound {
                // Locked: the only legal value is the default. Reset both
                // ends together instead of fixing this one in place, so the
                // gap clamp below can never fight the correction.
                resetChargeBoundsToDefaults()
            } else if chargeLowerBound < 0 { chargeLowerBound = 0 }
            else if chargeLowerBound > chargeUpperBound - Self.chargeBoundMinGap {
                chargeLowerBound = chargeUpperBound - Self.chargeBoundMinGap
            }
            defaults.set(chargeLowerBound, forKey: "chargeLowerBound")
        }
    }
    @Published var chargeUpperBound: Int {
        didSet {
            if oldValue != chargeUpperBound { controlRevision &+= 1 }
            if chargeBoundsLocked && chargeUpperBound != Self.defaultChargeUpperBound {
                resetChargeBoundsToDefaults()
            } else if chargeUpperBound > 100 { chargeUpperBound = 100 }
            else if chargeUpperBound < chargeLowerBound + Self.chargeBoundMinGap {
                chargeUpperBound = chargeLowerBound + Self.chargeBoundMinGap
            }
            defaults.set(chargeUpperBound, forKey: "chargeUpperBound")
        }
    }

    /// Put both bounds back to the defaults, in the assignment order the gap
    /// clamps accept: lower first when the default lower fits under the
    /// current upper, otherwise upper first. One of the two always works.
    /// If neither did, the current range would lie both entirely below the
    /// default lower and entirely above the default upper, which is
    /// impossible for a valid pair (and while locked, the other end is
    /// already at its default, so a transient single-ended violation
    /// cannot block both orders either). Each assignment re-enters the
    /// didSets with a default value, which the lock guard accepts.
    private func resetChargeBoundsToDefaults() {
        let lower = Self.defaultChargeLowerBound
        let upper = Self.defaultChargeUpperBound
        if lower <= chargeUpperBound - Self.chargeBoundMinGap {
            if chargeLowerBound != lower { chargeLowerBound = lower }
            if chargeUpperBound != upper { chargeUpperBound = upper }
        } else {
            if chargeUpperBound != upper { chargeUpperBound = upper }
            if chargeLowerBound != lower { chargeLowerBound = lower }
        }
    }

    /// The bounds to run with, given what UserDefaults held (nil = never
    /// saved). Repairs, in order: each end clamped to 0...100; both reset to
    /// the defaults if the saved gap violates the minGap invariant
    /// (corrupted defaults, or values written by an older build); and while
    /// the bounds are locked, the defaults regardless of what was saved. A
    /// custom range left behind by a registration that lapsed must not
    /// resurface on the next launch of the now-unregistered copy.
    static func repairedChargeBounds(lower: Int?, upper: Int?, locked: Bool) -> (lower: Int, upper: Int) {
        if locked { return (defaultChargeLowerBound, defaultChargeUpperBound) }
        var lower = lower ?? defaultChargeLowerBound
        var upper = upper ?? defaultChargeUpperBound
        if lower < 0 { lower = 0 }
        if upper > 100 { upper = 100 }
        if upper - lower < chargeBoundMinGap {
            return (defaultChargeLowerBound, defaultChargeUpperBound)
        }
        return (lower, upper)
    }

    private var timer: Timer?
    private var updateCheckTimer: Timer?
    /// The held powerd assertion backing keepAwakeEnabled; 0/false = none.
    /// Reconciled against the desired state every refresh tick, same
    /// retry-until-they-match contract as sleepHoldActive vs intent.
    private var keepAwakeAssertionID: IOPMAssertionID = 0
    private var keepAwakeAssertionHeld = false
    /// One-shot timer at the session deadline, so expiry lands on time
    /// instead of waiting out the current poll interval (up to 60 s).
    private var keepAwakeExpiryTimer: Timer?
    /// IOKit power-source change notifications (plug/unplug, charge ticks)
    /// drive an immediate refresh; removed from the run loop in deinit.
    private var powerSourceRunLoopSource: CFRunLoopSource?
    // Self-update plumbing, used by the extension in Updater.swift. Not
    // `private`: stored properties can't live in a cross-file extension,
    // but the logic that touches them does.
    var updateDownloadTask: URLSessionDownloadTask?
    var updateProgressObservation: NSKeyValueObservation?
    private var terminationObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var autoManageInFlight = false
    /// True once the health check has dispatched a CHTE repair for the
    /// current unhealthy episode; cleared on the next healthy check. The
    /// first repair runs silently (a transient firmware reset that the very
    /// next check confirms fixed shouldn't flash the red warning); only a
    /// mismatch that survives a repair attempt surfaces it, where "revoke &
    /// re-grant admin" is plausible advice again.
    private var chteRepairAttempted = false
    /// Sleep-hold intent from the state machine, persisted so a crash or
    /// in-app upgrade mid-hold re-arms after relaunch (launch cleanup always
    /// restores pmset via nodischarge, so without the persisted intent a
    /// lid-closed Mac would fall asleep mid-band with the charge unfinished).
    private var sleepHoldIntent: Bool = false {
        didSet {
            guard oldValue != sleepHoldIntent else { return }
            controlRevision &+= 1
            defaults.set(sleepHoldIntent, forKey: "sleepHoldIntent")
        }
    }
    private var refreshCount = 0
    /// Persisted so rule-2 (connected→disconnected → clear chargeToUpperBound)
    /// fires correctly across an app restart. Without this, a launch on
    /// battery loses the "we were on AC" memory and rule 2 silently no-ops,
    /// causing the persisted chargeToUpperBound to auto-resume on the next
    /// reconnect — the opposite of what the rule is for.
    private var lastAdapterConnected: Bool? {
        didSet {
            // Skip the UserDefaults write when the value didn't actually
            // change — refresh re-assigns this every cycle.
            guard oldValue != lastAdapterConnected else { return }
            controlRevision &+= 1
            // Encode nil as absence; only persist concrete true/false.
            if let v = lastAdapterConnected {
                defaults.set(v, forKey: "lastAdapterConnected")
            } else {
                defaults.removeObject(forKey: "lastAdapterConnected")
            }
        }
    }
    private let smcQueue = DispatchQueue(label: "com.ampere.smc", qos: .utility)

    /// Single source of truth for the "no adapter" error string — it's
    /// both set (in toggleCharging) and compared (in refresh) to clear on
    /// reconnect; literal duplication would let a typo silently break the
    /// clear path.
    private static let noAdapterError = "No power adapter connected"

    /// Shown when the SMC persistently disagrees with the expected state.
    /// Single definition because performHealthCheck both suppresses it (the
    /// first, silent repair attempt) and sets it (repair didn't stick, or
    /// wasn't applicable) — the strings must stay identical for that
    /// sequence to read as one warning.
    private static let smcMismatchWarning = "SMC mismatch — revoke & re-grant admin"

    /// Skip health checks on the first N refresh cycles so launch-time SMC
    /// writes have a chance to settle before we assert on their results.
    private static let healthCheckSettleRefreshes = 3

    private static let sudoersPath = AppConstants.sudoersPath
    private static let helperPath = AppConstants.helperPath

    /// `chargeBoundsLocked`: true for an unregistered copy, so the bounds are
    /// pinned to the defaults from the launch-time SMC decision onward (see
    /// the property).
    init(chargeBoundsLocked: Bool, defaults: BatteryPreferences = UserDefaults.standard,
         io: IO = IO(), startMonitoring: Bool = true) {
        self.defaults = defaults
        self.io = io
        self.chargeBoundsLocked = chargeBoundsLocked
        // Load persisted auto-manage settings
        let autoManage = defaults.bool(forKey: "autoManageEnabled")
        self.autoManageEnabled = autoManage
        self.autoDischargeEnabled = defaults.bool(forKey: "autoDischargeEnabled")
        // Default true (shown) — bool(forKey:) would read a missing key as false.
        self.showMenuBarPercent = defaults.object(forKey: "showMenuBarPercent") as? Bool ?? true
        // Keep-awake: restore the toggle and its wall-clock deadline. A
        // deadline that passed while the app wasn't running means the
        // session is over — restore "off" and persist the negation (didSet
        // doesn't fire during init), same pattern as the flag repairs
        // below. A deadline found without its toggle is half-written state
        // from a crash between the two defaults writes; drop it. The
        // assertion itself is re-acquired by the first refresh's reconcile,
        // and the expiry timer by the same path (timers can't be scheduled
        // this early in init anyway).
        // Repair a corrupted duration to Forever — a value outside the
        // preset list would leave the picker with no selected item.
        let storedKeepAwakeMinutes = defaults.object(forKey: "keepAwakeMinutes") as? Int ?? 0
        self.keepAwakeMinutes = Self.keepAwakeDurations.contains(storedKeepAwakeMinutes)
            ? storedKeepAwakeMinutes : 0
        let persistedKeepAwake = defaults.bool(forKey: "keepAwakeEnabled")
        let persistedKeepAwakeDeadline = (defaults.object(forKey: "keepAwakeDeadline") as? Double)
            .map { Date(timeIntervalSince1970: $0) }
        if persistedKeepAwake, let deadline = persistedKeepAwakeDeadline, deadline <= Date() {
            self.keepAwakeEnabled = false
            self.keepAwakeDeadline = nil
            defaults.set(false, forKey: "keepAwakeEnabled")
            defaults.removeObject(forKey: "keepAwakeDeadline")
        } else {
            self.keepAwakeEnabled = persistedKeepAwake
            self.keepAwakeDeadline = persistedKeepAwake ? persistedKeepAwakeDeadline : nil
            if !persistedKeepAwake, persistedKeepAwakeDeadline != nil {
                defaults.removeObject(forKey: "keepAwakeDeadline")
            }
        }
        let originalLower = defaults.object(forKey: "chargeLowerBound") as? Int
        let originalUpper = defaults.object(forKey: "chargeUpperBound") as? Int
        // didSet doesn't fire on init, so this is the only chance to repair
        // the saved values (repairedChargeBounds lists what gets repaired).
        let bounds = Self.repairedChargeBounds(lower: originalLower, upper: originalUpper,
                                               locked: chargeBoundsLocked)
        self.chargeLowerBound = bounds.lower
        self.chargeUpperBound = bounds.upper
        // Persist the repair if it differs from what was on disk, otherwise
        // the corrupted (or locked-out custom) values would resurface on
        // every launch.
        if originalLower != bounds.lower { defaults.set(bounds.lower, forKey: "chargeLowerBound") }
        if originalUpper != bounds.upper { defaults.set(bounds.upper, forKey: "chargeUpperBound") }
        // Charge-to-upper intent persists across restart so a crash mid-recovery
        // resumes the in-progress charge rather than parking at the current level.
        // Clear it if auto-manage is disabled (it has no effect outside auto mode).
        let persistedCtu = defaults.bool(forKey: "chargeToUpperBound")
        self.chargeToUpperBound = autoManage && persistedCtu
        // Charge-to-full follows the same persist/restore contract as
        // charge-to-upper: survive a restart mid-charge, but drop it when
        // auto-manage is off (the state machine that acts on it only runs
        // in auto mode). Assigned before the reads below — self can't be
        // touched until every stored property is initialized.
        let persistedCtf = defaults.bool(forKey: "chargeToFull")
        self.chargeToFull = autoManage && persistedCtf
        // Persist the negations (autoManage=false but a persisted true would
        // otherwise stay diverged from in-memory state forever, since didSet
        // doesn't fire during init).
        if !self.chargeToUpperBound && persistedCtu {
            defaults.set(false, forKey: "chargeToUpperBound")
        }
        if !self.chargeToFull && persistedCtf {
            defaults.set(false, forKey: "chargeToFull")
        }
        // Sleep-hold intent rides on charge-to-upper: it only means anything
        // while that intent is armed. The pmset side always starts released
        // (launch cleanup runs nodischarge, which restores any crash-left
        // markers); the first refresh re-applies the hold when the intent
        // survived. If the ctu crash repair below clears the intent's
        // carrier, the first refresh releases this flag too — didSet doesn't
        // fire during init, so persist the negation explicitly like the two
        // flags above.
        let persistedHold = defaults.bool(forKey: "sleepHoldIntent")
        self.sleepHoldIntent = self.chargeToUpperBound && persistedHold
        if !self.sleepHoldIntent && persistedHold {
            defaults.set(false, forKey: "sleepHoldIntent")
        }
        // Invariant: chargeToFull implies auto-discharge is off (activating
        // it turns the preference off — see setChargeToFull). Both entry
        // points enforce this, so a violation here means corrupted defaults;
        // repair in favor of the full charge, since draining right after an
        // explicit "charge me to 100%" is never what the user meant.
        if self.chargeToFull && self.autoDischargeEnabled {
            self.autoDischargeEnabled = false
            defaults.set(false, forKey: "autoDischargeEnabled")
        }
        // Restore the last-known adapter state so rule 2 (connected→disconnected
        // → clear chargeToUpperBound) can fire on the first refresh after a
        // restart that crossed an adapter transition.
        self.lastAdapterConnected = defaults.object(forKey: "lastAdapterConnected") as? Bool

        // chargingPaused starts false; the launch-cleanup block below may
        // set it to true if shouldInhibit applies. Not persisted — always
        // derived fresh from the rule conditions at launch.
        chargingPaused = false
        guard startMonitoring else { return }
        // Install/update the helper or authorize this macOS account.
        // brew uninstall would have removed the helper; a fresh app build
        // would have a different helper binary. The install prompts for
        // admin via osascript; cancellation terminates the app.
        if !isSudoRuleInstalled || io.helperStale() || !io.helperAuthorized() {
            NSLog("Ampere: Helper needs installation, update, or authorization")
            if !io.installHelper() {
                NSLog("Ampere: Helper install failed or cancelled, quitting")
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Admin Access Required"
                    alert.informativeText = "Ampere needs admin access to install its helper tool. Please relaunch and enter your admin password."
                    alert.alertStyle = .critical
                    alert.runModal()
                    NSApp.terminate(nil)
                }
                return
            }
        }
        if isSudoRuleInstalled {
            // Read battery once and remember whether the read actually
            // succeeded — a failed read returns nil and `?? 0` would falsely
            // claim "below lower bound", silently overwriting the persisted
            // chargeToUpperBound value next time around.
            let launchBattery = self.io.battery()
            let launchPercentage = launchBattery?.percentage ?? 0
            // Crash-recovery sanity: chargeToUpperBound=true is only valid below
            // the upper bound. A crash between the state machine's CHTE=inhibit
            // write and its in-memory ctu=false update can leave ctu=true
            // persisted with pct already at/above upper. Without this correction,
            // shouldInhibit below would compute false and the launch cleanup
            // would briefly write CHTE=allow, violating the invariant until the
            // first refresh self-corrects. reachedBound: for a 100% upper
            // bound the BMS fully-charged flag counts as "at the bound",
            // same rule the state machine applies.
            if chargeToUpperBound, let lb = launchBattery,
               Self.reachedBound(chargeUpperBound, percentage: lb.percentage,
                                 fullyCharged: lb.fullyCharged) {
                chargeToUpperBound = false
                defaults.set(false, forKey: "chargeToUpperBound")
            }
            // Same crash-window repair for charge-to-full against its own
            // target: a crash between the at-full inhibit write and the
            // in-memory clear must not resurrect the override.
            if chargeToFull, let lb = launchBattery,
               Self.reachedBound(100, percentage: lb.percentage,
                                 fullyCharged: lb.fullyCharged) {
                chargeToFull = false
                defaults.set(false, forKey: "chargeToFull")
            }
            // Respect persisted charge-to-upper/-full intent: if either is
            // set, skip the inhibit so the in-progress charge survives a
            // restart.
            let shouldInhibit = autoManageEnabled
                && launchBattery != nil
                && (launchPercentage >= chargeLowerBound
                    || Self.reachedBound(effectiveUpperBound, percentage: launchPercentage,
                                         fullyCharged: launchBattery?.fullyCharged ?? false))
                && !chargeToUpperBound
                && !chargeToFull
            if shouldInhibit {
                chargingPaused = true
            } else if autoManageEnabled, launchBattery != nil,
                      launchPercentage < chargeLowerBound {
                // Rule 1: below lower bound at launch — charge all the way to upper
                chargeToUpperBound = true
                // didSet doesn't fire during init, so explicitly persist —
                // otherwise a quit-and-restart mid-charge wouldn't see the
                // intent saved, breaking the "in-progress charge resumes"
                // promise the README makes for this path.
                defaults.set(true, forKey: "chargeToUpperBound")
            }
            // Cleanup runs synchronously here so the SMC is in the
            // expected state by the time refresh() starts dispatching
            // auto-manage actions — otherwise refresh's state machine
            // could race against an in-flight cleanup write.
            let okDischarge = runSMCWriteViaSudo("nodischarge")
            let okChte = runSMCWriteViaSudo(shouldInhibit ? "inhibit" : "allow")
            let pid = ProcessInfo.processInfo.processIdentifier
            let okWatchdog = runSMCWriteViaSudo("spawn-watchdog:\(pid)")
            if okDischarge && okChte {
                NSLog("Ampere: Launch cleanup done (inhibit=%d)", shouldInhibit)
            } else {
                NSLog("Ampere: Launch cleanup failed (nodischarge=%d, chte=%d)", okDischarge, okChte)
            }
            if !okWatchdog {
                NSLog("Ampere: Watchdog spawn failed at launch — crash safety net not installed")
            }
        }

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // React to power-source changes the moment they happen instead of
        // waiting out the poll interval: rule 2 and the charge-to-full
        // session semantics key off the connected→disconnected edge, which
        // a short unplug could otherwise slip past entirely between polls,
        // and a discharge left running after an unplug should stop within
        // seconds, not at the next tick. The timer above remains the
        // fallback cadence and drives health checks when nothing changes.
        // passUnretained is safe: the source is removed in deinit, so no
        // callback can outlive self. The callback fires on the run loop the
        // source is added to — main, where refresh() belongs.
        let iopsContext = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue().refresh()
        }, iopsContext)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSourceRunLoopSource = source
        } else {
            NSLog("Ampere: IOPS notification source unavailable — timer-only polling")
        }
        // Check for updates: 5 minutes after launch, then once daily at a random interval
        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { [weak self] _ in
            self?.checkForUpdate()
            self?.scheduleNextUpdateCheck()
        }

        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.restoreBeforeTermination()
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.prepareForSleep()
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.resumeAfterWake()
        }
    }

    func restoreBeforeTermination() {
        terminating = true
        guard isSudoRuleInstalled else { return }
        let done = DispatchSemaphore(value: 0)
        smcQueue.async {
            // A single helper transaction restores both SMC keys and sleep
            // before retiring the watchdog. Failure leaves it alive to retry
            // after this app exits. Queueing also covers an in-flight write
            // that has not published chargingPaused/activeDischarging yet.
            _ = self.runSMCWriteViaSudo("restore")
            done.signal()
        }
        _ = done.wait(timeout: .now() + 6)
    }

    /// Block new poll-driven writes before draining those already queued.
    /// chargingPaused may still be true while an allow is in flight, so it
    /// must not gate the final inhibit. The last write also honors a newer
    /// full-charge or manual-resume request whose callback is still pending.
    func prepareForSleep() {
        preparingForSleep = true
        smcQueue.sync {}
        guard isSudoRuleInstalled, let battery = io.battery(), battery.adapterConnected else { return }
        let pause: Bool
        if autoManageEnabled {
            // Between bounds, pause until wake. Full-charge and below-lower
            // sessions may charge through sleep, as documented.
            pause = Self.reachedBound(effectiveUpperBound, percentage: battery.percentage,
                                      fullyCharged: battery.fullyCharged)
                || (!chargeToFull && battery.percentage >= chargeLowerBound)
        } else if let requested = requestedChargingPaused {
            pause = requested
        } else {
            return
        }
        let ok = smcQueue.sync { runSMCWrite(pause ? .inhibit : .allow) }
        NSLog("Ampere: Pre-sleep %@ at %d%% %@", pause ? "pause" : "resume",
              battery.percentage, ok ? "applied" : "failed")
    }

    func resumeAfterWake() {
        preparingForSleep = false
        // Keep this pending if another callback still owns the in-flight
        // token. Its completion refresh will perform the re-assertion.
        wakeReassertPending = true
        refresh()
    }

    deinit {
        timer?.invalidate()
        updateCheckTimer?.invalidate()
        keepAwakeExpiryTimer?.invalidate()
        // Redundant with process exit (the kernel drops assertions of a
        // dead process) but keeps a torn-down monitor from pinning the
        // system awake for the remainder of the process's lifetime.
        if keepAwakeAssertionHeld { IOPMAssertionRelease(keepAwakeAssertionID) }
        updateDownloadTask?.cancel()
        if let source = powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        if let observer = terminationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let observer = sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    /// Switch to fast (10s) or slow (60s) polling based on popover visibility.
    func setFastPolling(_ fast: Bool) {
        isPopoverVisible = fast
        timer?.invalidate()
        let interval: TimeInterval = fast ? 10.0 : 60.0
        if fast { refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // MARK: - Update Check

    private static let caskURL = URL(string: "https://raw.githubusercontent.com/az-code-lab/homebrew-taps/main/Casks/ampere.rb")!

    private func scheduleNextUpdateCheck() {
        // ~Once per day, with ±2h jitter so multiple clients don't all hit the
        // cask repo at the same instant after a coordinated event (e.g. mass
        // reboot, brew upgrade wave).
        updateCheckTimer = Timer.scheduledTimer(
            withTimeInterval: Double.random(in: 79200 ..< 93600),
            repeats: false
        ) { [weak self] _ in
            self?.checkForUpdate()
            self?.scheduleNextUpdateCheck()
        }
    }

    /// User-initiated check from the footer button: same fetch as the daily
    /// check, but reports its outcome through manualUpdateCheck.
    func checkForUpdateNow() {
        manualCheckGeneration += 1
        manualUpdateCheck = .checking
        checkForUpdate(manual: true)
    }

    /// Publish a manual-check outcome; transient outcomes clear after a few
    /// seconds unless a newer manual check has started since.
    private func finishManualCheck(_ outcome: ManualUpdateCheck) {
        manualUpdateCheck = outcome
        guard outcome != .none else { return }
        let generation = manualCheckGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.manualCheckGeneration == generation else { return }
            self.manualUpdateCheck = .none
        }
    }

    private func checkForUpdate(manual: Bool = false) {
        let task = URLSession.shared.dataTask(with: Self.caskURL) { [weak self] data, _, error in
            guard let self else { return }
            guard error == nil,
                  let data, let content = String(data: data, encoding: .utf8),
                  let update = Self.parseCask(content) else {
                // Automatic checks fail silently; a clicked check owes the
                // user an answer.
                if manual {
                    DispatchQueue.main.async { self.finishManualCheck(.failed) }
                }
                return
            }
            let current = AppVersion.current.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            DispatchQueue.main.async {
                // Never mutate updateAvailable under an in-flight install —
                // installUpdate captured its own copy, but the UI's progress
                // row keys off this property.
                switch self.updateState {
                case .downloading, .installing:
                    if manual { self.finishManualCheck(.none) }
                    return
                case .idle, .failed: break
                }
                if Self.isNewerVersion(update.version, than: current) {
                    if self.updateAvailable != update {
                        self.updateAvailable = update
                        // A .failed from an older offer doesn't apply to this
                        // one; keep it only while the same update is retried.
                        self.updateState = .idle
                        NSLog("Ampere: Update available: %@ → %@", current, update.version)
                    }
                    // The update row appearing is the answer; no text needed.
                    if manual { self.finishManualCheck(.none) }
                } else {
                    self.updateAvailable = nil
                    self.updateState = .idle
                    if manual { self.finishManualCheck(.upToDate) }
                }
            }
        }
        task.resume()
    }

    /// Compare two dotted version strings (e.g. "0.0.18" > "0.0.17").
    /// Returns false unless BOTH parse fully as dotted integers: dev builds
    /// report a git hash ("6d18eea") or describe string ("v0.0.18-3-g6d18eea"),
    /// and a lenient partial parse would flag every release as an update.
    /// Internal (not private) so the comparison rules can be pinned by tests.
    static func isNewerVersion(_ remote: String, than current: String) -> Bool {
        guard let r = parseDottedVersion(remote),
              let c = parseDottedVersion(current) else { return false }
        for i in 0 ..< max(r.count, c.count) {
            let rv = i < r.count ? r[i] : 0
            let cv = i < c.count ? c[i] : 0
            if rv > cv { return true }
            if rv < cv { return false }
        }
        return false
    }

    /// "1.2.3" → [1, 2, 3]; nil if any component is non-numeric or the
    /// string is empty.
    private static func parseDottedVersion(_ s: String) -> [Int]? {
        let parts = s.split(separator: ".")
        guard !parts.isEmpty else { return nil }
        let nums = parts.compactMap { Int($0) }
        return nums.count == parts.count ? nums : nil
    }

    // MARK: - Sudo Setup

    /// Check if the passwordless sudoers rule and helper binary are installed
    var isSudoRuleInstalled: Bool { io.helperInstalled() }

    /// Check if the installed helper differs from the bundled one. Returns
    /// `false` when either side can't be read — we can't reinstall what we
    /// don't have, so callers should fall through and use whatever helper
    /// is currently installed. The bundled-side miss is logged once per
    /// check because in a release build it indicates a corrupted bundle.
    private static func helperNeedsUpdate() -> Bool {
        guard let installed = try? Data(contentsOf: URL(fileURLWithPath: Self.helperPath)) else {
            return false
        }
        guard let bundled = try? Data(contentsOf: URL(fileURLWithPath: smcWriterPath)) else {
            NSLog("Ampere: bundled SMCWriter unreadable at %@ — cannot check staleness", smcWriterPath)
            return false
        }
        return installed != bundled
    }

    /// Restore charging and sleep before removing the privileged files.
    func removeSudoRule() {
        guard !autoManageInFlight else {
            lastError = "Charge control is busy — try revoking access again in a moment"
            return
        }
        autoManageInFlight = true
        smcQueue.async { [weak self] in
            guard let self else { return }
            // Restoration and removal share the one existing admin prompt.
            // This also works when the sudoers rule belongs to another user.
            let ok = HelperSecurity.isProtected(path: Self.helperPath)
                && self.io.runAsAdmin(HelperSetup.removalScript())
            DispatchQueue.main.async {
                self.autoManageInFlight = false
                if ok && !self.isSudoRuleInstalled {
                    self.autoManageEnabled = false
                    self.autoDischargeEnabled = false
                    self.chargeToUpperBound = false
                    self.chargeToFull = false
                    self.requestedChargingPaused = nil
                    self.chargingPaused = false
                    self.activeDischarging = false
                    self.sleepHoldActive = false
                    self.sleepHoldIntent = false
                    self.lastError = nil
                    self.healthWarning = nil
                } else {
                    self.lastError = "Admin access was not revoked. Cleanup must succeed before the helper can be removed."
                }
            }
        }
    }

    /// Run shell commands as root via osascript "with administrator privileges".
    /// Shows the native macOS password dialog (one-time setup only).
    private static func runAsAdmin(_ commands: String) -> Bool {
        let escaped = commands.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        // Discard child stdout/stderr — we don't read them, and unread
        // Pipes can block the child if its output ever fills the buffer.
        // Also pin stdin to /dev/null so osascript (which doesn't read it
        // for our -e usage) can't accidentally block waiting on inherited
        // input from a TTY.
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Path to the SMCWriter binary (lightweight, no AppKit/SwiftUI)
    private static var smcWriterPath: String {
        let mainBinary = Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments[0]
        // SMCWriter is a sibling executable in the same build directory
        return (mainBinary as NSString).deletingLastPathComponent + "/SMCWriter"
    }

    /// Install into the protected directory and migrate the old helper in
    /// the same administrator prompt used for every normal helper update.
    private static func installSudo() -> Bool {
        guard HelperSecurity.canInstall(in: AppConstants.helperDirectory),
              NSUserName().range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.-]*$"#,
                                 options: .regularExpression) != nil,
              let helperData = try? Data(contentsOf: URL(fileURLWithPath: smcWriterPath)) else {
            NSLog("Ampere: Helper setup refused — destination is not protected or bundled helper is unavailable")
            return false
        }
        let digest = SHA256.hash(data: helperData).map { String(format: "%02x", $0) }.joined()
        let script = HelperSetup.installScript(writer: smcWriterPath, digest: digest,
            username: NSUserName(), appPID: ProcessInfo.processInfo.processIdentifier)
        return runAsAdmin(script) && checkHelperAuthorization()
    }

    /// Ensure sudo helper is installed (prompts for password on background queue).
    /// Calls completion on the main queue with success/failure.
    func ensureSudoInstalled(completion: @escaping (Bool) -> Void) {
        if isSudoRuleInstalled && !io.helperStale() && io.helperAuthorized() {
            completion(true)
            return
        }
        smcQueue.async { [weak self] in
            let ok = self?.io.installHelper() ?? false
            // The setup transaction already installed a fresh watchdog.
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                if ok {
                    self?.recheckHealth()
                }
                completion(ok)
            }
        }
    }

    // MARK: - SMC Write

    /// High-level SMC operations exposed to the auto-manage state machine and
    /// the UI. Each case maps to one or more `runSMCWriteViaSudo` calls.
    enum SMCWriteOp {
        case allow        // CHTE=0x00 — charging enabled
        case inhibit      // CHTE=0x01 — charging blocked
        case discharge    // CHIE=0x08 + sleep prevention + watchdog
        case nodischarge  // clear CHIE + restore sleep + re-spawn watchdog
    }

    /// Start the discharge daemon. It writes CHIE, sets sleep prevention,
    /// then spawns a watchdog daemon via posix_spawn that monitors the app
    /// PID and cleans up if the app dies.
    private func startDischarge() -> Bool {
        // Clean up any stale watchdog/CHIE/sleep state first
        guard runSMCWriteViaSudo("nodischarge") else { return false }

        let ok = runSMCWriteViaSudo("discharge:\(ProcessInfo.processInfo.processIdentifier)")
        if ok {
            NSLog("Ampere: discharge daemon started")
        } else if !runSMCWriteViaSudo("spawn-watchdog:\(ProcessInfo.processInfo.processIdentifier)") {
            // The successful nodischarge retired the previous watchdog.
            // Restore crash recovery even if discharge could not start.
            NSLog("Ampere: Watchdog respawn after failed discharge start also failed")
        }
        return ok
    }

    /// Stop discharge: clear CHIE, restore sleep, retire the watchdog, then re-spawn
    /// a watchdog so CHTE is still protected if the app is killed. Returns
    /// the success of the primary `nodischarge` write; logs but does not fail
    /// the overall call if only the watchdog respawn failed.
    private func stopDischarge() -> Bool {
        // Failure preserves the current watchdog; do not create a duplicate.
        guard runSMCWriteViaSudo("nodischarge") else { return false }
        let watchdogOk = runSMCWriteViaSudo("spawn-watchdog:\(ProcessInfo.processInfo.processIdentifier)")
        if !watchdogOk {
            NSLog("Ampere: nodischarge succeeded but watchdog respawn failed — CHTE protection on crash may be lost")
        }
        NSLog("Ampere: discharge stopped")
        return true
    }

    /// Run a high-level SMC operation via the sudoers helper (no password
    /// prompt). Requires the sudoers helper to be installed.
    @discardableResult
    private func runSMCWrite(_ op: SMCWriteOp) -> Bool {
        guard isSudoRuleInstalled else {
            NSLog("Ampere: sudo helper not installed, cannot write SMC")
            return false
        }
        switch op {
        case .allow:       return runSMCWriteViaSudo("allow")
        case .inhibit:     return runSMCWriteViaSudo("inhibit")
        case .discharge:   return startDischarge()
        case .nodischarge: return stopDischarge()
        }
    }

    private func runSMCWriteViaSudo(_ arg: String) -> Bool { io.writeHelper(arg) }

    private static func checkHelperAuthorization() -> Bool {
        // -k ignores cached sudo credentials for this command. Success
        // therefore proves passwordless access for the current account.
        executeHelper("check", ignoreCachedCredentials: true)
    }

    private static func executeHelper(_ arg: String) -> Bool {
        executeHelper(arg, ignoreCachedCredentials: false)
    }

    private static func executeHelper(_ arg: String, ignoreCachedCredentials: Bool) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        task.arguments = ["-n"] + (ignoreCachedCredentials ? ["-k"] : []) + [Self.helperPath, arg]
        let errPipe = Pipe()
        task.standardInput = FileHandle.nullDevice
        task.standardError = errPipe
        // stdout is brief ("OK: ...") and never read — discard to /dev/null
        // rather than create an unread Pipe that could block on a large write.
        task.standardOutput = FileHandle.nullDevice
        do {
            try task.run()
            let errorData = errPipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            if task.terminationStatus == 0 { return true }
            let errMsg = String(data: errorData, encoding: .utf8) ?? ""
            // Include the helper arg and exit status — the previous log
            // ("sudo failed: %@") swallowed both when stderr was empty.
            NSLog("Ampere: sudo failed (arg=%@ status=%d): %@", arg, task.terminationStatus, errMsg)
            return false
        } catch {
            NSLog("Ampere: failed to run sudo (arg=%@): %@", arg, error.localizedDescription)
            return false
        }
    }

    // MARK: - SMC Read (no root required)

    /// Read a single SMC key and return its raw bytes, or nil on failure.
    private static func smcReadKey(_ key: String) -> [UInt8]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
            IOServiceMatching("AppleSMCKeysEndpoint"))
        let svc = service != MACH_PORT_NULL ? service :
            IOServiceGetMatchingService(kIOMainPortDefault,
                IOServiceMatching("AppleSMC"))
        guard svc != MACH_PORT_NULL else { return nil }
        defer { IOObjectRelease(svc) }

        var conn: io_connect_t = 0
        guard IOServiceOpen(svc, mach_task_self_, 0, &conn) == kIOReturnSuccess else { return nil }
        defer { IOServiceClose(conn) }

        let smcKey = smcFourCharCode(key)
        let inputSize = MemoryLayout<SMCKeyData>.size
        var outputSize = MemoryLayout<SMCKeyData>.size

        // Step 1: get key info
        var input = SMCKeyData()
        var output = SMCKeyData()
        input.key = smcKey
        input.data8 = SMCCmd.readKeyInfo
        guard IOConnectCallStructMethod(conn, SMCCmd.userClientSelector, &input, inputSize, &output, &outputSize) == kIOReturnSuccess else { return nil }

        let dataSize = output.keyInfo.dataSize
        guard dataSize > 0 && dataSize <= SMCKeyData.bytesCapacity else { return nil }

        // Step 2: read value
        input = SMCKeyData()
        input.key = smcKey
        input.keyInfo.dataSize = dataSize
        input.data8 = SMCCmd.readKey
        output = SMCKeyData()
        outputSize = MemoryLayout<SMCKeyData>.size
        guard IOConnectCallStructMethod(conn, SMCCmd.userClientSelector, &input, inputSize, &output, &outputSize) == kIOReturnSuccess else { return nil }

        var raw = output.bytes
        return withUnsafeBytes(of: &raw) { Array($0.prefix(Int(dataSize))) }
    }

    // MARK: - Keep awake (idle-sleep assertion)

    /// Duration presets in minutes; 0 = Forever. Single source of truth
    /// for the picker's items, the init-time repair of a persisted value,
    /// and the labels — a preset outside this list would render a menu
    /// with no selected item.
    static let keepAwakeDurations = [0, 15, 30, 60, 120, 240, 480]

    /// Menu label for a duration preset: "Forever", "15 min", "1 hour".
    static func keepAwakeDurationLabel(_ minutes: Int) -> String {
        if minutes <= 0 { return "Forever" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        return hours == 1 ? "1 hour" : "\(hours) hours"
    }

    /// Pure gate for whether the keep-awake assertion should be held.
    /// AC-only by design: an assertion on battery would drain a forgotten
    /// Mac, and it cannot absorb lid-close sleep anyway, so on battery the
    /// toggle keeps its intent and the Mac sleeps normally. A deadline at
    /// or before `now` means the session ended.
    static func keepAwakeAssertionDesired(
        enabled: Bool, adapterConnected: Bool, deadline: Date?, now: Date
    ) -> Bool {
        guard enabled, adapterConnected else { return false }
        if let deadline, deadline <= now { return false }
        return true
    }

    /// Deadline for a session of `minutes` starting at `from`; 0 = Forever
    /// (no deadline).
    static func keepAwakeDeadline(minutes: Int, from: Date) -> Date? {
        minutes > 0 ? from.addingTimeInterval(TimeInterval(minutes) * 60) : nil
    }

    /// UI entry point for the toggle. Starting a session stamps the
    /// deadline from the configured duration; stopping clears it.
    func setKeepAwake(_ on: Bool) {
        guard on != keepAwakeEnabled else { return }
        keepAwakeEnabled = on
        setKeepAwakeDeadline(on ? Self.keepAwakeDeadline(minutes: keepAwakeMinutes, from: Date()) : nil)
        reconcileKeepAwake(adapterConnected: state?.adapterConnected ?? false)
    }

    /// UI entry point for the duration picker. Changing the duration
    /// during an active session restarts the countdown from now, so the
    /// picker's value and the session in force can never disagree.
    func setKeepAwakeDuration(minutes: Int) {
        guard minutes != keepAwakeMinutes else { return }
        keepAwakeMinutes = minutes
        if keepAwakeEnabled {
            setKeepAwakeDeadline(Self.keepAwakeDeadline(minutes: minutes, from: Date()))
            reconcileKeepAwake(adapterConnected: state?.adapterConnected ?? false)
        }
    }

    /// Single writer for the deadline: keeps the published value, the
    /// persisted value, and the expiry timer in lockstep.
    private func setKeepAwakeDeadline(_ date: Date?) {
        keepAwakeDeadline = date
        if let date {
            defaults.set(date.timeIntervalSince1970, forKey: "keepAwakeDeadline")
        } else {
            defaults.removeObject(forKey: "keepAwakeDeadline")
        }
        scheduleKeepAwakeExpiry()
    }

    /// Arm the one-shot expiry timer for the current deadline (clearing
    /// any previous one). The handler only refreshes — the flip-off lives
    /// in reconcileKeepAwake, so a timer that fires late (system was
    /// asleep at the deadline on battery) and the poll path both converge
    /// on the same transition.
    private func scheduleKeepAwakeExpiry() {
        keepAwakeExpiryTimer?.invalidate()
        keepAwakeExpiryTimer = nil
        guard keepAwakeEnabled, let deadline = keepAwakeDeadline else { return }
        let interval = max(deadline.timeIntervalSinceNow, 0) + 0.5
        keepAwakeExpiryTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.keepAwakeExpiryTimer = nil
            self.refresh()
        }
    }

    /// Reconcile the powerd assertion with the desired state. Runs on
    /// every refresh tick (adapter transitions arrive there via the IOPS
    /// notification source), from the UI entry points, and from the expiry
    /// timer's refresh. A failed create simply retries next tick, same
    /// contract as the SMC reconciliation.
    private func reconcileKeepAwake(adapterConnected: Bool) {
        let now = Date()
        // Session over: flip the toggle off (didSet persists) so the UI
        // reads "off", never "on but expired".
        if keepAwakeEnabled, let deadline = keepAwakeDeadline, deadline <= now {
            keepAwakeEnabled = false
            setKeepAwakeDeadline(nil)
            NSLog("Ampere: Keep-awake session expired")
        }
        // Launch case: a deadline restored by init has no timer yet
        // (timers can't be scheduled mid-init).
        if keepAwakeExpiryTimer == nil, keepAwakeEnabled, keepAwakeDeadline != nil {
            scheduleKeepAwakeExpiry()
        }
        let desired = Self.keepAwakeAssertionDesired(
            enabled: keepAwakeEnabled, adapterConnected: adapterConnected,
            deadline: keepAwakeDeadline, now: now)
        guard desired != keepAwakeAssertionHeld else { return }
        if desired {
            var id: IOPMAssertionID = 0
            let rc = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Ampere: Keep Mac Awake" as CFString, &id)
            if rc == kIOReturnSuccess {
                keepAwakeAssertionID = id
                keepAwakeAssertionHeld = true
                NSLog("Ampere: Keep-awake assertion acquired")
            } else {
                NSLog("Ampere: Keep-awake assertion create failed (0x%08x)", UInt32(bitPattern: rc))
            }
        } else {
            // Release cannot meaningfully fail (the ID is one we created);
            // clear unconditionally so a stale ID can't wedge the state.
            IOPMAssertionRelease(keepAwakeAssertionID)
            keepAwakeAssertionID = 0
            keepAwakeAssertionHeld = false
            NSLog("Ampere: Keep-awake assertion released")
        }
    }

    // MARK: - Auto-manage decision (pure, testable)

    /// Pure state carried across refresh() cycles for the auto-manage state machine.
    /// `chargeToFull` defaults to false so existing construction sites (and
    /// tests) that predate the field remain valid.
    struct AutoManageState: Equatable {
        var chargingPaused: Bool
        var chargeToUpperBound: Bool
        var chargeToFull: Bool = false
        var lastAdapterConnected: Bool?
        /// Sleep-hold intent: keep the Mac awake (pmset override via the
        /// helper) while a below-lower charge runs, because the app cannot
        /// stop a charge at the upper bound while the system sleeps.
        /// Defaults false so existing construction sites remain valid.
        var sleepHold: Bool = false
    }

    /// Inputs observed by a single refresh() cycle.
    struct AutoManageInputs: Equatable {
        let autoManageEnabled: Bool
        let adapterConnected: Bool
        let percentage: Int
        let lowerBound: Int
        let upperBound: Int
        /// BMS charge-termination flag; substitutes for "percentage >= 100"
        /// on worn batteries that top out below a displayed 100%.
        let fullyCharged: Bool
        /// Lid state at poll time. Consulted only by the sleep-hold release
        /// rule: a closed lid during a hold means a sleep attempt was
        /// absorbed, so the hold persists to the upper bound. Desktops (no
        /// lid) and failed reads report open. Defaults false so existing
        /// construction sites remain valid.
        var lidClosed: Bool = false
    }

    /// SMC command the refresh() cycle should issue.
    enum AutoManageAction: Equatable {
        case none
        case inhibit
        case allow
    }

    struct AutoManageDecision: Equatable {
        let action: AutoManageAction
        let newState: AutoManageState
    }

    /// "Reached the bound" for charge decisions. For a 100% bound the BMS's
    /// charge-termination flag also counts: worn batteries can terminate
    /// below a displayed 100%, and comparing the percentage alone would
    /// keep CHTE=allow forever, trickle-charging at the top. Bounds below
    /// 100 are unaffected — the BMS never terminates there.
    /// One definition shared by the state machine and the launch-time
    /// crash repairs in init; internal (not private) so tests can pin it.
    static func reachedBound(_ bound: Int, percentage: Int, fullyCharged: Bool) -> Bool {
        percentage >= bound || (bound == 100 && fullyCharged)
    }

    /// Core auto-manage state machine. Pure function: given the prior state and
    /// the currently observed inputs, return the SMC action to issue and the
    /// state to store after the action completes. Encodes:
    ///   Rule 1 — below lower bound on AC → allow + set chargeToUpperBound
    ///   Rule 2 — AC disconnect at or above lower bound → clear chargeToUpperBound
    ///   Rule 3 — between bounds without chargeToUpperBound → inhibit
    ///   Charge to Full — while chargeToFull is set the effective upper bound
    ///   is 100; reaching it (by percentage or the BMS fully-charged flag) or
    ///   disconnecting from AC clears the flag and normal management resumes
    ///   with the configured bounds.
    static func evaluateAutoManageStep(
        state: AutoManageState,
        inputs: AutoManageInputs
    ) -> AutoManageDecision {
        var next = state

        // Rule 2: fire only on the connected→disconnected transition, and only
        // when at or above the lower bound. An explicit toggle made while
        // already on battery must not be reverted.
        if state.lastAdapterConnected == true, !inputs.adapterConnected,
           state.chargeToUpperBound, inputs.percentage >= inputs.lowerBound {
            next.chargeToUpperBound = false
        }
        // Charge-to-full is a one-shot tied to the current AC session: unlike
        // rule 2 it clears on ANY battery tick, not just the unplug edge, so
        // a stale flag (persisted by a crash inside the unplug window) can
        // never resurrect a "100%" target hours later on reconnect. There is
        // also no at-or-above-lower carve-out; below the lower bound the
        // fresh unplug instead downgrades it to charge-to-upper — exactly
        // what rule 1 would decide there. Leaving no intent at all would let
        // the still-allowed SMC charge to the lower bound on reconnect and
        // then park there (rule 3), a level the user never picked as a stop
        // point. The downgrade needs the unplug-time percentage, so it only
        // applies on the transition.
        if state.chargeToFull, !inputs.adapterConnected {
            next.chargeToFull = false
            if state.lastAdapterConnected == true, inputs.percentage < inputs.lowerBound {
                next.chargeToUpperBound = true
            }
        }
        next.lastAdapterConnected = inputs.adapterConnected

        // Auto-manage SMC decisions only apply on AC with auto-manage enabled.
        guard inputs.autoManageEnabled, inputs.adapterConnected else {
            // The sleep hold has no basis off AC or outside auto mode —
            // never keep a Mac awake on battery power.
            next.sleepHold = false
            return AutoManageDecision(action: .none, newState: next)
        }

        let reached: (Int) -> Bool = {
            reachedBound($0, percentage: inputs.percentage, fullyCharged: inputs.fullyCharged)
        }

        // chargeToUpperBound is only meaningful below the upper bound (init
        // repairs persisted state the same way). A stale true here — e.g. the
        // toggle flipped from a UI rendered against the previous poll's
        // reading, just as the battery crossed the bound — would otherwise
        // make the paused branch below issue a spurious allow at/above the
        // bound, immediately reverted by an inhibit on the next cycle.
        if next.chargeToUpperBound, reached(inputs.upperBound) {
            next.chargeToUpperBound = false
        }
        // Same staleness rule for charge-to-full against its own target.
        if next.chargeToFull, reached(100) {
            next.chargeToFull = false
        }

        // Rule 1, unpaused entry: below the lower bound on AC always means
        // "charge to the upper bound". The paused entry arms in the allow
        // branch below, but the below-lower state can also be entered
        // unpaused with nothing armed — auto-manage enabled while on
        // battery, or an unplug at/above lower (rule 2 clears the intent)
        // followed by a drain below it. Without this arm, the between-bounds
        // branch would inhibit at the lower-bound crossing and park the
        // charge there. Pure arm, no SMC action: unpaused means CHTE is
        // already in the allow state.
        if !next.chargingPaused, !next.chargeToUpperBound, !next.chargeToFull,
           inputs.percentage < inputs.lowerBound, !reached(inputs.upperBound) {
            next.chargeToUpperBound = true
        }

        // While charge-to-full is active the configured upper bound stops
        // being a charge terminator; 100% is the only ceiling. Cleared above
        // when full, so an active flag always means "keep charging".
        let effectiveUpper = next.chargeToFull ? 100 : inputs.upperBound

        let action: AutoManageAction
        if !next.chargingPaused && reached(effectiveUpper) {
            // At or above the effective upper bound → inhibit and reset
            // charge-to-upper.
            next.chargingPaused = true
            next.chargeToUpperBound = false
            action = .inhibit
        } else if !next.chargingPaused && !next.chargeToUpperBound && !next.chargeToFull
                    && inputs.percentage >= inputs.lowerBound
                    && inputs.percentage < effectiveUpper {
            // Between bounds without charge-to-upper/-full → inhibit (rule 3).
            next.chargingPaused = true
            action = .inhibit
        } else if next.chargingPaused && !reached(effectiveUpper)
                    && (inputs.percentage < inputs.lowerBound
                        || next.chargeToUpperBound || next.chargeToFull) {
            // Below lower bound (rule 1) or explicit charge-to-upper/-full → allow.
            let belowLower = inputs.percentage < inputs.lowerBound
            next.chargingPaused = false
            if belowLower {
                next.chargeToUpperBound = true
            }
            action = .allow
        } else {
            action = .none
        }

        // Sleep hold — a below-lower charge must keep the Mac awake, because
        // sleep cannot be refused at announcement time: the hold has to be
        // armed while the condition exists, and a lid close during it is
        // then absorbed before it can suspend the app (see README). Once the
        // battery climbs into the band, the hold persists to the upper bound
        // only while the lid stays closed — a closed lid is the evidence
        // that a sleep was absorbed. Lid open means nobody tried to sleep;
        // release, and the pre-sleep pause covers any later attempt.
        // Charge-to-full is exempt: its ceiling is 100%, so sleep-charging
        // cannot overshoot, and an overnight full charge should sleep.
        if next.chargeToUpperBound, !next.chargeToFull,
           inputs.percentage < inputs.lowerBound, !reached(effectiveUpper) {
            next.sleepHold = true
        } else if next.sleepHold,
                  !next.chargeToUpperBound || next.chargeToFull
                    || (inputs.percentage >= inputs.lowerBound && !inputs.lidClosed) {
            next.sleepHold = false
        }

        return AutoManageDecision(action: action, newState: next)
    }

    // MARK: - Health Check

    /// Health check for manual mode.
    /// Returns true if SMC state is consistent with the pause button state.
    static func healthCheckManualMode(pauseButtonPaused: Bool, chie: Int, chte: Int) -> Bool {
        guard chie == SMC.chieNormalInt else { return false }
        if pauseButtonPaused {
            return chte == SMC.chteInhibitInt
        } else {
            return chte == SMC.chteAllowInt
        }
    }

    /// Health check for auto mode.
    /// Returns true if SMC state is consistent with auto-manage settings.
    static func healthCheckAutoMode(
        chargeLevel: Int, lowerBound: Int, upperBound: Int,
        dischargeEnabled: Bool, activeDischarging: Bool,
        chargeToUpperBound: Bool,
        chie: Int, chte: Int, fullyCharged: Bool = false
    ) -> Bool {
        if !(dischargeEnabled && activeDischarging),
           reachedBound(upperBound, percentage: chargeLevel, fullyCharged: fullyCharged) {
            return chte == SMC.chteInhibitInt && chie == SMC.chieNormalInt
        }
        if dischargeEnabled {
            // The discharge daemon's CHIE=0x08 write persists as long as it's
            // running; activeDischarging tracks the daemon's lifetime, not
            // the level that originally triggered it. So gate on
            // activeDischarging alone — a transient where pct == upperBound
            // but the daemon hasn't been stopped yet must still expect
            // CHIE=discharge.
            if activeDischarging {
                // Apple's SMC firmware on some Macs auto-clears CHTE while
                // CHIE=0x08 is set, so CHTE can read as either 0 or 1
                // regardless of what we last wrote. CHIE=discharge is the
                // authoritative signal that the daemon is doing its job;
                // CHTE is informational only during active discharge.
                return chie == SMC.chieDischargeInt
            } else if chargeLevel >= lowerBound {
                // Between bounds: check chargeToUpperBound to determine expected CHTE
                if chargeToUpperBound {
                    return chte == SMC.chteAllowInt && chie == SMC.chieNormalInt
                } else {
                    return chte == SMC.chteInhibitInt && chie == SMC.chieNormalInt
                }
            } else {
                return chte == SMC.chteAllowInt && chie == SMC.chieNormalInt
            }
        } else {
            guard chie == SMC.chieNormalInt else { return false }
            if chargeLevel >= lowerBound {
                if chargeToUpperBound {
                    return chte == SMC.chteAllowInt
                } else {
                    return chte == SMC.chteInhibitInt
                }
            } else {
                return chte == SMC.chteAllowInt
            }
        }
    }

    /// Returns expected CHTE and CHIE display strings for the current state.
    static func expectedSMCValues(
        autoManageEnabled: Bool, pauseButtonPaused: Bool,
        chargeLevel: Int, lowerBound: Int, upperBound: Int,
        dischargeEnabled: Bool, activeDischarging: Bool,
        chargeToUpperBound: Bool, fullyCharged: Bool = false
    ) -> (chte: String, chie: String) {
        if autoManageEnabled {
            if !(dischargeEnabled && activeDischarging),
               reachedBound(upperBound, percentage: chargeLevel, fullyCharged: fullyCharged) {
                return (SMC.chteInhibitHex, SMC.chieNormalHex)
            }
            if dischargeEnabled {
                // Gate on activeDischarging alone — see comment in
                // healthCheckAutoMode for the boundary-window rationale.
                if activeDischarging {
                    return (SMC.chteInhibitHex, SMC.chieDischargeHex)
                } else if chargeLevel >= lowerBound {
                    if chargeToUpperBound {
                        return (SMC.chteAllowHex, SMC.chieNormalHex)
                    } else {
                        return (SMC.chteInhibitHex, SMC.chieNormalHex)
                    }
                } else {
                    return (SMC.chteAllowHex, SMC.chieNormalHex)
                }
            } else {
                if chargeLevel >= lowerBound {
                    if chargeToUpperBound {
                        return (SMC.chteAllowHex, SMC.chieNormalHex)
                    } else {
                        return (SMC.chteInhibitHex, SMC.chieNormalHex)
                    }
                } else {
                    return (SMC.chteAllowHex, SMC.chieNormalHex)
                }
            }
        } else {
            if pauseButtonPaused {
                return (SMC.chteInhibitHex, SMC.chieNormalHex)
            } else {
                return (SMC.chteAllowHex, SMC.chieNormalHex)
            }
        }
    }

    /// Decide whether a failed health check should self-repair CHTE, and
    /// with which write. Firmware or a PD renegotiation can reset CHTE at
    /// any time (observed across sleep, and a failed wake re-assert is
    /// never retried), and the state machine is edge-triggered: once its
    /// in-memory state matches its last decision it returns `.none` forever,
    /// so a drifted CHTE would otherwise persist until the next sleep/wake
    /// cycle while the battery charges past the bound (or refuses to charge
    /// to it). The health check already computes the expected value every
    /// tick — level-triggered enforcement is one write away.
    ///
    /// CHTE only, and only while CHIE is in its expected normal state:
    /// repairing a CHIE mismatch would mean starting or stopping a
    /// discharge, which the state machine owns (with sleep overrides and a
    /// watchdog attached) — and during an active discharge CHTE is firmware
    /// noise anyway (see healthCheckAutoMode). Internal so tests can pin
    /// the eligibility rules.
    static func chteRepairOp(
        chteMatch: Bool, chieMatch: Bool, chie: Int,
        expectedChte: String, activeDischarging: Bool
    ) -> SMCWriteOp? {
        guard !chteMatch, chieMatch, chie == SMC.chieNormalInt,
              !activeDischarging else { return nil }
        return expectedChte == SMC.chteInhibitHex ? .inhibit : .allow
    }

    // MARK: - Refresh

    /// Publish the latest battery reading, gated to avoid noisy SwiftUI
    /// layout passes when the popover is hidden and only menu-bar-relevant
    /// fields haven't changed.
    private func publishStateIfNeeded(_ battery: BatteryState?) {
        if state != battery {
            let menuBarChanged = state == nil
                || state?.percentage != battery?.percentage
                || state?.isCharging != battery?.isCharging
                // Menu bar animation direction is now driven by amperage's
                // sign too (via `effectivelyCharging`), so a sign flip with
                // unchanged `isCharging` (the discharge-startup transient)
                // must also re-render or the icon would lag the actual
                // current direction.
                || Self.amperageDirection(state?.amperage)
                    != Self.amperageDirection(battery?.amperage)
            if isPopoverVisible || menuBarChanged {
                state = battery
            }
        }
    }

    /// `-1` discharging, `+1` charging, `0` idle/unknown. Mirrors the
    /// branching in `BatteryModeRouter` and `effectivelyCharging` so
    /// `publishStateIfNeeded` re-renders the menu bar on the same events
    /// those consumers actually depend on.
    static func amperageDirection(_ amperage: Double?) -> Int {
        guard let amperage = amperage else { return 0 }
        if amperage > 0 { return 1 }
        if amperage < 0 { return -1 }
        return 0
    }

    func refresh() {
        guard !preparingForSleep, !terminating else { return }
        refreshCount += 1
        var battery = self.io.battery()
        // Publish unconditionally on every refresh — early returns below
        // dispatch SMC actions and exit, and on failure the dispatch's
        // callback intentionally does NOT recurse into refresh(). Without
        // this defer, the menu bar would be stuck at "0%" and the popover
        // at "no battery" whenever the first refresh trips an early return.
        defer { publishStateIfNeeded(battery) }

        // Keep-awake reconcile runs ahead of the early-return branches
        // below: the assertion must track adapter state even on ticks that
        // dispatch SMC work and exit. A failed battery read releases it
        // (sleep allowed) — the safe direction for unknown state, matching
        // the rest of this file.
        reconcileKeepAwake(adapterConnected: battery?.adapterConnected ?? false)

        // Stop discharge if the adapter disconnected mid-discharge. Gated
        // separately from the chargingPaused synthesize branch because the
        // window between "discharge dispatch succeeded → activeDischarging=true"
        // and "state machine ran → chargingPaused=true" can land here with
        // adapter=false, where the chargingPaused-gated cleanup would miss it.
        if activeDischarging, let b = battery, !b.adapterConnected, !autoManageInFlight {
            autoManageInFlight = true
            // Some Macs' firmware auto-clears CHTE while CHIE=0x08 is active
            // (see healthCheckAutoMode), so the pre-discharge inhibit may be
            // gone by the time the discharge stops. Re-assert CHTE explicitly
            // after every stop — the state machine won't: it trusts
            // chargingPaused, which still says inhibited. Without this,
            // affected Macs resume charging past the upper bound and the
            // discharge re-triggers, oscillating around the bound forever.
            // In manual mode (auto-manage just turned off) the desired state
            // is allow: the UI's disable handler resumes charging.
            let reassert: SMCWriteOp = (autoManageEnabled && chargingPaused) ? .inhibit : .allow
            smcQueue.async { [weak self] in
                guard let self = self else { return }
                let ok = self.runSMCWrite(.nodischarge)
                if ok, !self.runSMCWrite(reassert) {
                    NSLog("Ampere: CHTE re-assert after discharge stop failed")
                }
                DispatchQueue.main.async {
                    self.autoManageInFlight = false
                    if ok {
                        self.activeDischarging = false
                        NSLog("Ampere: Discharge stopped — adapter disconnected")
                        self.refresh()
                    }
                }
            }
            return
        }

        // Stop discharge if the toggle was turned off or auto-manage was disabled
        if activeDischarging && (!autoDischargeEnabled || !autoManageEnabled) && !autoManageInFlight {
            autoManageInFlight = true
            // Firmware may have cleared CHTE during discharge — re-assert.
            // See the adapter-disconnect stop above for the full rationale.
            let reassert: SMCWriteOp = (autoManageEnabled && chargingPaused) ? .inhibit : .allow
            smcQueue.async { [weak self] in
                guard let self = self else { return }
                let ok = self.runSMCWrite(.nodischarge)
                if ok, !self.runSMCWrite(reassert) {
                    NSLog("Ampere: CHTE re-assert after discharge stop failed")
                }
                DispatchQueue.main.async {
                    self.autoManageInFlight = false
                    if ok {
                        self.activeDischarging = false
                        NSLog("Ampere: Auto-discharge toggled off")
                        self.refresh()
                    }
                    // On failure: don't re-refresh immediately. The condition is
                    // still true, so refresh() would loop. Wait for the next
                    // timer tick instead.
                }
            }
            return
        }

        // Auto-discharge: start when above upper bound, stop when reached
        if autoManageEnabled, autoDischargeEnabled, !autoManageInFlight, let b = battery, b.adapterConnected {
            if (!activeDischarging || wakeReassertPending) && b.percentage > chargeUpperBound {
                autoManageInFlight = true
                wakeReassertPending = false
                // Capture pct/upper at dispatch time so the log can't lie if
                // the user changes the upper bound while the SMC write is in
                // flight — matches the state-machine dispatch's pattern.
                let pct = b.percentage
                let upper = chargeUpperBound
                smcQueue.async { [weak self] in
                    guard let self = self else { return }
                    let ok = self.runSMCWrite(.discharge)
                    DispatchQueue.main.async {
                        self.autoManageInFlight = false
                        if ok {
                            self.activeDischarging = true
                            NSLog("Ampere: Auto-discharge started at %d%%, target %d%%", pct, upper)
                            self.refresh()
                        }
                    }
                }
                return
            } else if activeDischarging && b.percentage <= chargeUpperBound {
                autoManageInFlight = true
                let upper = chargeUpperBound
                // Firmware may have cleared CHTE during discharge — re-assert.
                // See the adapter-disconnect stop above for the full rationale.
                let reassert: SMCWriteOp = (autoManageEnabled && chargingPaused) ? .inhibit : .allow
                smcQueue.async { [weak self] in
                    guard let self = self else { return }
                    let ok = self.runSMCWrite(.nodischarge)
                    if ok, !self.runSMCWrite(reassert) {
                        NSLog("Ampere: CHTE re-assert after discharge stop failed")
                    }
                    DispatchQueue.main.async {
                        self.autoManageInFlight = false
                        if ok {
                            self.activeDischarging = false
                            NSLog("Ampere: Auto-discharge reached target %d%%", upper)
                            self.refresh()
                        }
                    }
                }
                return
            }
        }

        if let pause = requestedChargingPaused, !autoManageInFlight, !activeDischarging {
            autoManageInFlight = true
            // This write also satisfies any pending wake re-assertion.
            // Consume it now so a failed request cannot retry in a loop.
            wakeReassertPending = false
            smcQueue.async { [weak self] in
                guard let self else { return }
                let ok = self.runSMCWrite(pause ? .inhibit : .allow)
                DispatchQueue.main.async {
                    self.autoManageInFlight = false
                    let requestChanged = self.requestedChargingPaused != pause
                    if ok {
                        self.chargingPaused = pause
                        if self.requestedChargingPaused == pause { self.requestedChargingPaused = nil }
                        self.lastError = nil
                    } else {
                        self.lastError = "Charge control failed — revoke and re-grant admin access"
                    }
                    if ok || requestChanged || self.wakeReassertPending { self.refresh() }
                }
            }
            return
        }

        // Auto-manage state machine — delegated to the pure decision function
        // so behavior can be exercised by unit tests. This block handles rules
        // 1/2/3: below-lower → charge-to-upper, disconnect-above-lower → clear
        // charge-to-upper, between-bounds → no auto-charge.
        if let b = battery {
            let priorState = AutoManageState(
                chargingPaused: chargingPaused,
                chargeToUpperBound: chargeToUpperBound,
                chargeToFull: chargeToFull,
                lastAdapterConnected: lastAdapterConnected,
                sleepHold: sleepHoldIntent
            )
            let stepInputs = AutoManageInputs(
                autoManageEnabled: autoManageEnabled,
                adapterConnected: b.adapterConnected,
                percentage: b.percentage,
                lowerBound: chargeLowerBound,
                upperBound: chargeUpperBound,
                fullyCharged: b.fullyCharged,
                lidClosed: self.io.lidClosed()
            )
            let decision = BatteryMonitor.evaluateAutoManageStep(
                state: priorState, inputs: stepInputs
            )

            // Pure state updates always apply (adapter tracking, rule-2 clear,
            // charge-to-full session clear / below-lower downgrade).
            lastAdapterConnected = decision.newState.lastAdapterConnected
            if chargeToUpperBound != decision.newState.chargeToUpperBound, decision.action == .none {
                chargeToUpperBound = decision.newState.chargeToUpperBound
                // Pure paths in both directions: rule 2 (AC disconnect above
                // lower) and the at/above-upper staleness repair clear it;
                // the charge-to-full disconnect downgrade and the rule-1 arm
                // (below lower on AC while unpaused) set it.
                NSLog("Ampere: %@ chargeToUpperBound at %d%%",
                      decision.newState.chargeToUpperBound ? "Set" : "Cleared", b.percentage)
            }
            if chargeToFull != decision.newState.chargeToFull, decision.action == .none {
                chargeToFull = decision.newState.chargeToFull
                // Pure-clear only (the machine never sets it): AC disconnect
                // or the at-100% staleness repair while already paused.
                NSLog("Ampere: Cleared chargeToFull at %d%%", b.percentage)
            }
            if sleepHoldIntent != decision.newState.sleepHold, decision.action == .none {
                // Pure intent transitions: the below-lower arm rides an
                // action-free tick (CHTE already allow), and the releases for
                // unplug / auto-off / lid-open-at-band are equally pure. The
                // pmset side is reconciled by the dispatch below against
                // sleepHoldActive.
                sleepHoldIntent = decision.newState.sleepHold
                NSLog("Ampere: Sleep-hold intent %@ at %d%%",
                      decision.newState.sleepHold ? "armed" : "cleared", b.percentage)
            }

            if autoManageEnabled, b.adapterConnected, lastError != nil { lastError = nil }
            // Manual mode: the specific "no adapter" error becomes irrelevant
            // the moment the adapter reconnects, even before the next charge
            // toggle. Clearing only this specific string avoids wiping
            // unrelated errors like "Charge control failed — …".
            if !autoManageEnabled, b.adapterConnected,
               lastError == Self.noAdapterError {
                lastError = nil
            }

            // An engaged hold can be released out from under us: the
            // SleepDisabled flag is a single global bit shared with other
            // keep-awake tools (e.g. Lidless), and their auto-off timer,
            // quit, or crash watchdog clears it without knowing we need it
            // — the lid-closed Mac then sleeps mid-charge and the SMC
            // charges past the upper bound with nobody awake to stop it.
            // Verify the flag while a hold should be engaged; observing it
            // cleared drops sleepHoldActive so the dispatch below re-applies
            // the hold (hold-sleep also corrects the saved marker — the
            // external holder that justified restoring "1" is evidently
            // gone).
            if sleepHoldActive, decision.newState.sleepHold, !activeDischarging,
               !io.sleepDisabled() {
                sleepHoldActive = false
                NSLog("Ampere: Sleep hold cleared externally at %d%% — re-arming", b.percentage)
            }

            // SMC action dispatch, plus pmset reconciliation for the sleep
            // hold (engaged state vs the machine's intent — retried every
            // tick until they match). Hold ops never run while a discharge
            // is active: nodischarge owns the markers then, and a release
            // here would re-enable sleep mid-CHIE (the clamshell blackout).
            // The mismatch resolves right after the discharge stops — its
            // stop path restores sleep and removes the markers, so a later
            // release is a clean no-op.
            let holdOpNeeded = !activeDischarging
                && decision.newState.sleepHold != sleepHoldActive
            if (decision.action != .none || holdOpNeeded || wakeReassertPending), !autoManageInFlight {
                autoManageInFlight = true
                let reassert = wakeReassertPending
                wakeReassertPending = false
                let revision = controlRevision
                let pct = b.percentage
                // Log the target the machine actually decided on — 100 while
                // charge-to-full survives this step, else the configured bound.
                let upper = decision.newState.chargeToFull ? 100 : chargeUpperBound
                let op: SMCWriteOp?
                switch decision.action {
                case .allow:   op = .allow
                case .inhibit: op = .inhibit
                case .none:    op = reassert ? (decision.newState.chargingPaused ? .inhibit : .allow) : nil
                }
                let next = decision.newState
                smcQueue.async { [weak self] in
                    guard let self = self else { return }
                    // CHTE first: at the upper bound the inhibit must land
                    // before the hold release re-enables sleep, or a closed
                    // lid could sleep the Mac while charging is still allowed.
                    let ok = op.map { self.runSMCWrite($0) } ?? true
                    var holdApplied = false
                    if ok, holdOpNeeded {
                        holdApplied = self.runSMCWriteViaSudo(
                            next.sleepHold ? "hold-sleep" : "release-sleep-hold")
                    }
                    DispatchQueue.main.async {
                        self.autoManageInFlight = false
                        let intentChanged = self.controlRevision != revision
                        if holdApplied {
                            self.sleepHoldActive = next.sleepHold
                            NSLog("Ampere: Sleep hold %@ at %d%%",
                                  next.sleepHold ? "engaged" : "released", pct)
                        }
                        if ok {
                            self.chargingPaused = next.chargingPaused
                            // The hardware operation completed even if the
                            // user changed their mind. Preserve newer intent
                            // and let refresh reconcile it against that fact.
                            if !intentChanged {
                                self.chargeToUpperBound = next.chargeToUpperBound
                                self.chargeToFull = next.chargeToFull
                                self.sleepHoldIntent = next.sleepHold
                            }
                            switch decision.action {
                            case .inhibit:
                                NSLog("Ampere: Inhibited charging at %d%%", pct)
                            case .allow:
                                NSLog("Ampere: Charging from %d%% to %d%%", pct, upper)
                            case .none:
                                break
                            }
                        }
                        // Re-refresh only when everything attempted landed.
                        // A failed write (CHTE or pmset) must wait for the
                        // next timer tick — the decision inputs are
                        // unchanged, so an immediate refresh would re-issue
                        // the same op and tight-loop.
                        if (ok && (!holdOpNeeded || holdApplied)) || intentChanged || self.wakeReassertPending {
                            self.refresh()
                        }
                    }
                }
            }
        }

        if chargingPaused, let b = battery {
            if b.adapterConnected {
                // Clear stale time-to-full and ensure state reflects paused charging
                if b.isCharging || !b.timeRemaining.isEmpty {
                    battery = BatteryState(
                        percentage: b.percentage, cycleCount: b.cycleCount,
                        isCharging: false,
                        adapterConnected: true,
                        health: b.health, temperature: b.temperature,
                        timeRemaining: "",
                        designCapacity: b.designCapacity, maxCapacity: b.maxCapacity,
                        currentCapacity: b.currentCapacity, amperage: b.amperage,
                        voltage: b.voltage,
                        adapterWatts: b.adapterWatts,
                        adapterAmperage: b.adapterAmperage,
                        adapterVoltage: b.adapterVoltage,
                        electronicsWatts: b.electronicsWatts,
                        batteryWatts: b.batteryWatts,
                        batteryAgeYears: b.batteryAgeYears, batteryAgeDays: b.batteryAgeDays,
                        fullyCharged: b.fullyCharged
                    )
                }
            } else if !autoManageEnabled, !autoManageInFlight {
                // Manual mode: clear inhibit/discharge so charging works
                // when plugged back in. Only mirror the state mutation into
                // memory after the SMC writes land — same gating as the
                // wake observer and auto-manage paths. Without this, an
                // SMC-write failure would leave the in-memory state lying
                // (UI says "not paused" while CHTE is still inhibit), and
                // refresh's state machine wouldn't reconcile in manual mode.
                // Takes the same in-flight token as every other SMC dispatch
                // site so it can't interleave with the wake handler's
                // re-assert; if one is in flight, the next tick retries.
                chargeToUpperBound = false  // in-memory only; safe to clear unconditionally
                chargeToFull = false
                autoManageInFlight = true
                smcQueue.async { [weak self] in
                    guard let self = self else { return }
                    let okAllow = self.runSMCWrite(.allow)
                    let okNoDischarge = self.runSMCWrite(.nodischarge)
                    DispatchQueue.main.async {
                        self.autoManageInFlight = false
                        if okAllow { self.chargingPaused = false }
                        if okNoDischarge { self.activeDischarging = false }
                        if (okAllow && okNoDischarge) || self.wakeReassertPending { self.refresh() }
                    }
                }
            }
        }

        // State publishing happens in the defer at the top of this function.

        // Health check: verify SMC state matches expected state.
        if refreshCount > Self.healthCheckSettleRefreshes,
           !autoManageInFlight, isSudoRuleInstalled,
           let b = battery, b.adapterConnected {
            performHealthCheck(battery: b)
        }
    }

    /// Format raw SMC bytes as hex string, e.g. "0x01 00 00 00".
    private static func formatHex(_ bytes: [UInt8]) -> String {
        "0x" + bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private func performHealthCheck(battery: BatteryState) {
        guard let chteBytes = io.readKey(SMC.keyChargeTerminate), chteBytes.count == 4,
              let chieBytes = io.readKey(SMC.keyChargeInhibit), chieBytes.count == 1 else {
            // Cannot read SMC — preserve any existing warning rather than
            // clearing it. Log it: without this the check silently never
            // completes and About shows "pending" with no clue why.
            NSLog("Ampere: Health check skipped — CHTE/CHIE read failed")
            return
        }

        // loadUnaligned because Swift's [UInt8] buffer isn't guaranteed to be
        // UInt32-aligned. macOS arm64 permits unaligned loads, but `.load`'s
        // API contract requires alignment — undefined behavior otherwise.
        let chte = chteBytes.withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self)) }
        let chie = Int(chieBytes[0])

        let healthy: Bool
        if autoManageEnabled {
            // While charge-to-full is active the expected-state rules are the
            // charge-to-upper rules evaluated against a ceiling of 100 — the
            // same equivalence the state machine uses — so the pure checkers
            // don't need a separate flag.
            healthy = Self.healthCheckAutoMode(
                chargeLevel: battery.percentage,
                lowerBound: chargeLowerBound,
                upperBound: effectiveUpperBound,
                dischargeEnabled: autoDischargeEnabled,
                activeDischarging: activeDischarging,
                chargeToUpperBound: chargeToUpperBound || chargeToFull,
                chie: chie, chte: chte, fullyCharged: battery.fullyCharged
            )
        } else {
            healthy = Self.healthCheckManualMode(
                pauseButtonPaused: chargingPaused,
                chie: chie, chte: chte
            )
        }

        let chteHex = Self.formatHex(chteBytes)
        let chieHex = Self.formatHex(chieBytes)
        let newSMC = "\(SMC.keyChargeTerminate)=\(chteHex)\n\(SMC.keyChargeInhibit)=\(chieHex)"
        let newStatus: String
        var newExpected = ""
        var newCHTEMatch = true
        var newCHIEMatch = true
        var newWarning: String?
        if healthy {
            newStatus = "pass"
            newWarning = nil
            chteRepairAttempted = false
        } else {
            newStatus = "FAIL"
            let expected = Self.expectedSMCValues(
                autoManageEnabled: autoManageEnabled,
                pauseButtonPaused: chargingPaused,
                chargeLevel: battery.percentage,
                lowerBound: chargeLowerBound,
                upperBound: effectiveUpperBound,
                dischargeEnabled: autoDischargeEnabled,
                activeDischarging: activeDischarging,
                chargeToUpperBound: chargeToUpperBound || chargeToFull,
                fullyCharged: battery.fullyCharged
            )
            newExpected = "\(SMC.keyChargeTerminate)=\(expected.chte)\n\(SMC.keyChargeInhibit)=\(expected.chie)"
            newCHTEMatch = chteHex == expected.chte
            newCHIEMatch = chieHex == expected.chie
            NSLog("Ampere: Health check failed — CHTE=%d CHIE=%d charge=%d%% paused=%d auto=%d discharge=%d bounds=[%d,%d]",
                  chte, chie, battery.percentage, chargingPaused, autoManageEnabled, autoDischargeEnabled,
                  chargeLowerBound, chargeUpperBound)

            // Self-repair a drifted CHTE instead of only reporting it (see
            // chteRepairOp). No in-memory state mirror is needed: the write
            // drives the hardware toward the state the app already claims.
            // Takes the same in-flight token as every other SMC dispatch
            // site. No refresh() from the completion — if firmware reverts
            // the write instantly, an immediate re-check would tight-loop;
            // the next tick (60s slow / 10s popover) re-verifies at a sane
            // cadence and clears the FAIL status once the repair sticks.
            if let op = Self.chteRepairOp(
                   chteMatch: newCHTEMatch, chieMatch: newCHIEMatch, chie: chie,
                   expectedChte: expected.chte, activeDischarging: activeDischarging),
               !autoManageInFlight, isSudoRuleInstalled {
                newWarning = chteRepairAttempted ? Self.smcMismatchWarning : nil
                chteRepairAttempted = true
                autoManageInFlight = true
                let pct = battery.percentage
                let revision = controlRevision
                smcQueue.async { [weak self] in
                    guard let self else { return }
                    let ok = self.runSMCWrite(op)
                    DispatchQueue.main.async {
                        self.autoManageInFlight = false
                        NSLog("Ampere: Health check CHTE repair (%@) at %d%% %@",
                              op == .inhibit ? "inhibit" : "allow", pct,
                              ok ? "applied" : "failed")
                        if self.controlRevision != revision || self.wakeReassertPending {
                            self.refresh()
                        }
                    }
                }
            } else {
                newWarning = Self.smcMismatchWarning
            }
        }

        // Publishing any of these fires objectWillChange, which redraws the
        // menu bar and re-renders the (possibly hidden) SwiftUI tree — the
        // very churn publishStateIfNeeded exists to avoid. When the popover
        // is hidden and the result is identical to the last check, skip the
        // publish entirely; only the timestamp would move, and the About
        // sheet that displays it can't be visible. Opening the popover
        // triggers an immediate refresh, so the timestamp is fresh by the
        // time it can be seen.
        let changed = lastHealthCheckStatus != newStatus
            || lastHealthCheckSMC != newSMC
            || lastHealthCheckExpected != newExpected
            || lastHealthCheckCHTEMatch != newCHTEMatch
            || lastHealthCheckCHIEMatch != newCHIEMatch
            || healthWarning != newWarning
        guard isPopoverVisible || changed else { return }

        lastHealthCheckTime = Date()
        lastHealthCheckSMC = newSMC
        lastHealthCheckStatus = newStatus
        lastHealthCheckExpected = newExpected
        lastHealthCheckCHTEMatch = newCHTEMatch
        lastHealthCheckCHIEMatch = newCHIEMatch
        healthWarning = newWarning
    }

    /// Re-run the health check immediately (e.g. after revoke/re-grant admin).
    private func recheckHealth() {
        guard let battery = self.io.battery() else { return }
        performHealthCheck(battery: battery)
    }

    /// Lid state (clamshell), read from IOPMrootDomain. Consulted only by
    /// the sleep-hold release rule: a closed lid during a hold means a sleep
    /// attempt was absorbed, so the hold persists to the upper bound. The
    /// key is absent on desktops (no lid) and on a failed read — both report
    /// open, which is safe: those machines only sleep via announcements,
    /// and the pre-sleep pause covers that path.
    static func readClamshellClosed() -> Bool {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault,
            IOServiceMatching("IOPMrootDomain"))
        guard entry != MACH_PORT_NULL else { return false }
        defer { IOObjectRelease(entry) }
        return (IORegistryEntryCreateCFProperty(entry, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool) ?? false
    }

    static func readBattery() -> BatteryState? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [Any],
              let first = sources.first,
              let desc = IOPSGetPowerSourceDescription(snapshot, first as CFTypeRef)?.takeUnretainedValue() as? [String: Any]
        else { return nil }

        let percentage = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
        let isCharging = (desc[kIOPSIsChargingKey] as? Bool) ?? false
        let powerSource = desc[kIOPSPowerSourceStateKey] as? String ?? ""
        let isPluggedIn = powerSource == kIOPSACPowerValue
        // IOPS "Is Charged" as the baseline; the registry's raw BMS flag
        // (read below, where the battery service is available) overrides it
        // when present. Default false — a missing key must never fake a
        // completed charge.
        var fullyCharged = desc[kIOPSIsChargedKey] as? Bool ?? false

        let timeToEmpty = desc[kIOPSTimeToEmptyKey] as? Int
        let timeToFull = desc[kIOPSTimeToFullChargeKey] as? Int

        var timeRemaining = ""
        if isCharging, let ttf = timeToFull, ttf > 0 {
            timeRemaining = "\(ttf / 60)h \(ttf % 60)m to full"
        } else if !isCharging && !isPluggedIn, let tte = timeToEmpty, tte > 0 {
            timeRemaining = "\(tte / 60)h \(tte % 60)m remaining"
        }

        let service = IOServiceGetMatchingService(kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery"))
        defer { IOObjectRelease(service) }

        var cycleCount = 0
        var designCap = 0
        var maxCap = 0
        var currentCap = 0
        var amperage: Double?
        var voltage: Double?
        var temperature = 0.0
        var adapterWatts: Double?
        var adapterAmperage: Double?
        var adapterVoltage: Double?
        var totalLoadWatts: Double?
        var electronicsWatts: Double?
        var batteryWatts: Double?

        if service != MACH_PORT_NULL {
            if let val = IORegistryEntryCreateCFProperty(service, "CycleCount" as CFString, nil, 0)?.takeRetainedValue() as? Int {
                cycleCount = val
            }
            if let val = IORegistryEntryCreateCFProperty(service, "DesignCapacity" as CFString, nil, 0)?.takeRetainedValue() as? Int {
                designCap = val
            }
            if let val = IORegistryEntryCreateCFProperty(service, "AppleRawMaxCapacity" as CFString, nil, 0)?.takeRetainedValue() as? Int {
                maxCap = val
            }
            if let val = IORegistryEntryCreateCFProperty(service, "AppleRawCurrentCapacity" as CFString, nil, 0)?.takeRetainedValue() as? Int {
                currentCap = val
            }
            if let val = Self.numericValue(IORegistryEntryCreateCFProperty(service, "Amperage" as CFString, nil, 0)?.takeRetainedValue()) {
                amperage = val
            }
            if let val = IORegistryEntryCreateCFProperty(service, "Voltage" as CFString, nil, 0)?.takeRetainedValue() as? Int {
                voltage = Double(val) / 1000.0
            }
            if let val = IORegistryEntryCreateCFProperty(service, "Temperature" as CFString, nil, 0)?.takeRetainedValue() as? Int {
                temperature = Double(val) / 100.0
            }
            if let val = IORegistryEntryCreateCFProperty(service, "FullyCharged" as CFString, nil, 0)?.takeRetainedValue() as? Bool {
                fullyCharged = val
            }
            if let telemetry = IORegistryEntryCreateCFProperty(service, "PowerTelemetryData" as CFString, nil, 0)?.takeRetainedValue() as? [String: Any] {
                adapterWatts = Self.milliwattsToWatts(telemetry["SystemPowerIn"])
                adapterAmperage = Self.numericValue(telemetry["SystemCurrentIn"])
                adapterVoltage = Self.millivoltsToVolts(telemetry["SystemVoltageIn"])
                totalLoadWatts = Self.milliwattsToWatts(telemetry["SystemLoad"])
                // NOTE: PowerTelemetryData.SystemLoad is the *total* load on the
                // adapter rail — it includes battery charging power. We compute
                // electronics-only "Load" below from `adapter − battery` so
                // the relationship Adapter ≈ Load + Battery holds.
            }
            // Intentionally no AdapterDetails fallback: details["Watts"] /
            // details["Current"] are the adapter's *rated* capacity, not its
            // live draw, so falling back would surface a constant lie. If
            // PowerTelemetryData is absent (very old Macs), leave nil and the
            // UI shows "—".
        }

        // batteryWatts is only meaningful when we actually read both voltage
        // and amperage from the battery service. Keep nil otherwise so the
        // UI shows "—" instead of a misleading "0.0 W".
        let batW: Double? = {
            guard let voltage, let amperage, voltage > 0 else { return nil }
            return voltage * amperage / 1000.0
        }()
        batteryWatts = batW

        // Electronics-only consumption = input/load − battery charging power.
        // Order matters: prefer the adapter reading; once the adapter is gone,
        // the discharge sign of `batW` is a more trustworthy source of the
        // System Load figure than `SystemLoad` (which is by definition an
        // adapter-rail quantity and shouldn't be relied on without an adapter
        // — using it then would double-count `|batW|`). `SystemLoad` is the
        // belt-and-suspenders fallback for the rare case where the adapter is
        // present but `SystemPowerIn` is unavailable.
        // Clamp subtraction to ≥ 0 because adapter/load and battery values
        // come from independent IOKit reads and can briefly disagree.
        // `batW ?? 0` is safe in branches 1 and 3: if the battery is
        // unreadable, the entire input goes to System Load.
        let electronicsW: Double?
        if let adapter = adapterWatts {
            electronicsW = max(0, adapter - (batW ?? 0))
        } else if let batW, batW < 0 {
            electronicsW = -batW
        } else if let totalLoad = totalLoadWatts {
            electronicsW = max(0, totalLoad - (batW ?? 0))
        } else {
            electronicsW = nil
        }
        electronicsWatts = electronicsW

        var adapterConnected = isPluggedIn
        if !adapterConnected, service != MACH_PORT_NULL {
            if let details = IORegistryEntryCreateCFProperty(service, "AdapterDetails" as CFString, nil, 0)?.takeRetainedValue() as? [String: Any] {
                if let watts = details["Watts"] as? Int, watts > 0 {
                    adapterConnected = true
                }
            }
        }

        // Battery age: estimate manufacture date from UpdateTime - TotalOperatingTime
        var batteryAgeYears = ""
        var batteryAgeDays = ""
        if service != MACH_PORT_NULL,
           let updateTime = IORegistryEntryCreateCFProperty(service, "UpdateTime" as CFString, nil, 0)?.takeRetainedValue() as? Int,
           let battData = IORegistryEntryCreateCFProperty(service, "BatteryData" as CFString, nil, 0)?.takeRetainedValue() as? [String: Any],
           let lifeData = battData["LifetimeData"] as? [String: Any],
           let totalHours = lifeData["TotalOperatingTime"] as? Int, totalHours > 0 {
            let firstUseTimestamp = TimeInterval(updateTime) - TimeInterval(totalHours * 3600)
            let firstUseDate = Date(timeIntervalSince1970: firstUseTimestamp)
            let totalDays = Int(Date().timeIntervalSince(firstUseDate) / 86400)
            let years = totalDays / 365
            let months = (totalDays % 365) / 30
            if years > 0 {
                batteryAgeYears = "\(years)y \(months)m"
            } else if months > 0 {
                batteryAgeYears = "\(months)m"
            } else {
                batteryAgeYears = "< 1m"
            }
            batteryAgeDays = "\(totalDays)d"
        }

        let healthPercent = designCap > 0 ? min(100, Int(Double(maxCap) / Double(designCap) * 100)) : 100
        let health = "\(healthPercent)%"

        return BatteryState(
            percentage: percentage,
            cycleCount: cycleCount,
            isCharging: isCharging,
            adapterConnected: adapterConnected,
            health: health,
            temperature: temperature,
            timeRemaining: timeRemaining,
            designCapacity: designCap,
            maxCapacity: maxCap,
            currentCapacity: currentCap,
            amperage: amperage,
            voltage: voltage,
            adapterWatts: adapterWatts,
            adapterAmperage: adapterAmperage,
            adapterVoltage: adapterVoltage,
            electronicsWatts: electronicsWatts,
            batteryWatts: batteryWatts,
            batteryAgeYears: batteryAgeYears,
            batteryAgeDays: batteryAgeDays,
            fullyCharged: fullyCharged
        )
    }

    /// Coerce any numeric value pulled out of an IOKit dict into a Double.
    /// CF numeric types (CFNumber regardless of underlying width) bridge to
    /// NSNumber, so this single case covers Int / Int64 / UInt64 / Double /
    /// Float / Bool and anything else that's actually a number.
    private static func numericValue(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func milliwattsToWatts(_ value: Any?) -> Double? {
        numericValue(value).map { $0 / 1000.0 }
    }

    private static func millivoltsToVolts(_ value: Any?) -> Double? {
        numericValue(value).map { $0 / 1000.0 }
    }

    // MARK: - Toggle

    /// Turn the one-shot "Charge to Full" override on or off.
    ///
    /// Activating turns the Discharge to Upper Bound preference OFF (not
    /// merely suspended): actively draining the battery right after an
    /// explicit full charge is never what the user meant, and a hidden
    /// "re-arms later" state would be worse than asking them to re-enable
    /// the preference when they actually want it again. The refresh() kicked
    /// below then stops any in-flight discharge (via its !autoDischargeEnabled
    /// branch) before the state machine issues the allow.
    ///
    /// Deactivating mid-charge mirrors the charge-to-upper toggle: inhibit
    /// immediately; the next state-machine cycle restores the rule-1/3
    /// default for the current level (including charge-to-upper if below
    /// the lower bound).
    func setChargeToFull(_ on: Bool) {
        if on {
            if autoDischargeEnabled { autoDischargeEnabled = false }
            requestedChargingPaused = nil
            chargeToFull = true
            refresh()
        } else {
            chargeToFull = false
            inhibitCharging()
        }
    }

    /// Explicit cancellation is queued even while an earlier allow is in
    /// flight. The shared dispatcher applies it after that write completes.
    func inhibitCharging() {
        requestedChargingPaused = true
        refresh()
    }

    func toggleCharging() {
        let shouldPause = !(requestedChargingPaused ?? chargingPaused)
        if shouldPause {
            guard let battery = io.battery() ?? state, battery.adapterConnected else {
                lastError = Self.noAdapterError
                return
            }
        }
        ensureSudoInstalled { [weak self] ok in
            guard let self, ok else {
                self?.lastError = "Admin access required to control charging"
                return
            }
            self.requestedChargingPaused = shouldPause
            self.refresh()
        }
    }
}
