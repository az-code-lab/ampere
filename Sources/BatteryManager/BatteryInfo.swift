import Foundation
import AppKit
import IOKit.ps

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
    @Published var lastError: String?
    @Published var pinned: Bool = false

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
    private let smcQueue = DispatchQueue(label: "com.battery-manager.smc", qos: .utility)

    private static let pausedFlagPath = NSTemporaryDirectory() + ".battery_manager_paused"
    private static let sudoersPath = "/etc/sudoers.d/az-battery-manager"
    private static let helperPath = "/usr/local/bin/az-battery-manager-smc"

    init() {
        // Load persisted auto-manage settings
        let defaults = UserDefaults.standard
        self.autoManageEnabled = defaults.bool(forKey: "autoManageEnabled")
        self.chargeLowerBound = defaults.object(forKey: "chargeLowerBound") as? Int ?? 40
        self.chargeUpperBound = defaults.object(forKey: "chargeUpperBound") as? Int ?? 60

        let wasPaused = FileManager.default.fileExists(atPath: Self.pausedFlagPath)

        if wasPaused && autoManageEnabled {
            // Auto-manage is on — restore paused state so it can resume control
            chargingPaused = true
            NSLog("BatteryManager: Restored charge inhibit for auto-manage")
        } else {
            // Always clear CHTE on launch when not intentionally paused.
            // The paused flag lives in the temp directory and gets cleaned on reboot,
            // but CHTE persists in the SMC — so we must proactively clear it.
            chargingPaused = false
            try? FileManager.default.removeItem(atPath: Self.pausedFlagPath)
            smcQueue.async { [weak self] in
                self?.runSMCWrite("allow")
                NSLog("BatteryManager: Cleared CHTE on launch")
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
            guard let self = self, self.chargingPaused else { return }
            if self.autoManageEnabled {
                // Auto-manage is on — keep CHTE set so charging stays inhibited
                // between app quit and restart. The paused flag stays too, so
                // init() will restore the state on next launch.
                return
            }
            // Manual pause — clear CHTE so we don't leave charging stuck
            let done = DispatchSemaphore(value: 0)
            self.smcQueue.async {
                self.runSMCWrite("allow")
                try? FileManager.default.removeItem(atPath: Self.pausedFlagPath)
                done.signal()
            }
            _ = done.wait(timeout: .now() + 3.0)
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

    /// Remove the sudoers rule and helper binary.
    /// If charging is paused, resumes charging via sudo BEFORE removing the rule.
    func removeSudoRule() {
        let wasPaused = self.chargingPaused
        smcQueue.async { [weak self] in
            guard let self = self else { return }

            let cmd = "rm -f '\(Self.sudoersPath)' '\(Self.helperPath)' /etc/sudoers.d/battery-manager"

            // Resume charging BEFORE removing the helper (need sudo access)
            if wasPaused { self.runSMCWrite("allow") }

            let ok = self.runAsAdmin(cmd)

            DispatchQueue.main.async {
                if ok && !self.isSudoRuleInstalled {
                    self.autoManageEnabled = false
                    self.chargingPaused = false
                    try? FileManager.default.removeItem(atPath: Self.pausedFlagPath)
                } else if wasPaused {
                    // User cancelled — re-inhibit since we cleared it
                    self.smcQueue.async { self.runSMCWrite("inhibit") }
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
        if isSudoRuleInstalled {
            completion(true)
            return
        }
        smcQueue.async { [weak self] in
            let ok = self?.installSudo() ?? false
            DispatchQueue.main.async { completion(ok) }
        }
    }

    // MARK: - SMC Write

    /// Run the SMCWriter helper via sudo (no password prompt).
    /// Requires the sudoers helper to be installed first via ensureSudoInstalled().
    @discardableResult
    private func runSMCWrite(_ arg: String) -> Bool {
        guard isSudoRuleInstalled else {
            NSLog("BatteryManager: sudo helper not installed, cannot write SMC")
            return false
        }
        return runSMCWriteViaSudo(arg)
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

    // MARK: - Refresh

    func refresh() {
        var battery = Self.readBattery()

        // Auto charge management:
        //   1. charge when < lower bound, continue until upper bound
        //   2. hold when between bounds (inhibit charging)
        //   3. above upper bound → inhibit charging (battery drains passively under load)
        if autoManageEnabled, !autoManageInFlight, let b = battery, b.adapterConnected {
            if lastError != nil { lastError = nil }

            if !chargingPaused && b.percentage >= chargeUpperBound {
                // At or above upper bound — inhibit charging
                autoManageInFlight = true
                smcQueue.async { [weak self] in
                    guard let self = self else { return }
                    let ok = self.runSMCWrite("inhibit")
                    DispatchQueue.main.async {
                        self.autoManageInFlight = false
                        if ok {
                            self.chargingPaused = true
                            FileManager.default.createFile(atPath: Self.pausedFlagPath, contents: nil)
                            NSLog("BatteryManager: Inhibited charging at %d%%", b.percentage)
                        }
                        self.refresh()
                    }
                }
            } else if chargingPaused && b.percentage < chargeLowerBound {
                // Below lower bound — start charging (will continue to upper bound)
                autoManageInFlight = true
                smcQueue.async { [weak self] in
                    guard let self = self else { return }
                    let ok = self.runSMCWrite("allow")
                    DispatchQueue.main.async {
                        self.autoManageInFlight = false
                        if ok {
                            self.chargingPaused = false
                            try? FileManager.default.removeItem(atPath: Self.pausedFlagPath)
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
                // Adapter disconnected — clear inhibit so charging works when plugged back in
                chargingPaused = false
                try? FileManager.default.removeItem(atPath: Self.pausedFlagPath)
                smcQueue.async { [weak self] in self?.runSMCWrite("allow") }
            }
        }

        state = battery
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
                        if shouldPause {
                            FileManager.default.createFile(atPath: Self.pausedFlagPath, contents: nil)
                        } else {
                            try? FileManager.default.removeItem(atPath: Self.pausedFlagPath)
                        }
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
