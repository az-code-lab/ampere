import Foundation
import AppKit
import IOKit.ps
import Shared

struct BatteryState {
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
    @Published var lastHealthCheckTime: Date?

    @Published var autoManageEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoManageEnabled, forKey: "autoManageEnabled")
        }
    }
    @Published var chargeLowerBound: Int {
        didSet { UserDefaults.standard.set(chargeLowerBound, forKey: "chargeLowerBound") }
    }
    @Published var chargeUpperBound: Int {
        didSet { UserDefaults.standard.set(chargeUpperBound, forKey: "chargeUpperBound") }
    }

    private var timer: Timer?
    private var terminationObserver: NSObjectProtocol?
    private var autoManageInFlight = false
    private var refreshCount = 0
    private let smcQueue = DispatchQueue(label: "com.battery-manager.smc", qos: .utility)

    private static let sudoersPath = AppConstants.sudoersPath
    private static let helperPath = AppConstants.helperPath

    init() {
        // Load persisted auto-manage settings
        let defaults = UserDefaults.standard
        self.autoManageEnabled = defaults.bool(forKey: "autoManageEnabled")
        self.autoDischargeEnabled = defaults.bool(forKey: "autoDischargeEnabled")
        self.chargeLowerBound = defaults.object(forKey: "chargeLowerBound") as? Int ?? 40
        self.chargeUpperBound = defaults.object(forKey: "chargeUpperBound") as? Int ?? 60

        // Always clear discharge (CHIE) and kill orphaned watchdogs on launch.
        // For CHTE: if auto-manage is enabled and charge is at or above the lower
        // bound, inhibit charging to prevent micro-charges between bounds after a
        // restart. Only allow charging when charge drops below the lower bound.
        chargingPaused = false
        if isSudoRuleInstalled {
            let shouldInhibit = autoManageEnabled
                && (Self.readBattery()?.percentage ?? 0) >= chargeLowerBound
            if shouldInhibit {
                chargingPaused = true
            }
            smcQueue.async { [weak self] in
                let okDischarge = self?.runSMCWriteViaSudo("nodischarge") ?? false
                let okChte = self?.runSMCWriteViaSudo(shouldInhibit ? "inhibit" : "allow") ?? false
                if okDischarge && okChte {
                    NSLog("BatteryManager: Launch cleanup done (inhibit=%d)", shouldInhibit)
                } else {
                    NSLog("BatteryManager: Launch cleanup failed (nodischarge=%d, chte=%d)", okDischarge, okChte)
                }
            }
        }

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            guard self.chargingPaused || self.activeDischarging else { return }

            let done = DispatchSemaphore(value: 0)
            self.smcQueue.async {
                // Always restore system defaults on quit
                if self.activeDischarging {
                    self.runSMCWrite("nodischarge")
                }
                if self.chargingPaused {
                    self.runSMCWrite("allow")
                }

                done.signal()
            }
            _ = done.wait(timeout: .now() + 6.0)
        }
    }

    deinit {
        timer?.invalidate()
        if let observer = terminationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Sudo Setup

    /// Check if the passwordless sudoers rule and helper binary are installed
    var isSudoRuleInstalled: Bool {
        FileManager.default.fileExists(atPath: Self.sudoersPath)
            && FileManager.default.fileExists(atPath: Self.helperPath)
    }

    /// Check if the installed helper is older than the bundled one
    private var isHelperStale: Bool {
        let fm = FileManager.default
        guard let installed = try? fm.attributesOfItem(atPath: Self.helperPath)[.modificationDate] as? Date,
              let bundled = try? fm.attributesOfItem(atPath: smcWriterPath)[.modificationDate] as? Date
        else { return false }
        return bundled > installed
    }

    /// Remove the sudoers rule and helper binary.
    /// If charging is paused, resumes charging via sudo BEFORE removing the rule.
    func removeSudoRule() {
        let wasPaused = self.chargingPaused
        let wasDischarging = self.activeDischarging
        smcQueue.async { [weak self] in
            guard let self = self else { return }

            let cmd = "rm -f '\(Self.sudoersPath)' '\(Self.helperPath)' /etc/sudoers.d/battery-manager"

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
            "rm -f /etc/sudoers.d/battery-manager",
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
            DispatchQueue.main.async { completion(ok) }
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
            NSLog("BatteryManager: discharge daemon started")
        }
        return ok
    }

    /// Stop discharge: clear CHIE, kill watchdog, and restore sleep via one-shot command.
    private func stopDischarge() {
        _ = runSMCWriteViaSudo("nodischarge")
        NSLog("BatteryManager: discharge stopped")
    }

    /// Run the SMCWriter helper via sudo (no password prompt).
    /// Requires the sudoers helper to be installed first via ensureSudoInstalled().
    @discardableResult
    private func runSMCWrite(_ arg: String) -> Bool {
        guard isSudoRuleInstalled else {
            NSLog("BatteryManager: sudo helper not installed, cannot write SMC")
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
            NSLog("BatteryManager: sudo failed: %@", errMsg)
            return false
        } catch {
            NSLog("BatteryManager: failed to run sudo: %@", error.localizedDescription)
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
        guard chie == 0 else { return false }
        if pauseButtonPaused {
            return chte == 1
        } else {
            return chte == 0
        }
    }

    /// Health check for auto mode.
    /// Returns true if SMC state is consistent with auto-manage settings.
    static func healthCheckAutoMode(
        chargeLevel: Int, lowerBound: Int, upperBound: Int,
        dischargeEnabled: Bool, chie: Int, chte: Int
    ) -> Bool {
        if dischargeEnabled {
            if chargeLevel > upperBound {
                return chte == 1 && chie == 8
            } else if chargeLevel >= lowerBound {
                // Between bounds (inclusive): chte can be 0 or 1, chie must be 0
                return chie == 0
            } else {
                return chte == 0 && chie == 0
            }
        } else {
            guard chie == 0 else { return false }
            if chargeLevel >= upperBound {
                return chte == 1
            } else if chargeLevel >= lowerBound {
                return true // chte can be 0 or 1
            } else {
                return chte == 0
            }
        }
    }

    // MARK: - Refresh

    func refresh() {
        refreshCount += 1
        var battery = Self.readBattery()

        // Always update state immediately so the UI has data
        state = battery

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
                        NSLog("BatteryManager: Auto-discharge toggled off")
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
                            NSLog("BatteryManager: Auto-discharge started at %d%%, target %d%%", b.percentage, self.chargeUpperBound)
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
                            NSLog("BatteryManager: Auto-discharge reached target %d%%", self.chargeUpperBound)
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
                            NSLog("BatteryManager: Inhibited charging at %d%%", b.percentage)
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
                            NSLog("BatteryManager: Charging from %d%% to %d%%", b.percentage, self.chargeUpperBound)
                        }
                        self.refresh()
                    }
                }
            }
        }

        if chargingPaused, let b = battery {
            if b.adapterConnected {
                // Clear stale time-to-full and ensure state reflects paused charging
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
            } else {
                // Adapter disconnected — clear inhibit/discharge so charging works when plugged back in
                chargingPaused = false
                activeDischarging = false
                chargeToUpperBound = false
                smcQueue.async { [weak self] in
                    self?.runSMCWrite("allow")
                    self?.runSMCWrite("nodischarge")
                }
            }
        }

        state = battery

        // Health check: verify SMC state matches expected state.
        // Skip during the first few cycles to allow initial cleanup to settle.
        if refreshCount > 3, !autoManageInFlight, isSudoRuleInstalled,
           let b = battery, b.adapterConnected {
            performHealthCheck(battery: b)
        } else {
            healthWarning = nil
        }
    }

    /// Format raw SMC bytes as hex string, e.g. "0x01 00 00 00".
    private static func formatHex(_ bytes: [UInt8]) -> String {
        "0x" + bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private func performHealthCheck(battery: BatteryState) {
        guard let chteBytes = Self.smcReadKey("CHTE"), chteBytes.count == 4,
              let chieBytes = Self.smcReadKey("CHIE"), chieBytes.count == 1 else {
            healthWarning = nil
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
        lastHealthCheckSMC = "CHTE=\(chteHex)\nCHIE=\(chieHex)"
        if healthy {
            lastHealthCheckStatus = "pass"
            healthWarning = nil
        } else {
            lastHealthCheckStatus = "FAIL"
            NSLog("BatteryManager: Health check failed — CHTE=%d CHIE=%d charge=%d%% paused=%d auto=%d discharge=%d bounds=[%d,%d]",
                  chte, chie, battery.percentage, chargingPaused, autoManageEnabled, autoDischargeEnabled,
                  chargeLowerBound, chargeUpperBound)
            healthWarning = "SMC state mismatch — try Revoke Admin Access, then re-grant"
        }
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
                        NSLog("BatteryManager: Charging %@", shouldPause ? "paused" : "resumed")
                    } else {
                        self.lastError = "Failed to change charging state"
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        self.refresh()
                    }
                }
            }
        }
    }
}
