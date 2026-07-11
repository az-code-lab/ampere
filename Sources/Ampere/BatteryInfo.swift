import Foundation
import AppKit
import CryptoKit
import IOKit.ps
import Shared


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
}

final class BatteryMonitor: ObservableObject {
    @Published var state: BatteryState?
    @Published var chargingPaused: Bool = false
    @Published var activeDischarging: Bool = false
    @Published var autoDischargeEnabled: Bool {
        didSet { UserDefaults.standard.set(autoDischargeEnabled, forKey: "autoDischargeEnabled") }
    }
    @Published var chargeToUpperBound: Bool {
        didSet { UserDefaults.standard.set(chargeToUpperBound, forKey: "chargeToUpperBound") }
    }
    /// Show the "77%" text beside the menu bar battery icon; off = icon
    /// only, halving the menu bar footprint. Lives here rather than in
    /// @AppStorage because AppDelegate (not the SwiftUI tree) renders the
    /// menu bar item and needs a change signal via objectWillChange.
    @Published var showMenuBarPercent: Bool {
        didSet { UserDefaults.standard.set(showMenuBarPercent, forKey: "showMenuBarPercent") }
    }
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

    @Published var autoManageEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoManageEnabled, forKey: "autoManageEnabled")
        }
    }
    /// Minimum gap between charge bounds, matches the slider's `minGap`.
    static let chargeBoundMinGap = 5

    @Published var chargeLowerBound: Int {
        didSet {
            if chargeLowerBound < 0 { chargeLowerBound = 0 }
            else if chargeLowerBound > chargeUpperBound - Self.chargeBoundMinGap {
                chargeLowerBound = chargeUpperBound - Self.chargeBoundMinGap
            }
            UserDefaults.standard.set(chargeLowerBound, forKey: "chargeLowerBound")
        }
    }
    @Published var chargeUpperBound: Int {
        didSet {
            if chargeUpperBound > 100 { chargeUpperBound = 100 }
            else if chargeUpperBound < chargeLowerBound + Self.chargeBoundMinGap {
                chargeUpperBound = chargeLowerBound + Self.chargeBoundMinGap
            }
            UserDefaults.standard.set(chargeUpperBound, forKey: "chargeUpperBound")
        }
    }

    private var timer: Timer?
    private var updateCheckTimer: Timer?
    // Self-update plumbing, used by the extension in Updater.swift. Not
    // `private`: stored properties can't live in a cross-file extension,
    // but the logic that touches them does.
    var updateDownloadTask: URLSessionDownloadTask?
    var updateProgressObservation: NSKeyValueObservation?
    private var terminationObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var autoManageInFlight = false
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
            // Encode nil as absence; only persist concrete true/false.
            if let v = lastAdapterConnected {
                UserDefaults.standard.set(v, forKey: "lastAdapterConnected")
            } else {
                UserDefaults.standard.removeObject(forKey: "lastAdapterConnected")
            }
        }
    }
    private let smcQueue = DispatchQueue(label: "com.ampere.smc", qos: .utility)

    /// Single source of truth for the "no adapter" error string — it's
    /// both set (in toggleCharging) and compared (in refresh) to clear on
    /// reconnect; literal duplication would let a typo silently break the
    /// clear path.
    private static let noAdapterError = "No power adapter connected"

    /// Skip health checks on the first N refresh cycles so launch-time SMC
    /// writes have a chance to settle before we assert on their results.
    private static let healthCheckSettleRefreshes = 3

    private static let sudoersPath = AppConstants.sudoersPath
    private static let helperPath = AppConstants.helperPath

    init() {
        // Load persisted auto-manage settings
        let defaults = UserDefaults.standard
        let autoManage = defaults.bool(forKey: "autoManageEnabled")
        self.autoManageEnabled = autoManage
        self.autoDischargeEnabled = defaults.bool(forKey: "autoDischargeEnabled")
        // Default true (shown) — bool(forKey:) would read a missing key as false.
        self.showMenuBarPercent = defaults.object(forKey: "showMenuBarPercent") as? Bool ?? true
        let originalLower = defaults.object(forKey: "chargeLowerBound") as? Int
        let originalUpper = defaults.object(forKey: "chargeUpperBound") as? Int
        var lower = originalLower ?? 40
        var upper = originalUpper ?? 60
        if lower < 0 { lower = 0 }
        if upper > 100 { upper = 100 }
        // Reset to defaults if the saved gap violates the minGap invariant
        // (corrupted UserDefaults or values written by an older build).
        // didSet doesn't fire on init, so this is the only chance to repair.
        if upper - lower < Self.chargeBoundMinGap { lower = 40; upper = 60 }
        self.chargeLowerBound = lower
        self.chargeUpperBound = upper
        // Persist the repair if it differs from what was on disk —
        // otherwise the corrupted values would resurface on every launch.
        if originalLower != lower { defaults.set(lower, forKey: "chargeLowerBound") }
        if originalUpper != upper { defaults.set(upper, forKey: "chargeUpperBound") }
        // Charge-to-upper intent persists across restart so a crash mid-recovery
        // resumes the in-progress charge rather than parking at the current level.
        // Clear it if auto-manage is disabled (it has no effect outside auto mode).
        let persistedCtu = defaults.bool(forKey: "chargeToUpperBound")
        self.chargeToUpperBound = autoManage && persistedCtu
        // Persist the negation (autoManage=false but persisted ctu=true would
        // otherwise stay diverged from in-memory state forever, since didSet
        // doesn't fire during init).
        if !self.chargeToUpperBound && persistedCtu {
            defaults.set(false, forKey: "chargeToUpperBound")
        }
        // Restore the last-known adapter state so rule 2 (connected→disconnected
        // → clear chargeToUpperBound) can fire on the first refresh after a
        // restart that crossed an adapter transition.
        self.lastAdapterConnected = defaults.object(forKey: "lastAdapterConnected") as? Bool

        // chargingPaused starts false; the launch-cleanup block below may
        // set it to true if shouldInhibit applies. Not persisted — always
        // derived fresh from the rule conditions at launch.
        chargingPaused = false
        // If the helper is missing or out-of-date, install (or update) it.
        // brew uninstall would have removed the helper; a fresh app build
        // would have a different helper binary. The install prompts for
        // admin via osascript; cancellation terminates the app.
        if !isSudoRuleInstalled || isHelperStale {
            NSLog("Ampere: Helper %@, installing…", !isSudoRuleInstalled ? "missing" : "stale")
            if !installSudo() {
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
            let launchBattery = Self.readBattery()
            let launchPercentage = launchBattery?.percentage ?? 0
            // Crash-recovery sanity: chargeToUpperBound=true is only valid below
            // the upper bound. A crash between the state machine's CHTE=inhibit
            // write and its in-memory ctu=false update can leave ctu=true
            // persisted with pct already at/above upper. Without this correction,
            // shouldInhibit below would compute false and the launch cleanup
            // would briefly write CHTE=allow, violating the invariant until the
            // first refresh self-corrects.
            if chargeToUpperBound, launchBattery != nil, launchPercentage >= chargeUpperBound {
                chargeToUpperBound = false
                defaults.set(false, forKey: "chargeToUpperBound")
            }
            // Respect persisted charge-to-upper intent: if true, skip the inhibit
            // so an in-progress charge-to-upper survives a restart.
            let shouldInhibit = autoManageEnabled
                && launchBattery != nil
                && launchPercentage >= chargeLowerBound
                && !chargeToUpperBound
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
                UserDefaults.standard.set(true, forKey: "chargeToUpperBound")
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
        // Check for updates: 5 minutes after launch, then once daily at a random interval
        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { [weak self] _ in
            self?.checkForUpdate()
            self?.scheduleNextUpdateCheck()
        }

        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            guard self.chargingPaused || self.activeDischarging else { return }

            let done = DispatchSemaphore(value: 0)
            self.smcQueue.async {
                // Always restore system defaults on quit.
                // Use runSMCWriteViaSudo directly to avoid stopDischarge()
                // spawning a redundant watchdog during shutdown.
                if self.activeDischarging {
                    _ = self.runSMCWriteViaSudo("nodischarge")
                }
                if self.chargingPaused {
                    _ = self.runSMCWriteViaSudo("allow")
                }

                done.signal()
            }
            _ = done.wait(timeout: .now() + 6.0)
        }

        // Re-assert SMC state on wake — firmware or PD renegotiation can reset
        // CHTE during sleep, allowing charging to bypass micro-charge prevention.
        // Delegate to evaluateAutoManageStep so rule 1/2/3 transitions are
        // handled consistently with refresh() and don't race against it.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self, self.isSudoRuleInstalled else { return }
            // Take the same in-flight token every other SMC dispatch site
            // uses, so the wake write can't interleave with a concurrent
            // timer-refresh dispatch. If one is already in flight, skip —
            // its completion refresh() re-runs the state machine anyway.
            guard !self.autoManageInFlight else {
                NSLog("Ampere: System wake — SMC op in flight, deferring to refresh")
                return
            }
            NSLog("Ampere: System wake — re-asserting SMC state")
            self.autoManageInFlight = true

            // Capture all state on main queue to avoid cross-queue reads.
            let activeDischarging = self.activeDischarging
            let chargingPausedSnapshot = self.chargingPaused
            let priorState = AutoManageState(
                chargingPaused: chargingPausedSnapshot,
                chargeToUpperBound: self.chargeToUpperBound,
                lastAdapterConnected: self.lastAdapterConnected
            )
            let autoManageEnabledSnapshot = self.autoManageEnabled
            let lower = self.chargeLowerBound
            let upper = self.chargeUpperBound

            self.smcQueue.async {
                if activeDischarging {
                    if !self.startDischarge() {
                        NSLog("Ampere: Wake — failed to re-assert active discharge state")
                        // startDischarge's internal nodischarge killed any
                        // existing watchdog; if the discharge:PID step then
                        // failed, no new watchdog was spawned. Re-spawn one
                        // so crash safety isn't lost until next refresh.
                        let pid = ProcessInfo.processInfo.processIdentifier
                        let okWatchdog = self.runSMCWriteViaSudo("spawn-watchdog:\(pid)")
                        if !okWatchdog {
                            NSLog("Ampere: Wake — watchdog respawn after failed discharge restart also failed")
                        }
                    }
                    DispatchQueue.main.async {
                        self.autoManageInFlight = false
                        self.refresh()
                    }
                    return
                }

                guard let battery = Self.readBattery() else {
                    DispatchQueue.main.async {
                        self.autoManageInFlight = false
                        self.refresh()
                    }
                    return
                }

                let inputs = AutoManageInputs(
                    autoManageEnabled: autoManageEnabledSnapshot,
                    adapterConnected: battery.adapterConnected,
                    percentage: battery.percentage,
                    lowerBound: lower,
                    upperBound: upper
                )
                let decision = BatteryMonitor.evaluateAutoManageStep(
                    state: priorState, inputs: inputs
                )

                // Determine the SMC op to write. An explicit transition from the
                // pure function wins. Otherwise re-assert inhibit if we were
                // already paused, so a firmware-induced CHTE reset during sleep
                // gets corrected before the next refresh cycle.
                let op: SMCWriteOp?
                switch decision.action {
                case .allow:   op = .allow
                case .inhibit: op = .inhibit
                case .none:    op = chargingPausedSnapshot ? .inhibit : nil
                }

                if let op = op {
                    let ok = self.runSMCWrite(op)
                    DispatchQueue.main.async {
                        self.autoManageInFlight = false
                        // Only mirror the state-machine's decision into
                        // in-memory state if the SMC write actually landed.
                        // Otherwise we'd report "paused" while CHTE still
                        // allows charging (or vice versa) — divergence the
                        // next refresh/health-check would have to clean up.
                        if ok, decision.action != .none {
                            self.chargingPaused = decision.newState.chargingPaused
                            self.chargeToUpperBound = decision.newState.chargeToUpperBound
                            NSLog("Ampere: Wake — auto-manage %@ at %d%%",
                                  op == .allow ? "allow" : "inhibit", battery.percentage)
                        }
                        self.refresh()
                    }
                } else {
                    DispatchQueue.main.async {
                        self.autoManageInFlight = false
                        self.refresh()
                    }
                }
            }
        }
    }

    deinit {
        timer?.invalidate()
        updateCheckTimer?.invalidate()
        updateDownloadTask?.cancel()
        if let observer = terminationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = wakeObserver {
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
    var isSudoRuleInstalled: Bool {
        FileManager.default.fileExists(atPath: Self.sudoersPath)
            && FileManager.default.fileExists(atPath: Self.helperPath)
    }

    /// Check if the installed helper differs from the bundled one. Returns
    /// `false` when either side can't be read — we can't reinstall what we
    /// don't have, so callers should fall through and use whatever helper
    /// is currently installed. The bundled-side miss is logged once per
    /// check because in a release build it indicates a corrupted bundle.
    private var isHelperStale: Bool {
        guard let installed = try? Data(contentsOf: URL(fileURLWithPath: Self.helperPath)) else {
            return false
        }
        guard let bundled = try? Data(contentsOf: URL(fileURLWithPath: smcWriterPath)) else {
            NSLog("Ampere: bundled SMCWriter unreadable at %@ — cannot check staleness", smcWriterPath)
            return false
        }
        return installed != bundled
    }

    /// Remove the sudoers rule and helper binary.
    /// If charging is paused, resumes charging via sudo BEFORE removing the rule.
    func removeSudoRule() {
        let wasPaused = self.chargingPaused
        let wasDischarging = self.activeDischarging
        smcQueue.async { [weak self] in
            guard let self = self else { return }

            // Also remove the saved-pmset state dir and any legacy /tmp
            // markers — the nodischarge below has already restored sleep
            // settings, so leftover markers would only mislead a future
            // install into "restoring" values from a stale session.
            let cmd = "rm -f \(Self.shQuote(Self.sudoersPath)) \(Self.shQuote(Self.helperPath))"
                + " \(Self.shQuote(AppConstants.legacySavedSleepPath))"
                + " \(Self.shQuote(AppConstants.legacySavedDisplaySleepPath))"
                + " && rm -rf \(Self.shQuote(AppConstants.stateDirPath))"

            // Always clear all SMC state BEFORE removing the helper (need sudo access).
            // Use unconditional writes since in-memory state may not reflect actual SMC state.
            _ = self.runSMCWriteViaSudo("nodischarge")
            _ = self.runSMCWriteViaSudo("allow")

            let ok = self.runAsAdmin(cmd)

            DispatchQueue.main.async {
                if ok && !self.isSudoRuleInstalled {
                    self.autoManageEnabled = false
                    self.autoDischargeEnabled = false
                    self.chargeToUpperBound = false
                    self.chargingPaused = false
                    self.activeDischarging = false
                    // Clear any stale error — the user just acted on the
                    // common "revoke and re-grant admin access" guidance.
                    self.lastError = nil
                    self.recheckHealth()
                } else {
                    // Removal failed or was cancelled — restore previous SMC
                    // state. The nodischarge command above pkill'd the
                    // launch-time watchdog, so we must respawn one or the
                    // app has no crash safety net for the rest of the session.
                    // startDischarge spawns its own watchdog; the !wasDischarging
                    // branch must respawn manually.
                    self.smcQueue.async {
                        if wasPaused { self.runSMCWrite(.inhibit) }
                        if wasDischarging {
                            _ = self.startDischarge()
                        } else {
                            let pid = ProcessInfo.processInfo.processIdentifier
                            let okWatchdog = self.runSMCWriteViaSudo("spawn-watchdog:\(pid)")
                            if !okWatchdog {
                                NSLog("Ampere: Watchdog spawn failed during removeSudoRule rollback — crash safety net not installed")
                            }
                        }
                    }
                }
            }
        }
    }

    /// Run shell commands as root via osascript "with administrator privileges".
    /// Shows the native macOS password dialog (one-time setup only).
    private func runAsAdmin(_ commands: String) -> Bool {
        let escaped = commands.replacingOccurrences(of: "\"", with: "\\\"")
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
    private var smcWriterPath: String {
        let mainBinary = Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments[0]
        // SMCWriter is a sibling executable in the same build directory
        return (mainBinary as NSString).deletingLastPathComponent + "/SMCWriter"
    }

    /// Single-quote a string for safe use in a shell command, escaping any
    /// embedded single quotes via the `'\''` idiom.
    private static func shQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Install the SMCWriter binary at a root-owned fixed path, plus a sudoers rule.
    /// Shows the native macOS password dialog (one-time).
    private func installSudo() -> Bool {
        // Digest-pin the sudoers rule to the exact binary being installed. A
        // path-only NOPASSWD rule trusts whatever sits at helperPath — if the
        // directory is ever non-root-writable (e.g. a migrated Intel-Homebrew
        // /usr/local), swapping the binary would grant passwordless root.
        // sudo verifies the digest on every invocation; a helper update
        // rewrites the binary and this rule together, so they can't drift.
        // (cp/xattr/chmod/chown don't alter the data fork, so the digest of
        // the bundled source equals the digest of the installed copy.)
        guard let helperData = try? Data(contentsOf: URL(fileURLWithPath: smcWriterPath)) else {
            NSLog("Ampere: bundled SMCWriter unreadable at %@ — cannot install", smcWriterPath)
            return false
        }
        let digest = SHA256.hash(data: helperData).map { String(format: "%02x", $0) }.joined()
        let writer = Self.shQuote(smcWriterPath)
        let helper = Self.shQuote(Self.helperPath)
        let sudoers = Self.shQuote(Self.sudoersPath)
        let rule = Self.shQuote("\(NSUserName()) ALL=(root) NOPASSWD: sha256:\(digest) \(Self.helperPath)\n")
        let cmd = [
            "mkdir -p /usr/local/bin",
            "cp \(writer) \(helper)",
            "xattr -cr \(helper)",
            "chmod 0755 \(helper)",
            "chown root:wheel \(helper)",
            "printf '%s' \(rule) > \(sudoers)",
            "chmod 0440 \(sudoers)",
        ].joined(separator: " && ")

        return runAsAdmin(cmd)
    }

    /// Ensure sudo helper is installed (prompts for password on background queue).
    /// Calls completion on the main queue with success/failure.
    func ensureSudoInstalled(completion: @escaping (Bool) -> Void) {
        if isSudoRuleInstalled && !isHelperStale {
            completion(true)
            return
        }
        smcQueue.async { [weak self] in
            let ok = self?.installSudo() ?? false
            // If install succeeded, spawn a watchdog right away — the
            // launch-time watchdog was likely killed by a previous
            // removeSudoRule (which runs nodischarge), and refresh()
            // doesn't re-spawn on its own. Without this, the app would
            // have no crash safety net until the next launch.
            if ok, let self = self {
                let pid = ProcessInfo.processInfo.processIdentifier
                let okWatchdog = self.runSMCWriteViaSudo("spawn-watchdog:\(pid)")
                if !okWatchdog {
                    NSLog("Ampere: Watchdog spawn failed after install — crash safety net not installed")
                }
            }
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
        _ = runSMCWriteViaSudo("nodischarge")

        let ok = runSMCWriteViaSudo("discharge:\(ProcessInfo.processInfo.processIdentifier)")
        if ok {
            NSLog("Ampere: discharge daemon started")
        }
        return ok
    }

    /// Stop discharge: clear CHIE, kill watchdog, restore sleep, then re-spawn
    /// a watchdog so CHTE is still protected if the app is killed. Returns
    /// the success of the primary `nodischarge` write; logs but does not fail
    /// the overall call if only the watchdog respawn failed.
    private func stopDischarge() -> Bool {
        let ok = runSMCWriteViaSudo("nodischarge")
        let watchdogOk = runSMCWriteViaSudo("spawn-watchdog:\(ProcessInfo.processInfo.processIdentifier)")
        if !watchdogOk {
            if ok {
                NSLog("Ampere: nodischarge succeeded but watchdog respawn failed — CHTE protection on crash may be lost")
            } else {
                NSLog("Ampere: nodischarge failed AND watchdog respawn failed — discharge state may be stuck and no crash safety")
            }
        }
        if ok {
            NSLog("Ampere: discharge stopped")
        }
        return ok
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

    private func runSMCWriteViaSudo(_ arg: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        task.arguments = [Self.helperPath, arg]
        let errPipe = Pipe()
        task.standardInput = FileHandle.nullDevice
        task.standardError = errPipe
        // stdout is brief ("OK: ...") and never read — discard to /dev/null
        // rather than create an unread Pipe that could block on a large write.
        task.standardOutput = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 { return true }
            let errMsg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
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

    // MARK: - Auto-manage decision (pure, testable)

    /// Pure state carried across refresh() cycles for the auto-manage state machine.
    struct AutoManageState: Equatable {
        var chargingPaused: Bool
        var chargeToUpperBound: Bool
        var lastAdapterConnected: Bool?
    }

    /// Inputs observed by a single refresh() cycle.
    struct AutoManageInputs: Equatable {
        let autoManageEnabled: Bool
        let adapterConnected: Bool
        let percentage: Int
        let lowerBound: Int
        let upperBound: Int
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

    /// Core auto-manage state machine. Pure function: given the prior state and
    /// the currently observed inputs, return the SMC action to issue and the
    /// state to store after the action completes. Encodes:
    ///   Rule 1 — below lower bound on AC → allow + set chargeToUpperBound
    ///   Rule 2 — AC disconnect at or above lower bound → clear chargeToUpperBound
    ///   Rule 3 — between bounds without chargeToUpperBound → inhibit
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
        next.lastAdapterConnected = inputs.adapterConnected

        // Auto-manage SMC decisions only apply on AC with auto-manage enabled.
        guard inputs.autoManageEnabled, inputs.adapterConnected else {
            return AutoManageDecision(action: .none, newState: next)
        }

        // chargeToUpperBound is only meaningful below the upper bound (init
        // repairs persisted state the same way). A stale true here — e.g. the
        // toggle flipped from a UI rendered against the previous poll's
        // reading, just as the battery crossed the bound — would otherwise
        // make the paused branch below issue a spurious allow at/above the
        // bound, immediately reverted by an inhibit on the next cycle.
        if next.chargeToUpperBound, inputs.percentage >= inputs.upperBound {
            next.chargeToUpperBound = false
        }

        if !next.chargingPaused && inputs.percentage >= inputs.upperBound {
            // At or above upper bound → inhibit and reset charge-to-upper.
            next.chargingPaused = true
            next.chargeToUpperBound = false
            return AutoManageDecision(action: .inhibit, newState: next)
        } else if !next.chargingPaused && !next.chargeToUpperBound
                    && inputs.percentage >= inputs.lowerBound
                    && inputs.percentage < inputs.upperBound {
            // Between bounds without charge-to-upper → inhibit (rule 3).
            next.chargingPaused = true
            return AutoManageDecision(action: .inhibit, newState: next)
        } else if next.chargingPaused
                    && (inputs.percentage < inputs.lowerBound || next.chargeToUpperBound) {
            // Below lower bound (rule 1) or explicit charge-to-upper → allow.
            let belowLower = inputs.percentage < inputs.lowerBound
            next.chargingPaused = false
            if belowLower {
                next.chargeToUpperBound = true
            }
            return AutoManageDecision(action: .allow, newState: next)
        }

        return AutoManageDecision(action: .none, newState: next)
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
        chie: Int, chte: Int
    ) -> Bool {
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
            if chargeLevel >= upperBound {
                return chte == SMC.chteInhibitInt
            } else if chargeLevel >= lowerBound {
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
        chargeToUpperBound: Bool
    ) -> (chte: String, chie: String) {
        if autoManageEnabled {
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
                if chargeLevel >= upperBound {
                    return (SMC.chteInhibitHex, SMC.chieNormalHex)
                } else if chargeLevel >= lowerBound {
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
        refreshCount += 1
        var battery = Self.readBattery()
        // Publish unconditionally on every refresh — early returns below
        // dispatch SMC actions and exit, and on failure the dispatch's
        // callback intentionally does NOT recurse into refresh(). Without
        // this defer, the menu bar would be stuck at "0%" and the popover
        // at "no battery" whenever the first refresh trips an early return.
        defer { publishStateIfNeeded(battery) }

        // Stop discharge if the adapter disconnected mid-discharge. Gated
        // separately from the chargingPaused synthesize branch because the
        // window between "discharge dispatch succeeded → activeDischarging=true"
        // and "state machine ran → chargingPaused=true" can land here with
        // adapter=false, where the chargingPaused-gated cleanup would miss it.
        if activeDischarging, let b = battery, !b.adapterConnected, !autoManageInFlight {
            autoManageInFlight = true
            smcQueue.async { [weak self] in
                guard let self = self else { return }
                let ok = self.runSMCWrite(.nodischarge)
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
            smcQueue.async { [weak self] in
                guard let self = self else { return }
                let ok = self.runSMCWrite(.nodischarge)
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
            if !activeDischarging && b.percentage > chargeUpperBound {
                autoManageInFlight = true
                // Capture pct/upper at dispatch time so the log can't lie if
                // the user changes the upper bound while the SMC write is in
                // flight — matches the state-machine dispatch's pattern.
                let pct = b.percentage
                let upper = chargeUpperBound
                smcQueue.async { [weak self] in
                    guard let self = self else { return }
                    let ok = self.runSMCWrite(.discharge)
                    if !ok {
                        // startDischarge killed the existing watchdog before
                        // running discharge:PID; if that step failed, no new
                        // watchdog was spawned. Respawn so crash safety isn't
                        // lost until next refresh tick.
                        let pid = ProcessInfo.processInfo.processIdentifier
                        let okWatchdog = self.runSMCWriteViaSudo("spawn-watchdog:\(pid)")
                        if !okWatchdog {
                            NSLog("Ampere: Watchdog respawn after failed auto-discharge start also failed")
                        }
                    }
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
                smcQueue.async { [weak self] in
                    guard let self = self else { return }
                    let ok = self.runSMCWrite(.nodischarge)
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

        // Auto-manage state machine — delegated to the pure decision function
        // so behavior can be exercised by unit tests. This block handles rules
        // 1/2/3: below-lower → charge-to-upper, disconnect-above-lower → clear
        // charge-to-upper, between-bounds → no auto-charge.
        if let b = battery {
            let priorState = AutoManageState(
                chargingPaused: chargingPaused,
                chargeToUpperBound: chargeToUpperBound,
                lastAdapterConnected: lastAdapterConnected
            )
            let stepInputs = AutoManageInputs(
                autoManageEnabled: autoManageEnabled,
                adapterConnected: b.adapterConnected,
                percentage: b.percentage,
                lowerBound: chargeLowerBound,
                upperBound: chargeUpperBound
            )
            let decision = BatteryMonitor.evaluateAutoManageStep(
                state: priorState, inputs: stepInputs
            )

            // Pure state updates always apply (adapter tracking, rule-2 clear).
            lastAdapterConnected = decision.newState.lastAdapterConnected
            if chargeToUpperBound != decision.newState.chargeToUpperBound, decision.action == .none {
                chargeToUpperBound = decision.newState.chargeToUpperBound
                // Two pure-clear paths: rule 2 (AC disconnect above lower) and
                // the at/above-upper staleness repair.
                NSLog("Ampere: Cleared chargeToUpperBound at %d%%", b.percentage)
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

            // SMC action dispatch.
            if decision.action != .none, !autoManageInFlight {
                autoManageInFlight = true
                let pct = b.percentage
                let upper = chargeUpperBound
                let op: SMCWriteOp = decision.action == .allow ? .allow : .inhibit
                let next = decision.newState
                smcQueue.async { [weak self] in
                    guard let self = self else { return }
                    let ok = self.runSMCWrite(op)
                    DispatchQueue.main.async {
                        self.autoManageInFlight = false
                        if ok {
                            self.chargingPaused = next.chargingPaused
                            self.chargeToUpperBound = next.chargeToUpperBound
                            switch decision.action {
                            case .inhibit:
                                NSLog("Ampere: Inhibited charging at %d%%", pct)
                            case .allow:
                                NSLog("Ampere: Charging from %d%% to %d%%", pct, upper)
                            case .none:
                                break
                            }
                            self.refresh()
                        }
                        // On failure: don't re-refresh. The decision inputs
                        // are unchanged, so refresh would re-issue the same
                        // action and tight-loop. Wait for the next timer tick.
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
                        batteryAgeYears: b.batteryAgeYears, batteryAgeDays: b.batteryAgeDays
                    )
                }
            } else if !autoManageEnabled {
                // Manual mode: clear inhibit/discharge so charging works
                // when plugged back in. Only mirror the state mutation into
                // memory after the SMC writes land — same gating as the
                // wake observer and auto-manage paths. Without this, an
                // SMC-write failure would leave the in-memory state lying
                // (UI says "not paused" while CHTE is still inhibit), and
                // refresh's state machine wouldn't reconcile in manual mode.
                chargeToUpperBound = false  // in-memory only; safe to clear unconditionally
                smcQueue.async { [weak self] in
                    guard let self = self else { return }
                    let okAllow = self.runSMCWrite(.allow)
                    let okNoDischarge = self.runSMCWrite(.nodischarge)
                    DispatchQueue.main.async {
                        if okAllow { self.chargingPaused = false }
                        if okNoDischarge { self.activeDischarging = false }
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
        guard let chteBytes = Self.smcReadKey(SMC.keyChargeTerminate), chteBytes.count == 4,
              let chieBytes = Self.smcReadKey(SMC.keyChargeInhibit), chieBytes.count == 1 else {
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
            healthy = Self.healthCheckAutoMode(
                chargeLevel: battery.percentage,
                lowerBound: chargeLowerBound,
                upperBound: chargeUpperBound,
                dischargeEnabled: autoDischargeEnabled,
                activeDischarging: activeDischarging,
                chargeToUpperBound: chargeToUpperBound,
                chie: chie, chte: chte
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
        let newWarning: String?
        if healthy {
            newStatus = "pass"
            newWarning = nil
        } else {
            newStatus = "FAIL"
            let expected = Self.expectedSMCValues(
                autoManageEnabled: autoManageEnabled,
                pauseButtonPaused: chargingPaused,
                chargeLevel: battery.percentage,
                lowerBound: chargeLowerBound,
                upperBound: chargeUpperBound,
                dischargeEnabled: autoDischargeEnabled,
                activeDischarging: activeDischarging,
                chargeToUpperBound: chargeToUpperBound
            )
            newExpected = "\(SMC.keyChargeTerminate)=\(expected.chte)\n\(SMC.keyChargeInhibit)=\(expected.chie)"
            newCHTEMatch = chteHex == expected.chte
            newCHIEMatch = chieHex == expected.chie
            NSLog("Ampere: Health check failed — CHTE=%d CHIE=%d charge=%d%% paused=%d auto=%d discharge=%d bounds=[%d,%d]",
                  chte, chie, battery.percentage, chargingPaused, autoManageEnabled, autoDischargeEnabled,
                  chargeLowerBound, chargeUpperBound)
            newWarning = "SMC mismatch — revoke & re-grant admin"
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
        guard let battery = Self.readBattery() else { return }
        performHealthCheck(battery: battery)
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
            batteryAgeDays: batteryAgeDays
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

    /// Re-inhibit charging (e.g. when user toggles off "Charge to Upper Bound" mid-charge).
    func inhibitCharging() {
        guard !chargingPaused else { return }
        smcQueue.async { [weak self] in
            guard let self = self else { return }
            // Use runSMCWrite (not runSMCWriteViaSudo) so the missing-helper
            // case logs a clearer message and matches the pattern used by
            // toggleCharging / refresh / wake observer.
            let ok = self.runSMCWrite(.inhibit)
            DispatchQueue.main.async {
                if ok {
                    self.chargingPaused = true
                    NSLog("Ampere: Re-inhibited charging")
                    self.refresh()
                } else {
                    // Surface the failure so the user notices instead of
                    // silently observing charging continuing after they
                    // toggled charge-to-upper off.
                    self.lastError = "Failed to inhibit charging — revoke and re-grant admin access"
                }
                // On failure: don't refresh. The state-machine would just
                // re-dispatch the same inhibit and tight-loop. Next timer
                // tick will reconcile.
            }
        }
    }

    func toggleCharging() {
        let shouldPause = !chargingPaused
        if shouldPause {
            guard let state = state, state.adapterConnected else {
                lastError = Self.noAdapterError
                return
            }
        }

        // Ensure sudo helper is installed first (one-time admin prompt)
        ensureSudoInstalled { [weak self] ok in
            guard let self = self, ok else {
                self?.lastError = "Admin access required to control charging"
                return
            }
            self.smcQueue.async {
                let op: SMCWriteOp = shouldPause ? .inhibit : .allow
                let ok = self.runSMCWrite(op)
                DispatchQueue.main.async {
                    if ok {
                        self.chargingPaused = shouldPause
                        self.lastError = nil
                        NSLog("Ampere: Charging %@", shouldPause ? "paused" : "resumed")
                    } else {
                        self.lastError = "Charge control failed — revoke and re-grant admin access"
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        self.refresh()
                    }
                }
            }
        }
    }
}
