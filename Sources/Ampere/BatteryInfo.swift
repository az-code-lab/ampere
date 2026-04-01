import Foundation
import AppKit
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
    let amperage: Int
    let voltage: Double
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
    @Published var chargeToUpperBound: Bool = false
    @Published var lastError: String?
    @Published var pinned: Bool = false
    @Published var healthWarning: String?
    @Published var lastHealthCheckStatus: String = "pending"
    @Published var lastHealthCheckSMC: String = ""
    @Published var lastHealthCheckExpected: String = ""
    @Published var lastHealthCheckCHTEMatch: Bool = true
    @Published var lastHealthCheckCHIEMatch: Bool = true
    @Published var lastHealthCheckTime: Date?
    @Published var updateAvailable: String?  // nil = no update, otherwise the new version string
    @Published var isPopoverVisible: Bool = false

    @Published var autoManageEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoManageEnabled, forKey: "autoManageEnabled")
        }
    }
    @Published var chargeLowerBound: Int {
        didSet {
            if chargeLowerBound < 0 { chargeLowerBound = 0 }
            else if chargeLowerBound >= chargeUpperBound { chargeLowerBound = chargeUpperBound - 5 }
            UserDefaults.standard.set(chargeLowerBound, forKey: "chargeLowerBound")
        }
    }
    @Published var chargeUpperBound: Int {
        didSet {
            if chargeUpperBound > 100 { chargeUpperBound = 100 }
            else if chargeUpperBound <= chargeLowerBound { chargeUpperBound = chargeLowerBound + 5 }
            UserDefaults.standard.set(chargeUpperBound, forKey: "chargeUpperBound")
        }
    }

    private var timer: Timer?
    private var updateCheckTimer: Timer?
    private var terminationObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var autoManageInFlight = false
    private var refreshCount = 0
    private let smcQueue = DispatchQueue(label: "com.ampere.smc", qos: .utility)

    private static let sudoersPath = AppConstants.sudoersPath
    private static let helperPath = AppConstants.helperPath

    init() {
        // Load persisted auto-manage settings
        let defaults = UserDefaults.standard
        self.autoManageEnabled = defaults.bool(forKey: "autoManageEnabled")
        self.autoDischargeEnabled = defaults.bool(forKey: "autoDischargeEnabled")
        var lower = defaults.object(forKey: "chargeLowerBound") as? Int ?? 40
        var upper = defaults.object(forKey: "chargeUpperBound") as? Int ?? 60
        if lower < 0 { lower = 0 }
        if upper > 100 { upper = 100 }
        if lower >= upper { lower = 40; upper = 60 }
        self.chargeLowerBound = lower
        self.chargeUpperBound = upper

        // Always clear discharge (CHIE) and kill orphaned watchdogs on launch.
        // For CHTE: if auto-manage is enabled and charge is at or above the lower
        // bound, inhibit charging to prevent micro-charges between bounds after a
        // restart. Only allow charging when charge drops below the lower bound.
        // If the helper was removed (e.g. brew uninstall), disable features that need it
        chargingPaused = false
        if !isSudoRuleInstalled {
            autoManageEnabled = false
            autoDischargeEnabled = false
            chargeToUpperBound = false
        }
        if isSudoRuleInstalled && isHelperStale {
            NSLog("Ampere: Helper is stale, re-installing…")
            if !installSudo() {
                NSLog("Ampere: Helper re-install failed or cancelled, quitting")
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Admin Access Required"
                    alert.informativeText = "Ampere needs to update its helper tool after an upgrade. Please relaunch and enter your admin password."
                    alert.alertStyle = .critical
                    alert.runModal()
                    NSApp.terminate(nil)
                }
                return
            }
        }
        if isSudoRuleInstalled {
            let shouldInhibit = autoManageEnabled
                && (Self.readBattery()?.percentage ?? 0) >= chargeLowerBound
            if shouldInhibit {
                chargingPaused = true
            }
            // Run cleanup synchronously before first refresh to prevent charging
            // from starting during the async window
            let okDischarge = runSMCWriteViaSudo("nodischarge")
            let okChte = runSMCWriteViaSudo(shouldInhibit ? "inhibit" : "allow")
            let pid = ProcessInfo.processInfo.processIdentifier
            _ = runSMCWriteViaSudo("spawn-watchdog:\(pid)")
            if okDischarge && okChte {
                NSLog("Ampere: Launch cleanup done (inhibit=%d)", shouldInhibit)
            } else {
                NSLog("Ampere: Launch cleanup failed (nodischarge=%d, chte=%d)", okDischarge, okChte)
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
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self, self.isSudoRuleInstalled else { return }
            NSLog("Ampere: System wake — re-asserting SMC state")
            self.smcQueue.async {
                if self.activeDischarging {
                    _ = self.startDischarge()
                } else if self.chargingPaused {
                    _ = self.runSMCWriteViaSudo("inhibit")
                }
                DispatchQueue.main.async {
                    self.refresh()
                }
            }
        }
    }

    deinit {
        timer?.invalidate()
        updateCheckTimer?.invalidate()
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
        updateCheckTimer = Timer.scheduledTimer(
            withTimeInterval: Double.random(in: 0 ..< 86400),
            repeats: false
        ) { [weak self] _ in
            self?.checkForUpdate()
            self?.scheduleNextUpdateCheck()
        }
    }

    private func checkForUpdate() {
        let task = URLSession.shared.dataTask(with: Self.caskURL) { [weak self] data, _, error in
            guard let self, error == nil,
                  let data, let content = String(data: data, encoding: .utf8) else { return }
            // Parse: version "X.Y.Z" from the cask file
            guard let range = content.range(of: #"version\s+"([^"]+)""#, options: .regularExpression),
                  let versionRange = content[range].range(of: #""([^"]+)""#, options: .regularExpression) else { return }
            let remote = String(content[versionRange]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let current = AppVersion.current.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            DispatchQueue.main.async {
                if Self.isNewerVersion(remote, than: current) {
                    self.updateAvailable = remote
                    NSLog("Ampere: Update available: %@ → %@", current, remote)
                } else {
                    self.updateAvailable = nil
                }
            }
        }
        task.resume()
    }

    /// Compare two dotted version strings (e.g. "0.0.18" > "0.0.17").
    private static func isNewerVersion(_ remote: String, than current: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let c = current.split(separator: ".").compactMap { Int($0) }
        for i in 0 ..< max(r.count, c.count) {
            let rv = i < r.count ? r[i] : 0
            let cv = i < c.count ? c[i] : 0
            if rv > cv { return true }
            if rv < cv { return false }
        }
        return false
    }

    // MARK: - Sudo Setup

    /// Check if the passwordless sudoers rule and helper binary are installed
    var isSudoRuleInstalled: Bool {
        FileManager.default.fileExists(atPath: Self.sudoersPath)
            && FileManager.default.fileExists(atPath: Self.helperPath)
    }

    /// Check if the installed helper differs from the bundled one
    private var isHelperStale: Bool {
        guard let installed = try? Data(contentsOf: URL(fileURLWithPath: Self.helperPath)),
              let bundled = try? Data(contentsOf: URL(fileURLWithPath: smcWriterPath))
        else { return false }
        return installed != bundled
    }

    /// Remove the sudoers rule and helper binary.
    /// If charging is paused, resumes charging via sudo BEFORE removing the rule.
    func removeSudoRule() {
        let wasPaused = self.chargingPaused
        let wasDischarging = self.activeDischarging
        smcQueue.async { [weak self] in
            guard let self = self else { return }

            let cmd = "rm -f '\(Self.sudoersPath)' '\(Self.helperPath)'"

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
                    self.recheckHealth()
                } else {
                    // User cancelled — restore previous state
                    self.smcQueue.async {
                        if wasPaused { self.runSMCWrite("inhibit") }
                        if wasDischarging { _ = self.startDischarge() }
                    }
                }
                self.objectWillChange.send()
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
        task.standardOutput = Pipe()
        task.standardError = Pipe()
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

    /// Install the SMCWriter binary at a root-owned fixed path, plus a sudoers rule.
    /// Shows the native macOS password dialog (one-time).
    private func installSudo() -> Bool {
        let user = NSUserName()
        let smcWriter = smcWriterPath
        let cmd = [
            "mkdir -p /usr/local/bin",
            "cp '\(smcWriter)' \(Self.helperPath)",
            "chmod 0755 \(Self.helperPath)",
            "chown root:wheel \(Self.helperPath)",
            "printf '%s' '\(user) ALL=(root) NOPASSWD: \(Self.helperPath)\n' > \(Self.sudoersPath)",
            "chmod 0440 \(Self.sudoersPath)",
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
    /// a watchdog so CHTE is still protected if the app is killed.
    private func stopDischarge() {
        _ = runSMCWriteViaSudo("nodischarge")
        _ = runSMCWriteViaSudo("spawn-watchdog:\(ProcessInfo.processInfo.processIdentifier)")
        NSLog("Ampere: discharge stopped")
    }

    /// Run the SMCWriter helper via sudo (no password prompt).
    /// Requires the sudoers helper to be installed first via ensureSudoInstalled().
    @discardableResult
    private func runSMCWrite(_ arg: String) -> Bool {
        guard isSudoRuleInstalled else {
            NSLog("Ampere: sudo helper not installed, cannot write SMC")
            return false
        }
        switch arg {
        case "discharge":
            return startDischarge()
        case "nodischarge":
            stopDischarge()
            return true
        default:
            return runSMCWriteViaSudo(arg)
        }
    }

    private func runSMCWriteViaSudo(_ arg: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        task.arguments = [Self.helperPath, arg]
        let errPipe = Pipe()
        task.standardInput = FileHandle.nullDevice
        task.standardError = errPipe
        task.standardOutput = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 { return true }
            let errMsg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            NSLog("Ampere: sudo failed: %@", errMsg)
            return false
        } catch {
            NSLog("Ampere: failed to run sudo: %@", error.localizedDescription)
            return false
        }
    }

    // MARK: - SMC Read (no root required)

    /// SMC struct layout — must match SMCWriter's SMCKeyData exactly.
    private struct SMCKeyData {
        struct Vers { var major: UInt8 = 0; var minor: UInt8 = 0; var build: UInt8 = 0; var reserved: UInt8 = 0; var release: UInt16 = 0 }
        struct PLimitData { var version: UInt16 = 0; var length: UInt16 = 0; var cpuPLimit: UInt32 = 0; var gpuPLimit: UInt32 = 0; var memPLimit: UInt32 = 0 }
        struct KeyInfo { var dataSize: UInt32 = 0; var dataType: UInt32 = 0; var dataAttributes: UInt8 = 0 }
        var key: UInt32 = 0
        var vers: Vers = Vers()
        var pLimitData: PLimitData = PLimitData()
        var keyInfo: KeyInfo = KeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0; var status: UInt8 = 0; var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                    UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                    UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                    UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8) =
            (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
    }

    private static func fourCharCode(_ str: String) -> UInt32 {
        var result: UInt32 = 0
        for char in str.utf8.prefix(4) { result = (result << 8) | UInt32(char) }
        return result
    }

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

        let smcKey = fourCharCode(key)
        let inputSize = MemoryLayout<SMCKeyData>.size
        var outputSize = MemoryLayout<SMCKeyData>.size

        // Step 1: get key info
        var input = SMCKeyData()
        var output = SMCKeyData()
        input.key = smcKey
        input.data8 = 9 // kSMCGetKeyInfo
        guard IOConnectCallStructMethod(conn, 2, &input, inputSize, &output, &outputSize) == kIOReturnSuccess else { return nil }

        let dataSize = output.keyInfo.dataSize
        guard dataSize > 0 && dataSize <= 32 else { return nil }

        // Step 2: read value
        input = SMCKeyData()
        input.key = smcKey
        input.keyInfo.dataSize = dataSize
        input.data8 = 5 // kSMCReadKey
        output = SMCKeyData()
        outputSize = MemoryLayout<SMCKeyData>.size
        guard IOConnectCallStructMethod(conn, 2, &input, inputSize, &output, &outputSize) == kIOReturnSuccess else { return nil }

        var raw = output.bytes
        return withUnsafeBytes(of: &raw) { Array($0.prefix(Int(dataSize))) }
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
            if activeDischarging && chargeLevel > upperBound {
                return chte == SMC.chteInhibitInt && chie == SMC.chieDischargeInt
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
                if activeDischarging && chargeLevel > upperBound {
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

    func refresh() {
        refreshCount += 1
        var battery = Self.readBattery()

        // Only publish to SwiftUI when popover is visible to avoid expensive layout passes
        if isPopoverVisible {
            state = battery
        } else if state == nil {
            // First refresh on launch — always publish so menu bar icon has data
            state = battery
        } else if let old = state, old.percentage != battery?.percentage || old.isCharging != battery?.isCharging {
            // Menu bar icon needs updating
            state = battery
        }

        // Stop discharge if the toggle was turned off or auto-manage was disabled
        if activeDischarging && (!autoDischargeEnabled || !autoManageEnabled) && !autoManageInFlight {
            autoManageInFlight = true
            smcQueue.async { [weak self] in
                guard let self = self else { return }
                let ok = self.runSMCWrite("nodischarge")
                DispatchQueue.main.async {
                    self.autoManageInFlight = false
                    if ok {
                        self.activeDischarging = false
                        NSLog("Ampere: Auto-discharge toggled off")
                    }
                    self.refresh()
                }
            }
            return
        }

        // Auto-discharge: start when above upper bound, stop when reached
        if autoManageEnabled, autoDischargeEnabled, !autoManageInFlight, let b = battery, b.adapterConnected {
            if !activeDischarging && b.percentage > chargeUpperBound {
                autoManageInFlight = true
                smcQueue.async { [weak self] in
                    guard let self = self else { return }
                    let ok = self.runSMCWrite("discharge")
                    DispatchQueue.main.async {
                        self.autoManageInFlight = false
                        if ok {
                            self.activeDischarging = true
                            NSLog("Ampere: Auto-discharge started at %d%%, target %d%%", b.percentage, self.chargeUpperBound)
                        }
                        self.refresh()
                    }
                }
                return
            } else if activeDischarging && b.percentage <= chargeUpperBound {
                autoManageInFlight = true
                smcQueue.async { [weak self] in
                    guard let self = self else { return }
                    let ok = self.runSMCWrite("nodischarge")
                    DispatchQueue.main.async {
                        self.autoManageInFlight = false
                        if ok {
                            self.activeDischarging = false
                            NSLog("Ampere: Auto-discharge reached target %d%%", self.chargeUpperBound)
                        }
                        self.refresh()
                    }
                }
                return
            }
        }

        if autoManageEnabled, !autoManageInFlight, let b = battery, b.adapterConnected {
            if lastError != nil { lastError = nil }

            if !chargingPaused && b.percentage >= chargeUpperBound {
                // At or above upper bound — inhibit charging and reset charge-to-upper toggle
                autoManageInFlight = true
                smcQueue.async { [weak self] in
                    guard let self = self else { return }
                    let ok = self.runSMCWrite("inhibit")
                    DispatchQueue.main.async {
                        self.autoManageInFlight = false
                        if ok {
                            self.chargingPaused = true
                            self.chargeToUpperBound = false
                            NSLog("Ampere: Inhibited charging at %d%%", b.percentage)
                        }
                        self.refresh()
                    }
                }
            } else if !chargingPaused && !chargeToUpperBound
                        && b.percentage >= chargeLowerBound && b.percentage < chargeUpperBound {
                // Between bounds without an explicit charge-to-upper request — inhibit.
                // This handles bounds being adjusted while charging is in progress.
                autoManageInFlight = true
                smcQueue.async { [weak self] in
                    guard let self = self else { return }
                    let ok = self.runSMCWrite("inhibit")
                    DispatchQueue.main.async {
                        self.autoManageInFlight = false
                        if ok {
                            self.chargingPaused = true
                            NSLog("Ampere: Inhibited charging at %d%% (between bounds)", b.percentage)
                        }
                        self.refresh()
                    }
                }
            } else if chargingPaused && (b.percentage < chargeLowerBound || chargeToUpperBound) {
                // Below lower bound or user explicitly requested charge to upper bound
                autoManageInFlight = true
                smcQueue.async { [weak self] in
                    guard let self = self else { return }
                    let ok = self.runSMCWrite("allow")
                    DispatchQueue.main.async {
                        self.autoManageInFlight = false
                        if ok {
                            self.chargingPaused = false
                            NSLog("Ampere: Charging from %d%% to %d%%", b.percentage, self.chargeUpperBound)
                        }
                        self.refresh()
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
                        batteryAgeYears: b.batteryAgeYears, batteryAgeDays: b.batteryAgeDays
                    )
                }
            } else if autoManageEnabled {
                // Auto-manage: keep CHTE/chargingPaused for micro-charge prevention
                // on reconnect. Only stop active discharge (no adapter = no discharge).
                if activeDischarging {
                    activeDischarging = false
                    smcQueue.async { [weak self] in
                        _ = self?.runSMCWriteViaSudo("nodischarge")
                        let pid = ProcessInfo.processInfo.processIdentifier
                        _ = self?.runSMCWriteViaSudo("spawn-watchdog:\(pid)")
                    }
                }
            } else {
                // Manual mode: clear inhibit/discharge so charging works when plugged back in
                chargingPaused = false
                activeDischarging = false
                chargeToUpperBound = false
                smcQueue.async { [weak self] in
                    self?.runSMCWrite("allow")
                    self?.runSMCWrite("nodischarge")
                }
            }
        }

        // Update state again if it was modified (e.g. cleared timeRemaining when paused)
        if isPopoverVisible, state != battery {
            state = battery
        }

        // Health check: verify SMC state matches expected state.
        // Skip first few cycles for cleanup to settle.
        if refreshCount > 3, !autoManageInFlight, isSudoRuleInstalled,
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
            // Cannot read SMC — preserve any existing warning rather than clearing it
            return
        }

        let chte = chteBytes.withUnsafeBytes { Int($0.load(as: UInt32.self)) }
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
        lastHealthCheckTime = Date()
        lastHealthCheckSMC = "\(SMC.keyChargeTerminate)=\(chteHex)\n\(SMC.keyChargeInhibit)=\(chieHex)"
        if healthy {
            lastHealthCheckStatus = "pass"
            lastHealthCheckExpected = ""
            lastHealthCheckCHTEMatch = true
            lastHealthCheckCHIEMatch = true
            healthWarning = nil
        } else {
            lastHealthCheckStatus = "FAIL"
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
            lastHealthCheckExpected = "\(SMC.keyChargeTerminate)=\(expected.chte)\n\(SMC.keyChargeInhibit)=\(expected.chie)"
            lastHealthCheckCHTEMatch = chteHex == expected.chte || expected.chte == SMC.chteEitherHex
            lastHealthCheckCHIEMatch = chieHex == expected.chie
            NSLog("Ampere: Health check failed — CHTE=%d CHIE=%d charge=%d%% paused=%d auto=%d discharge=%d bounds=[%d,%d]",
                  chte, chie, battery.percentage, chargingPaused, autoManageEnabled, autoDischargeEnabled,
                  chargeLowerBound, chargeUpperBound)
            healthWarning = "SMC mismatch — revoke & re-grant admin"
        }
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
        var amperage = 0
        var voltage = 0.0
        var temperature = 0.0

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
            if let val = IORegistryEntryCreateCFProperty(service, "Amperage" as CFString, nil, 0)?.takeRetainedValue() as? Int {
                amperage = val
            }
            if let val = IORegistryEntryCreateCFProperty(service, "Voltage" as CFString, nil, 0)?.takeRetainedValue() as? Int {
                voltage = Double(val) / 1000.0
            }
            if let val = IORegistryEntryCreateCFProperty(service, "Temperature" as CFString, nil, 0)?.takeRetainedValue() as? Int {
                temperature = Double(val) / 100.0
            }
        }

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
            batteryAgeYears: batteryAgeYears,
            batteryAgeDays: batteryAgeDays
        )
    }

    // MARK: - Toggle

    /// Re-inhibit charging (e.g. when user toggles off "Charge to Upper Bound" mid-charge).
    func inhibitCharging() {
        guard !chargingPaused else { return }
        smcQueue.async { [weak self] in
            guard let self = self else { return }
            let ok = self.runSMCWriteViaSudo("inhibit")
            DispatchQueue.main.async {
                if ok {
                    self.chargingPaused = true
                    NSLog("Ampere: Re-inhibited charging")
                }
                self.refresh()
            }
        }
    }

    func toggleCharging() {
        let shouldPause = !chargingPaused
        if shouldPause {
            guard let state = state, state.adapterConnected else {
                lastError = "No power adapter connected"
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
                let arg = shouldPause ? "inhibit" : "allow"
                let ok = self.runSMCWrite(arg)
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
