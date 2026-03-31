import SwiftUI
import AppKit
import Combine
import ServiceManagement

// MARK: - Menu Bar App

struct AmpereApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let monitor = BatteryMonitor()
    private var pinnedObserver: Any?
    private var stateObserver: Any?
    private var mouseMonitor: Any?
    private var globalMouseMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Activation policy is set in main.swift before SwiftUI launches,
        // so we don't need to change it here (avoids external monitor blackout).

        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            updateMenuBarIcon()
            button.action = #selector(togglePopover)
            button.target = self
        }

        // Create popover with the battery panel
        popover = NSPopover()
        popover.contentSize = NSSize(width: 340, height: 620)
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: ContentView(monitor: monitor)
        )

        // Observe pinned state to change popover behavior
        pinnedObserver = monitor.$pinned.sink { [weak self] pinned in
            self?.popover.behavior = pinned ? .applicationDefined : .transient
        }

        // Update menu bar icon whenever monitor state changes
        stateObserver = monitor.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateMenuBarIcon()
            }
        }

        // Reactivate app on any mouse click in our windows — fixes focus loss
        // for .accessory apps where clicking the popover doesn't auto-activate.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            if !NSApp.isActive {
                NSApp.activate(ignoringOtherApps: true)
            }
            return event
        }

        // Dismiss popover on clicks outside the app — .transient behavior is
        // unreliable for .accessory apps (clicks on desktop/other apps can be missed).
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.popover.isShown, self.popover.behavior == .transient else { return }
            self.popover.performClose(nil)
        }
    }

    private var lastIconPct: Int = -1
    private var lastIconCharging: Bool = false
    private var lastIconWarning: Bool = false

    private func updateMenuBarIcon() {
        guard let button = statusItem.button else { return }
        let pct = monitor.state?.percentage ?? 0
        let isCharging = monitor.state?.isCharging ?? false
        let hasWarning = monitor.healthWarning != nil

        // Skip redraw if nothing visible changed
        guard pct != lastIconPct || isCharging != lastIconCharging || hasWarning != lastIconWarning else { return }
        lastIconPct = pct
        lastIconCharging = isCharging
        lastIconWarning = hasWarning

        button.image = buildMenuBarIcon(
            percentage: CGFloat(pct),
            isCharging: isCharging,
            hasWarning: hasWarning
        )
        let titleAttrs: [NSAttributedString.Key: Any] = hasWarning
            ? [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
               .foregroundColor: NSColor.systemOrange]
            : [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)]
        button.attributedTitle = NSAttributedString(string: " \(pct)%", attributes: titleAttrs)
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            monitor.setFastPolling(true)
            updateMenuBarIcon()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func popoverShouldDetach(_ popover: NSPopover) -> Bool {
        true
    }

    func popoverDidDetach(_ popover: NSPopover) {
        monitor.pinned = true
    }

    func popoverDidClose(_ notification: Notification) {
        // popoverDidClose also fires during detach (popover → window transition).
        // Skip cleanup in that case — the user is still viewing the panel.
        guard !popover.isDetached else { return }
        monitor.pinned = false
        monitor.setFastPolling(false)
    }

    deinit {
        (pinnedObserver as? AnyCancellable)?.cancel()
        (stateObserver as? AnyCancellable)?.cancel()
        if let mouseMonitor = mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
        }
        if let globalMouseMonitor = globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
        }
    }

    private func buildMenuBarIcon(percentage: CGFloat, isCharging: Bool, hasWarning: Bool = false) -> NSImage {
        let battW: CGFloat = 24
        let battH: CGFloat = 11
        let capW: CGFloat = 2.8
        let totalW = battW + capW + 1
        let totalH: CGFloat = 17

        let image = NSImage(size: NSSize(width: totalW, height: totalH))
        image.lockFocus()

        let color: NSColor = hasWarning ? .systemOrange : .black
        let battY = (totalH - battH) / 2

        // Battery outline
        let bodyRect = NSRect(x: 0.5, y: battY + 0.5, width: battW - 1, height: battH - 1)
        let path = NSBezierPath(roundedRect: bodyRect, xRadius: 2, yRadius: 2)
        color.withAlphaComponent(0.7).setStroke()
        path.lineWidth = 1.2
        path.stroke()

        // Battery cap
        let capRect = NSRect(x: battW, y: battY + battH * 0.3, width: capW, height: battH * 0.4)
        color.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: capRect, xRadius: 0.8, yRadius: 0.8).fill()

        // Fill level
        let inset: CGFloat = 2
        let fillMaxW = battW - 1 - inset * 2
        let fillW = max(0, fillMaxW * percentage / 100)
        let fillRect = NSRect(x: 0.5 + inset, y: battY + 0.5 + inset,
                              width: fillW, height: battH - 1 - inset * 2)
        color.setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: 1, yRadius: 1).fill()

        // Overlay bolt SF Symbol when charging
        if isCharging,
           let symbol = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .black)
            let configured = symbol.withSymbolConfiguration(config) ?? symbol
            let symSize = configured.size
            let symX = (battW - symSize.width) / 2
            let symY = (totalH - symSize.height) / 2

            // Erase area behind symbol
            NSGraphicsContext.current?.compositingOperation = .copy
            NSColor.clear.setFill()
            NSBezierPath(ovalIn: NSRect(x: symX, y: symY,
                                         width: symSize.width, height: symSize.height)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver

            // Draw the symbol in black
            // Need to tint it black since it's a template
            let tinted = NSImage(size: symSize)
            tinted.lockFocus()
            color.set()
            NSRect(origin: .zero, size: symSize).fill()
            configured.draw(in: NSRect(origin: .zero, size: symSize),
                           from: .zero, operation: .destinationIn, fraction: 1.0)
            tinted.unlockFocus()

            tinted.draw(in: NSRect(x: symX, y: symY, width: symSize.width, height: symSize.height))
        }

        image.unlockFocus()
        image.isTemplate = !hasWarning
        return image
    }
}

// MARK: - Content View

struct ContentView: View {
    @ObservedObject var monitor: BatteryMonitor
    @State private var useFahrenheit = true
    @State private var showAbout = false
    @State private var healthShowPercent = true
    @State private var ageShowYears = true
    @State private var amperageShowMA = true
    @State private var capacityShowMAh = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var healthCheckTimeString: String {
        guard let time = monitor.lastHealthCheckTime else { return "n/a" }
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm:ss a M/d/yyyy"
        return fmt.string(from: time)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let state = monitor.state {
                batteryView(state)
            } else {
                noBatteryView
            }
        }
        .frame(width: 340)
        .background(Color(.windowBackgroundColor))
    }

    // MARK: - Battery View

    private func batteryView(_ state: BatteryState) -> some View {
        VStack(spacing: 16) {
            // App name centered, pin button top-right
            ZStack {
                Text("Ampere \(AppVersion.current)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                HStack {
                    Spacer()
                    Button(action: { monitor.pinned.toggle() }) {
                        Image(systemName: monitor.pinned ? "pin.fill" : "pin")
                            .font(.system(size: 12))
                            .foregroundColor(monitor.pinned ? .accentColor : .secondary)
                            .rotationEffect(.degrees(monitor.pinned ? 0 : 45))
                    }
                    .buttonStyle(.plain)
                    .help(monitor.pinned ? "Unpin panel" : "Pin panel open")
                }
            }
            .padding(.top, -8)
            .padding(.trailing, 12)

            // Header with battery icon
            batteryHeader(state)

            Divider().padding(.horizontal)

            // Status grid
            statusGrid(state)

            if !monitor.autoManageEnabled && state.adapterConnected {
                Divider().padding(.horizontal)

                // Charge control: pause/discharge/resume
                chargeControlSection()
            }

            if monitor.autoManageEnabled {
                Divider().padding(.horizontal)

                // Auto charge management content (slider + discharge toggle)
                autoManageContent(state)
            }

            Divider().padding(.horizontal).padding(.top, 8)

            // Auto charge management toggle
            autoManageToggle()

            // Launch at login
            HStack {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(launchAtLogin ? .accentColor : .secondary)
                Text("Launch at Login")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Toggle("", isOn: $launchAtLogin)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: launchAtLogin) {
                        setLaunchAtLogin(launchAtLogin)
                    }
            }
            .padding(.horizontal, 16)

            Divider().padding(.horizontal).padding(.top, 8)

            // Footer actions
            HStack(spacing: 12) {
                if monitor.isSudoRuleInstalled {
                    Button("Revoke Admin Access") {
                        monitor.removeSudoRule()
                    }
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .buttonStyle(.plain)
                }
                Spacer()
                if let newVersion = monitor.updateAvailable {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                        .help("Update available: \(AppVersion.current) → \(newVersion)")
                }
                Button("About") {
                    showAbout = true
                }
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .buttonStyle(.plain)
                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .sheet(isPresented: $showAbout) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Ampere \(AppVersion.current)")
                        .font(.headline)
                    Text("Battery status monitor and charge controller for Apple Silicon Macs.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Divider()
                    HStack(spacing: 4) {
                        Text("Health check:")
                            .font(.system(size: 12))
                        Text(monitor.lastHealthCheckStatus)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(monitor.lastHealthCheckStatus == "pass" ? .green
                                : monitor.lastHealthCheckStatus == "FAIL" ? .red : .primary)
                    }
                    if monitor.lastHealthCheckStatus == "FAIL" {
                        let expectedLines = monitor.lastHealthCheckExpected.split(separator: "\n", omittingEmptySubsequences: false)
                        let actualLines = monitor.lastHealthCheckSMC.split(separator: "\n", omittingEmptySubsequences: false)
                        // Show matched keys in gray, only show expected vs actual for mismatched keys
                        if monitor.lastHealthCheckCHTEMatch {
                            Text(String(actualLines.first ?? ""))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.secondary)
                        } else {
                            healthCheckMismatch(
                                expectedValue: String(expectedLines.first ?? ""),
                                actualValue: String(actualLines.first ?? ""))
                        }
                        if monitor.lastHealthCheckCHIEMatch {
                            Text(String(actualLines.count > 1 ? actualLines[1] : ""))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.secondary)
                        } else {
                            healthCheckMismatch(
                                expectedValue: String(expectedLines.count > 1 ? expectedLines[1] : ""),
                                actualValue: String(actualLines.count > 1 ? actualLines[1] : ""))
                        }
                    } else {
                        Text(monitor.lastHealthCheckSMC)
                            .font(.system(size: 12, design: .monospaced))
                    }
                    Text("Checked at: \(healthCheckTimeString)")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Divider()
                    Text("Requires admin privileges for charge control.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    HStack {
                        Spacer()
                        Button("OK") { showAbout = false }
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .textSelection(.enabled)
                .padding(20)
                .frame(width: 300)
            }
        }
        .padding(.vertical, 20)
    }

    private func batteryMode(_ state: BatteryState) -> BatteryMode {
        if state.isCharging { return .charging }
        if monitor.activeDischarging { return .discharging }
        if state.adapterConnected { return .onACNotCharging }
        return .onBattery
    }

    private func batteryIcon(_ state: BatteryState) -> StaticBatteryBody {
        StaticBatteryBody(
            percentage: Double(state.percentage),
            mode: batteryMode(state),
            animate: monitor.isPopoverVisible
        )
    }

    private func batteryHeader(_ state: BatteryState) -> some View {
        VStack(spacing: 8) {
            VStack(spacing: 12) {
                batteryIcon(state)
                    .frame(width: 100, height: 48)

                Text("\(state.percentage)%")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
            }

            // Charging status label + time remaining
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor(state))
                    .frame(width: 8, height: 8)

                Text(state.timeRemaining.isEmpty
                    ? statusText(state)
                    : "\(statusText(state)) — \(state.timeRemaining)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
            }

            // Status message (fixed height to prevent layout jumps)
            Text(statusMessage(state))
                .font(.system(size: 12))
                .foregroundColor(statusMessageColor(state))
                .textSelection(.enabled)
                .frame(height: 14)
        }
    }

    private func statusMessage(_ state: BatteryState) -> String {
        if let error = monitor.lastError { return error }
        if let warning = monitor.healthWarning { return warning }
        if monitor.activeDischarging {
            return "Discharging to \(monitor.chargeUpperBound)% — sleep is temporarily disabled"
        }
        if monitor.autoManageEnabled && monitor.chargingPaused {
            if state.percentage > monitor.chargeUpperBound {
                return "Auto: not charging — drains to \(monitor.chargeUpperBound)% under load"
            }
            return "Auto: holding — charges below \(monitor.chargeLowerBound)% or on demand"
        }
        if monitor.autoManageEnabled && state.isCharging {
            return "Auto: charging to \(monitor.chargeUpperBound)%"
        }
        if monitor.chargingPaused { return "Running on AC power - battery will not charge" }
        if !state.adapterConnected { return "Connect power adapter to control charging" }
        return ""
    }

    private func statusMessageColor(_ state: BatteryState) -> Color {
        if monitor.lastError != nil { return .red }
        if monitor.healthWarning != nil { return .red }
        if monitor.activeDischarging { return .orange }
        if monitor.chargingPaused { return .blue }
        return .secondary
    }

    private func statusGrid(_ state: BatteryState) -> some View {
        let tempValue: String
        if useFahrenheit {
            let f = state.temperature * 9.0 / 5.0 + 32.0
            tempValue = String(format: "%.1f\u{00B0}F", f)
        } else {
            tempValue = String(format: "%.1f\u{00B0}C", state.temperature)
        }

        let watts = state.voltage * Double(state.amperage) / 1000.0
        let healthValue = healthShowPercent ? state.health : "\(state.maxCapacity)/\(state.designCapacity) mAh"

        let mode = batteryMode(state)
        let tint: Color = mode == .charging ? .green : (mode == .onBattery || mode == .discharging) ? .orange : .secondary

        return LazyVGrid(columns: [
            GridItem(.flexible()),
            GridItem(.flexible()),
        ], spacing: 12) {
            // Row 1: Lifetime
            StatCard(title: "Cycle Count", value: "\(state.cycleCount)", icon: "arrow.triangle.2.circlepath", iconColor: tint)
            StatCard(title: "Battery Served",
                value: ageShowYears
                    ? (state.batteryAgeYears.isEmpty ? "—" : state.batteryAgeYears)
                    : (state.batteryAgeDays.isEmpty ? "—" : state.batteryAgeDays),
                icon: "calendar.badge.clock", iconColor: tint, onTap: {
                    ageShowYears.toggle()
                })

            // Row 2: Capacity & Health
            StatCard(title: "Capacity",
                value: capacityShowMAh
                    ? "\(state.currentCapacity)/\(state.maxCapacity) mAh"
                    : (state.maxCapacity > 0
                        ? String(format: "%.1f%%", Double(state.currentCapacity) / Double(state.maxCapacity) * 100)
                        : "\(state.percentage)%"),
                icon: "battery.100", iconColor: tint, onTap: {
                    capacityShowMAh.toggle()
                })
            StatCard(title: "Health", value: healthValue, icon: "stethoscope", iconColor: tint, onTap: {
                healthShowPercent.toggle()
            })

            // Row 3: Electrical
            StatCard(title: "Voltage", value: String(format: "%.2f V", state.voltage), icon: "bolt.fill", iconColor: tint)
            StatCard(title: "Amperage",
                value: amperageShowMA ? "\(state.amperage) mA" : String(format: "%.2f A", Double(state.amperage) / 1000.0),
                icon: "alternatingcurrent", iconColor: tint, onTap: {
                    amperageShowMA.toggle()
                })

            // Row 4: Power & Temperature
            StatCard(title: "Wattage", value: String(format: "%.1f W", watts), icon: "bolt.horizontal.fill", iconColor: tint)
            StatCard(title: "Temperature", value: tempValue, icon: "thermometer.medium", iconColor: tint, onTap: {
                useFahrenheit.toggle()
            })
        }
        .padding(.horizontal, 16)
    }

    private func autoManageToggle() -> some View {
        HStack {
            Image(systemName: "arrow.up.arrow.down.circle.fill")
                .font(.system(size: 14))
                .foregroundColor(monitor.autoManageEnabled ? .accentColor : .secondary)
            Text("Auto Charge Management")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Toggle("", isOn: Binding(
                get: { monitor.autoManageEnabled },
                set: { newValue in
                    if newValue {
                        // Set immediately so the toggle doesn't flicker
                        monitor.autoManageEnabled = true
                        monitor.ensureSudoInstalled { ok in
                            if !ok {
                                monitor.autoManageEnabled = false
                                monitor.lastError = "Admin access required for auto charge management"
                            }
                        }
                    } else {
                        monitor.autoManageEnabled = false
                        if monitor.chargingPaused {
                            monitor.toggleCharging()
                        }
                    }
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
    }

    private func autoManageContent(_ state: BatteryState) -> some View {
        VStack(spacing: 10) {
            BatteryRangeSlider(
                lower: Binding(
                    get: { Double(monitor.chargeLowerBound) },
                    set: { monitor.chargeLowerBound = Int($0) }
                ),
                upper: Binding(
                    get: { Double(monitor.chargeUpperBound) },
                    set: { monitor.chargeUpperBound = Int($0) }
                ),
                currentLevel: Double(state.percentage),
                step: 5,
                minGap: 5
            )
            .frame(height: 68)
            .padding(.top, 2)
            .background(WindowDragBlocker())

            if state.percentage > monitor.chargeUpperBound {
                HStack {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 14))
                        .foregroundColor(monitor.autoDischargeEnabled ? .accentColor : .secondary)
                    Text("Discharge to Upper Bound")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { monitor.autoDischargeEnabled },
                        set: { newValue in
                            monitor.autoDischargeEnabled = newValue
                        }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
            } else {
                HStack {
                    Image(systemName: "arrow.up.to.line")
                        .font(.system(size: 14))
                        .foregroundColor(monitor.chargeToUpperBound ? .accentColor : .secondary)
                    Text("Charge to Upper Bound")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { monitor.chargeToUpperBound },
                        set: { newValue in
                            monitor.chargeToUpperBound = newValue
                        }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
            }

        }
        .padding(.horizontal, 16)
    }

    private func chargeControlSection() -> some View {
        VStack(spacing: 4) {
            if monitor.chargingPaused {
                Button(action: { monitor.toggleCharging() }) {
                    Label("Resume Charging", systemImage: "play.fill")
                }
                .buttonStyle(ChargeButtonStyle(color: .green))
            } else {
                Button(action: { monitor.toggleCharging() }) {
                    Label("Pause Charging", systemImage: "pause.fill")
                }
                .buttonStyle(ChargeButtonStyle(color: .orange))
            }
        }
        .padding(.horizontal, 16)
    }

    /// Shows expected (green) vs actual (red) for a mismatched SMC key,
    /// with the key= prefix aligned using monospaced font throughout.
    private func healthCheckMismatch(expectedValue: String, actualValue: String) -> some View {
        // e.g. expectedValue = "CHTE=0x01 00 00 00", actualValue = "CHTE=0x00 00 00 00"
        // Extract the key name (everything before '=') to build aligned lines
        let key = expectedValue.split(separator: "=", maxSplits: 1).first.map(String.init) ?? ""
        let expVal = expectedValue.split(separator: "=", maxSplits: 1).dropFirst().first.map(String.init) ?? expectedValue
        let actVal = actualValue.split(separator: "=", maxSplits: 1).dropFirst().first.map(String.init) ?? actualValue
        return VStack(alignment: .leading, spacing: 2) {
            Text("expected \(key)=\(expVal)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.green)
            Text("actual   \(key)=\(actVal)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.red)
        }
    }

    // MARK: - No Battery

    private var noBatteryView: some View {
        VStack(spacing: 12) {
            Image(systemName: "battery.0")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("No Battery Detected")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("This Mac may not have a battery,\nor battery info is unavailable.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Helpers

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Ampere: Failed to \(enabled ? "enable" : "disable") launch at login: %@", error.localizedDescription)
            // Revert toggle on failure
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func statusColor(_ state: BatteryState) -> Color {
        if state.isCharging { return .green }
        if monitor.activeDischarging { return .orange }
        if state.adapterConnected { return .blue }
        if state.percentage <= 15 { return .red }
        return .secondary
    }

    private func statusText(_ state: BatteryState) -> String {
        if monitor.activeDischarging { return "Discharging" }
        if monitor.chargingPaused && state.adapterConnected { return "On AC Power (Not Charging)" }
        if state.isCharging { return "Charging" }
        if state.adapterConnected { return "On AC Power" }
        return "On Battery"
    }
}

// MARK: - Battery Shape

enum BatteryMode {
    case charging
    case discharging
    case onACNotCharging
    case onBattery
}

private struct StaticBatteryBody: View {
    let percentage: Double
    let mode: BatteryMode
    var animate: Bool = false

    @State private var shimmerPhase: CGFloat = 0

    private var fillColor: Color {
        if percentage <= 15 { return .red }
        if percentage <= 30 { return .orange }
        return .green
    }

    private var iconName: String {
        switch mode {
        case .charging: return "bolt.fill"
        case .discharging, .onBattery: return "bolt.slash"
        case .onACNotCharging: return "powerplug.fill"
        }
    }

    private var shouldAnimate: Bool {
        animate && (mode == .charging || mode == .discharging)
    }

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.primary.opacity(0.4), lineWidth: 2)

                // Battery fill
                GeometryReader { geo in
                    let inset: CGFloat = 3
                    let totalWidth = geo.size.width - inset * 2
                    let fillWidth = totalWidth * percentage / 100
                    let fillHeight = geo.size.height - inset * 2

                    ZStack {
                        // Base color
                        RoundedRectangle(cornerRadius: 3.5)
                            .fill(fillColor)
                            .frame(width: fillWidth, height: fillHeight)

                        // Animated shimmer overlay
                        if shouldAnimate {
                            // A wide gradient strip that slides across
                            let shimmerWidth = fillWidth * 2
                            LinearGradient(
                                colors: [
                                    .clear,
                                    .white.opacity(0.3),
                                    .white.opacity(0.5),
                                    .white.opacity(0.3),
                                    .clear
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: shimmerWidth * 0.5, height: fillHeight)
                            .offset(x: shimmerPhase * fillWidth)
                            .frame(width: fillWidth, height: fillHeight)
                            .clipShape(RoundedRectangle(cornerRadius: 3.5))
                        }
                    }
                    .offset(x: inset, y: inset)
                    .frame(width: fillWidth, height: fillHeight, alignment: .leading)
                }

                Image(systemName: iconName)
                    .font(.system(size: mode == .onACNotCharging ? 14 : 18,
                                  weight: mode == .onACNotCharging ? .medium : .bold))
                    .foregroundColor(.white)
                    .opacity(0.8)
            }

            RoundedRectangle(cornerRadius: 2)
                .fill(Color.primary.opacity(0.4))
                .frame(width: 5, height: 16)
                .padding(.leading, -1)
        }
        .onChange(of: shouldAnimate) {
            if shouldAnimate {
                startAnimation()
            } else {
                withAnimation(.default) { shimmerPhase = 0 }
            }
        }
        .onAppear {
            if shouldAnimate {
                startAnimation()
            }
        }
    }

    private func startAnimation() {
        // Charging: shimmer flows left → right
        // Discharging: shimmer flows right → left
        let from: CGFloat = mode == .charging ? -1.0 : 1.0
        let to: CGFloat = mode == .charging ? 1.0 : -1.0
        shimmerPhase = from
        withAnimation(
            .linear(duration: 5.0)
            .repeatForever(autoreverses: false)
        ) {
            shimmerPhase = to
        }
    }
}

// MARK: - Battery Range Slider

struct BatteryRangeSlider: View {
    @Binding var lower: Double
    @Binding var upper: Double
    let currentLevel: Double
    var step: Double = 5
    var minGap: Double = 5

    private let batteryHeight: CGFloat = 28
    private let capWidth: CGFloat = 5
    private let cornerRadius: CGFloat = 6
    private let inset: CGFloat = 3
    private let markerWidth: CGFloat = 20

    private func fraction(_ value: Double) -> CGFloat {
        CGFloat(value / 100.0)
    }

    private func snap(_ value: Double) -> Double {
        (value / step).rounded() * step
    }

    var body: some View {
        GeometryReader { geo in
            let bodyW = geo.size.width - capWidth - 2
            let innerW = bodyW - inset * 2
            let fillW = max(0, innerW * fraction(currentLevel))
            let lowerX = innerW * fraction(lower)
            let upperX = innerW * fraction(upper)
            let midY = geo.size.height / 2

            ZStack(alignment: .leading) {
                // Battery outline
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.primary.opacity(0.35), lineWidth: 1.5)
                    .frame(width: bodyW, height: batteryHeight)
                    .position(x: bodyW / 2, y: midY)

                // Battery cap
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.primary.opacity(0.35))
                    .frame(width: capWidth, height: batteryHeight * 0.4)
                    .position(x: bodyW + capWidth / 2 + 1, y: midY)

                // Charge fill
                let fillColor: Color = currentLevel <= 15 ? .red : currentLevel <= 30 ? .orange : .green
                RoundedRectangle(cornerRadius: cornerRadius - inset)
                    .fill(fillColor.opacity(0.4))
                    .frame(width: fillW, height: batteryHeight - inset * 2)
                    .position(x: inset + fillW / 2, y: midY)

                // Target range highlight
                let rangeW = max(0, upperX - lowerX)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.green.opacity(0.15))
                    .frame(width: rangeW, height: batteryHeight - inset * 2)
                    .position(x: inset + lowerX + rangeW / 2, y: midY)

                // Lower bound marker — orange triangle above + vertical line
                Path { path in
                    let x = inset + lowerX
                    path.move(to: CGPoint(x: x, y: midY - batteryHeight / 2 + 1))
                    path.addLine(to: CGPoint(x: x, y: midY + batteryHeight / 2 - 1))
                }
                .stroke(Color.orange, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))

                // Lower thumb: triangle above battery
                Path { path in
                    let x = inset + lowerX
                    let top = midY - batteryHeight / 2 - 10
                    path.move(to: CGPoint(x: x - 5, y: top))
                    path.addLine(to: CGPoint(x: x + 5, y: top))
                    path.addLine(to: CGPoint(x: x, y: top + 7))
                    path.closeSubpath()
                }
                .fill(Color.orange)

                // Lower label
                Text("\(Int(lower))%")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.orange)
                    .position(x: inset + lowerX, y: midY - batteryHeight / 2 - 20)

                // Lower drag area
                Color.clear
                    .frame(width: markerWidth, height: geo.size.height)
                    .contentShape(Rectangle())
                    .position(x: inset + lowerX, y: midY)
                    .help("Lower bound: charging starts when battery drops below this level")
                    .gesture(
                        DragGesture()
                            .onChanged { drag in
                                let raw = Double(drag.location.x - inset) / Double(innerW) * 100
                                lower = snap(max(0, min(raw, upper - minGap)))
                            }
                    )

                // Upper bound marker — green line + triangle below
                Path { path in
                    let x = inset + upperX
                    path.move(to: CGPoint(x: x, y: midY - batteryHeight / 2 + 1))
                    path.addLine(to: CGPoint(x: x, y: midY + batteryHeight / 2 - 1))
                }
                .stroke(Color.green, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))

                // Upper thumb: triangle below battery
                Path { path in
                    let x = inset + upperX
                    let bot = midY + batteryHeight / 2 + 10
                    path.move(to: CGPoint(x: x - 5, y: bot))
                    path.addLine(to: CGPoint(x: x + 5, y: bot))
                    path.addLine(to: CGPoint(x: x, y: bot - 7))
                    path.closeSubpath()
                }
                .fill(Color.green)

                // Upper label
                Text("\(Int(upper))%")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.green)
                    .position(x: inset + upperX, y: midY + batteryHeight / 2 + 20)

                // Upper drag area
                Color.clear
                    .frame(width: markerWidth, height: geo.size.height)
                    .contentShape(Rectangle())
                    .position(x: inset + upperX, y: midY)
                    .help("Upper bound: charging stops when battery reaches this level")
                    .gesture(
                        DragGesture()
                            .onChanged { drag in
                                let raw = Double(drag.location.x - inset) / Double(innerW) * 100
                                upper = snap(min(100, max(raw, lower + minGap)))
                            }
                    )
            }
        }
    }
}

// MARK: - Window Drag Blocker

/// Overlay that prevents window drag from intercepting SwiftUI gestures.
/// Used on the range slider so thumbs are draggable in detached popover mode.
struct WindowDragBlocker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NoDragView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}

    /// Prevents window drag only within this view's bounds.
    /// Does NOT set window-level isMovableByWindowBackground, which would
    /// disable drag for the entire window and cause intermittent unresponsiveness.
    private class NoDragView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
    }
}

// MARK: - Charge Button Style

struct ChargeButtonStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .foregroundColor(.white)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(color)
                    .opacity(configuration.isPressed ? 0.8 : 1.0)
            )
    }
}

// MARK: - Stat Card

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    var iconColor: Color = .secondary
    var onTap: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(iconColor)

            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(title)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 60)
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture {
            onTap?()
        }
    }
}

