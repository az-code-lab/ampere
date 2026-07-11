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
    // Late-initialized: BatteryMonitor's init blocks on three sequential
    // `sudo SMCWriter` subprocess calls (nodischarge / inhibit-or-allow /
    // spawn-watchdog), ~1-2s total. Holding off on it until the status bar
    // item exists lets the icon appear immediately on launch.
    private var monitor: BatteryMonitor!
    private var registration: RegistrationManager!
    // Registration lives in a real window, not a sheet on the popover:
    // sheets over the popover's non-activating panel never reliably regain
    // key status after the app loses and regains focus, leaving their text
    // fields without an insertion point. A plain window gets standard
    // click-to-activate/key behavior.
    private var registrationWindow: NSWindow?
    private var registrationShowObserver: NSObjectProtocol?
    private var pinnedObserver: AnyCancellable?
    private var stateObserver: AnyCancellable?
    private var mouseMonitor: Any?
    private var globalMouseMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Activation policy is set in main.swift before SwiftUI launches,
        // so we don't need to change it here (avoids external monitor blackout).

        // 1. Status bar item first, with a placeholder icon and no click
        // handler. The OS draws the menu bar slot before the heavy
        // BatteryMonitor init runs below, so the user sees Ampere appear
        // immediately rather than after a 1-2s blank gap.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = buildMenuBarIcon(percentage: 0, hasWarning: false)
        }

        // 2. Heavy init — blocks the main thread on sudo SMC writes. The
        // placeholder icon is already visible during this; clicks land on a
        // button with no action and are no-ops, which is the right behavior
        // until the popover is wired up below.
        monitor = BatteryMonitor()
        registration = RegistrationManager()

        // 3. Wire the button to togglePopover and refresh the icon with real
        // data. Done after monitor is ready so updateMenuBarIcon can read it.
        if let button = statusItem.button {
            button.action = #selector(togglePopover)
            button.target = self
        }
        updateMenuBarIcon()

        // Create popover with the battery panel
        popover = NSPopover()
        popover.contentSize = NSSize(width: 580, height: 632)
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: ContentView(monitor: monitor, registration: registration)
        )

        // Keep popover behavior in sync: transient (auto-closes on outside
        // clicks / app deactivation) only while neither pinned nor showing a
        // sheet. A visible sheet pins the popover open exactly like the pin
        // button — see BatteryMonitor.sheetVisible for why closing under a
        // sheet must never happen.
        pinnedObserver = monitor.$pinned.combineLatest(monitor.$sheetVisible)
            .sink { [weak self] pinned, sheetVisible in
                self?.popover.behavior = (pinned || sheetVisible) ? .applicationDefined : .transient
            }

        // The panel's Registration row posts this; the window is owned here.
        registrationShowObserver = NotificationCenter.default.addObserver(
            forName: .ampereShowRegistrationWindow, object: nil, queue: .main
        ) { [weak self] _ in
            self?.showRegistrationWindow()
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
    private var lastIconShowPct: Bool = true
    private var lastIconPanelAnchored: Bool = false
    /// Whether the last rendered title occupied its full width (visible or
    /// clear glyphs, as opposed to the empty icon-only title).
    private var lastTitleWide = true
    /// True while the popover is (or is about to be) anchored to the status
    /// item — set before showing, cleared on close/detach. While set, the
    /// item width may grow but never shrink; see the title logic in
    /// updateMenuBarIcon.
    private var panelAnchored = false
    private var animationTimer: Timer?
    private var animationPct: Int = 0

    /// True iff the battery is actually receiving current right now. Shares
    /// the source-of-truth logic with `BatteryModeRouter` so the menu bar
    /// animation direction stays in lockstep with the stat-card tint and
    /// the Sankey diagram during transients.
    private func effectivelyCharging() -> Bool {
        BatteryModeRouter.compute(
            amperage: monitor.state?.amperage,
            isCharging: monitor.state?.isCharging ?? false,
            activeDischarging: monitor.activeDischarging,
            adapterConnected: monitor.state?.adapterConnected ?? false
        ) == .charging
    }

    private func updateMenuBarIcon() {
        guard let button = statusItem.button else { return }
        let pct = monitor.state?.percentage ?? 0
        let isCharging = effectivelyCharging()
        let hasWarning = monitor.healthWarning != nil
        let showPct = monitor.showMenuBarPercent

        let isAnimatingDown = monitor.activeDischarging
        let needsAnimation = isCharging || isAnimatingDown

        // Every @Published change lands here via objectWillChange (health
        // check timestamps, error strings, …). Skip the NSImage rebuild when
        // nothing the menu bar renders has changed and the animation timer
        // already matches the desired state — the timer redraws animated
        // frames on its own.
        if pct == lastIconPct, isCharging == lastIconCharging, hasWarning == lastIconWarning,
           showPct == lastIconShowPct, panelAnchored == lastIconPanelAnchored,
           needsAnimation == (animationTimer != nil) {
            return
        }

        // Reset the animation timer — the early return above is the exact
        // complement of the old "did anything change" condition, so reaching
        // this point always means the timer needs to be torn down or rebuilt.
        animationTimer?.invalidate()
        animationTimer = nil
        if needsAnimation {
            animationPct = pct
            animationTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
                guard let self, let button = self.statusItem.button else { return }
                let curPct = self.monitor.state?.percentage ?? 0
                let target: Int
                if self.effectivelyCharging() {
                    target = self.monitor.autoManageEnabled ? self.monitor.chargeUpperBound : 100
                    self.animationPct += 5
                    if self.animationPct > target { self.animationPct = curPct }
                } else {
                    target = self.monitor.chargeUpperBound
                    self.animationPct -= 5
                    if self.animationPct < target { self.animationPct = curPct }
                }
                let warn = self.monitor.healthWarning != nil
                button.image = self.buildMenuBarIcon(
                    percentage: CGFloat(self.animationPct),
                    hasWarning: warn
                )
            }
        }

        lastIconPct = pct
        lastIconCharging = isCharging
        lastIconWarning = hasWarning
        lastIconShowPct = showPct
        lastIconPanelAnchored = panelAnchored

        let displayPct = needsAnimation ? animationPct : pct
        button.image = buildMenuBarIcon(
            percentage: CGFloat(displayPct),
            hasWarning: hasWarning
        )
        // Menu bar items resize from the LEFT edge, so narrowing this item
        // drags the icon — and the panel anchored to it — sideways. While
        // the panel is anchored the width may therefore grow (percent
        // toggled on: it must, to fit the text) but never shrink: hiding
        // renders the same glyphs in clear color, which reflects instantly
        // at identical width, and the item narrows once the panel closes.
        let wide = showPct || (panelAnchored && lastTitleWide)
        lastTitleWide = wide
        if wide {
            var titleAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            ]
            if !showPct {
                titleAttrs[.foregroundColor] = NSColor.clear
            } else if hasWarning {
                titleAttrs[.foregroundColor] = NSColor.systemOrange
            }
            button.attributedTitle = NSAttributedString(string: " \(pct)%", attributes: titleAttrs)
        } else {
            // Icon-only mode: a health warning still shows via the orange icon.
            button.attributedTitle = NSAttributedString(string: "")
        }
    }

    private func showRegistrationWindow() {
        // Already open: just bring it forward — replacing the content view
        // mid-flight would wipe whatever the user has typed.
        if let window = registrationWindow, window.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        popover.performClose(nil)
        let window = registrationWindow ?? {
            let window = NSWindow(contentRect: .zero,
                                  styleMask: [.titled, .closable],
                                  backing: .buffered, defer: false)
            window.title = "Ampere Registration"
            // Reused across opens; a fresh RegistrationView is installed
            // each time below so the form starts clean.
            window.isReleasedWhenClosed = false
            registrationWindow = window
            return window
        }()
        window.contentViewController = NSHostingController(
            rootView: RegistrationView(registration: registration) { [weak self] in
                self?.registrationWindow?.close()
            }
        )
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            monitor.setFastPolling(true)
            // Set before the pre-show render: the width-shrink deferral in
            // updateMenuBarIcon must be active from the first anchored frame.
            panelAnchored = true
            updateMenuBarIcon()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func popoverShouldDetach(_ popover: NSPopover) -> Bool {
        true
    }

    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        // Refuse every close request while a sheet is up — including the
        // programmatic performClose from togglePopover (menu bar icon click).
        // The sheet must be dismissed first; then the popover closes normally.
        !monitor.sheetVisible
    }

    func popoverDidDetach(_ popover: NSPopover) {
        // Pin unconditionally so the detached window doesn't immediately
        // close on the next outside click (which would happen if pinned
        // stayed false: pinnedObserver would leave popover.behavior=.transient
        // and globalMouseMonitor would dismiss the detach). If we can't
        // register the close observer for some reason, the worst case is
        // fast polling staying on until the next app launch — invisible
        // battery drain is a lesser evil than the popover the user just
        // explicitly detached vanishing under them.
        // The detached window floats free of the status item, so item
        // resizes can't move it — release the deferred width shrink now.
        panelAnchored = false
        updateMenuBarIcon()
        monitor.pinned = true
        // Observe the detached window closing — popoverDidClose only fires
        // during the detach transition, NOT when the detached window is closed.
        if let window = popover.contentViewController?.view.window {
            NotificationCenter.default.addObserver(
                self, selector: #selector(detachedWindowDidClose),
                name: NSWindow.willCloseNotification, object: window
            )
        }
    }

    @objc private func detachedWindowDidClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: notification.object)
        monitor.pinned = false
        monitor.setFastPolling(false)
    }

    func popoverDidClose(_ notification: Notification) {
        // popoverDidClose fires during detach (popover → window transition)
        // but NOT when the detached window is closed. The detached window
        // close is handled by detachedWindowDidClose above.
        guard !popover.isDetached else { return }
        monitor.pinned = false
        monitor.setFastPolling(false)
        // Nothing is anchored to the item anymore — release the deferred
        // width shrink (this is where the item narrows when the percent
        // was hidden while the panel was open).
        panelAnchored = false
        updateMenuBarIcon()
    }

    deinit {
        // pinnedObserver / stateObserver are AnyCancellable — they cancel
        // automatically when this AppDelegate's stored properties go out of
        // scope, so no explicit .cancel() needed here.
        animationTimer?.invalidate()
        if let registrationShowObserver {
            NotificationCenter.default.removeObserver(registrationShowObserver)
        }
        if let mouseMonitor = mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
        }
        if let globalMouseMonitor = globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
        }
    }

    private func buildMenuBarIcon(percentage: CGFloat, hasWarning: Bool = false) -> NSImage {
        let battW: CGFloat = 24
        let battH: CGFloat = 11
        let capW: CGFloat = 2.8
        let totalW = battW + capW + 1
        let totalH: CGFloat = 18

        let image = NSImage(size: NSSize(width: totalW, height: totalH))
        image.lockFocus()

        let color: NSColor = hasWarning ? .systemOrange : .black
        let battY = (totalH - battH) / 2

        // Battery outline
        let bodyRect = NSRect(x: 0.5, y: battY + 0.5, width: battW - 1, height: battH - 1)
        let path = NSBezierPath(roundedRect: bodyRect, xRadius: 2, yRadius: 2)
        color.withAlphaComponent(0.7).setStroke()
        path.lineWidth = 1
        path.stroke()

        // Battery cap
        let capRect = NSRect(x: battW, y: battY + battH * 0.3, width: capW, height: battH * 0.4)
        color.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: capRect, xRadius: 0.8, yRadius: 0.8).fill()

        // Fill level. Clamp to [0, fillMaxW] because the animation timer
        // can briefly overshoot 100% (it bumps by +5 before the > target
        // reset fires), and without an upper clamp the fill would render
        // past the outlined boundary.
        let inset: CGFloat = 2
        let fillMaxW = battW - 1 - inset * 2
        let fillW = min(fillMaxW, max(0, fillMaxW * percentage / 100))
        let fillRect = NSRect(x: 0.5 + inset, y: battY + 0.5 + inset,
                              width: fillW, height: battH - 1 - inset * 2)
        color.setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: 1, yRadius: 1).fill()

        image.unlockFocus()
        image.isTemplate = !hasWarning
        return image
    }
}

// MARK: - Content View

struct ContentView: View {
    @ObservedObject var monitor: BatteryMonitor
    @ObservedObject var registration: RegistrationManager
    // Display preferences persist across restarts per CLAUDE.md requirement 3.
    // showAbout / launchAtLogin remain @State: the former is sheet visibility,
    // the latter is derived from SMAppService and isn't a user preference.
    @AppStorage("ui.useFahrenheit") private var useFahrenheit = true
    @AppStorage("ui.healthShowPercent") private var healthShowPercent = true
    @AppStorage("ui.ageShowYears") private var ageShowYears = true
    @AppStorage("ui.amperageShowMA") private var amperageShowMA = false
    @AppStorage("ui.rawChargeShowMAh") private var rawChargeShowMAh = false
    @State private var showAbout = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    // Deliberately @State, not persisted: the settings section starts folded
    // on every launch, but keeps its state while the app runs (the popover
    // closing does not recreate this view).
    @State private var settingsExpanded = false

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
        .frame(width: 580)
        .background(Color(.windowBackgroundColor))
        .onChange(of: showAbout) {
            // Mirror sheet visibility into the monitor so AppDelegate keeps
            // the popover from closing (and breaking) underneath the sheet.
            monitor.sheetVisible = showAbout
        }
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

            // Settings disclosure: auto charge management, launch at login,
            // and registration. Always collapsed on a fresh launch.
            settingsHeader()

            if settingsExpanded {
                autoManageToggle()
                launchAtLoginRow()
                menuBarPercentRow()
                registrationRow()
            }

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
                if let update = monitor.updateAvailable {
                    updateControl(update)
                } else {
                    switch monitor.manualUpdateCheck {
                    case .none:
                        Button("Check for Updates") {
                            monitor.checkForUpdateNow()
                        }
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .buttonStyle(.plain)
                    case .checking:
                        Text("Checking…")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    case .upToDate:
                        Text("Up to Date")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    case .failed:
                        Text("Check Failed")
                            .font(.system(size: 12))
                            .foregroundColor(.orange)
                    }
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
                        // Health checks only run while an adapter is connected
                        // (see the gate in refresh()), so on battery "pending"
                        // would never resolve — say what it's waiting for.
                        if monitor.lastHealthCheckStatus == "pending",
                           monitor.state?.adapterConnected != true {
                            Text("waiting for power adapter")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.secondary)
                        } else {
                            Text(monitor.lastHealthCheckStatus)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(monitor.lastHealthCheckStatus == "pass" ? .green
                                    : monitor.lastHealthCheckStatus == "FAIL" ? .red : .primary)
                        }
                        Spacer()
                        Link(destination: URL(string: "https://amperebattery.app/tech.html#health")!) {
                            Image(systemName: "info.circle")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        .help("How health checks work — opens amperebattery.app")
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
                    } else if !monitor.lastHealthCheckSMC.isEmpty {
                        Text(monitor.lastHealthCheckSMC)
                            .font(.system(size: 12, design: .monospaced))
                    }
                    Text("Checked at: \(healthCheckTimeString)")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Divider()
                    // Reflect the actual grant state — a static "requires
                    // admin privileges" line reads as an error when access
                    // is already granted.
                    Text(monitor.isSudoRuleInstalled
                        ? "Admin access granted for charge control."
                        : "Requires admin privileges for charge control.")
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
        BatteryModeRouter.compute(
            amperage: state.amperage,
            isCharging: state.isCharging,
            activeDischarging: monitor.activeDischarging,
            adapterConnected: state.adapterConnected
        )
    }

    private func batteryHeader(_ state: BatteryState) -> some View {
        VStack(spacing: 8) {
            VStack(spacing: 12) {
                PowerFlowDiagram(
                    adapterConnected: state.adapterConnected,
                    percentage: state.percentage,
                    adapterWatts: state.adapterWatts,
                    batteryWatts: state.batteryWatts,
                    electronicsWatts: state.electronicsWatts,
                    animate: monitor.isPopoverVisible
                )
                .frame(width: 240, height: 110)

                Text("\(state.percentage)%")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
            }

            // Charging status label + time remaining
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor(state))
                    .frame(width: 8, height: 8)

                Text(statusLine(state))
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

    /// "Charging — Xh Ym to NN%" / "Discharging — Xm remaining" / etc.
    /// Combines `statusText` with `displayedTimeRemaining` and computes
    /// the ETA once per render (the prior inline form called the helper
    /// twice — once for the empty check and again in the interpolation).
    private func statusLine(_ state: BatteryState) -> String {
        let trailing = displayedTimeRemaining(state)
        return trailing.isEmpty ? statusText(state) : "\(statusText(state)) — \(trailing)"
    }

    /// Compute our own ETA from the live amperage so the label is consistent
    /// across charging/discharging modes and doesn't go silent in scenarios
    /// IOKit doesn't track (active SMC discharge, weak adapter making the
    /// battery supplement). Falls back to `state.timeRemaining` only when
    /// the computation can't run — that path still serves the on-battery
    /// "Xh Ym remaining" case via IOKit's smart `TimeToEmpty` estimator.
    private func displayedTimeRemaining(_ state: BatteryState) -> String {
        let eta = TimeRemainingRouter.label(
            percentage: state.percentage,
            maxCapacity: state.maxCapacity,
            amperage: state.amperage,
            autoManageEnabled: monitor.autoManageEnabled,
            activeDischarging: monitor.activeDischarging,
            upperBound: monitor.chargeUpperBound
        )
        return eta.isEmpty ? state.timeRemaining : eta
    }

    private func statusMessage(_ state: BatteryState) -> String {
        if let error = monitor.lastError { return error }
        if let warning = monitor.healthWarning { return warning }
        if monitor.activeDischarging {
            // SMC discharge has been requested but may not have engaged yet
            // (transient at startup or just after toggling the feature on).
            // Be honest about the *current* state — the battery is still
            // gaining charge — instead of claiming the system is discharging.
            if (state.amperage ?? 0) > 0 {
                return "Discharge starting — sleep is temporarily disabled"
            }
            return "Discharging to \(monitor.chargeUpperBound)% — sleep is temporarily disabled"
        }
        if monitor.autoManageEnabled && monitor.chargingPaused {
            // "drains to X% under load" implies passive drain via the adapter
            // rail — only accurate on AC. On battery, the battery drains
            // directly regardless of CHTE, so fall through to the generic
            // "holding" message which is still accurate.
            if state.adapterConnected && state.percentage > monitor.chargeUpperBound {
                return "Auto: not charging — drains to \(monitor.chargeUpperBound)% under load"
            }
            return "Auto: holding — charges below \(monitor.chargeLowerBound)% or on demand"
        }
        // Use amperage's sign rather than `state.isCharging` for the same
        // transient-consistency reason as `BatteryModeRouter` — IOKit's
        // `isCharging` can lag the actual current direction.
        if monitor.autoManageEnabled, (state.amperage ?? 0) > 0 {
            return "Auto: charging to \(monitor.chargeUpperBound)%"
        }
        // chargingPaused can briefly persist after a manual-mode unplug
        // (until the next refresh tick clears it), so require adapterConnected
        // here to avoid "Running on AC power" while actually on battery.
        if monitor.chargingPaused && state.adapterConnected { return "Running on AC power — battery will not charge" }
        if !state.adapterConnected { return "Connect power adapter to control charging" }
        return ""
    }

    private func statusMessageColor(_ state: BatteryState) -> Color {
        if monitor.lastError != nil { return .red }
        if monitor.healthWarning != nil { return .red }
        if monitor.activeDischarging { return .orange }
        // Match statusMessage's branching: blue for auto-hold (regardless of AC)
        // or manual pause while on AC. A manual-mode chargingPaused with no
        // adapter falls through to the "Connect power adapter" prompt, which
        // should be secondary, not blue.
        if monitor.chargingPaused && (monitor.autoManageEnabled || state.adapterConnected) { return .blue }
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

        let healthValue = healthShowPercent ? state.health : "\(state.maxCapacity)/\(state.designCapacity) mAh"

        let mode = batteryMode(state)
        let tint: Color = mode == .charging ? .green : (mode == .onBattery || mode == .discharging) ? .orange : .secondary
        let fourColumns = [
            GridItem(.flexible()),
            GridItem(.flexible()),
            GridItem(.flexible()),
            GridItem(.flexible()),
        ]

        // Adapter cards dim to .secondary when nothing is plugged in so the
        // "—" or 0 readings are visually distinguished from live values.
        let adapterTint: Color = state.adapterConnected ? tint : .secondary

        return LazyVGrid(columns: fourColumns, spacing: 8) {
            // Row 0
            StatCard(title: "Cycle Count", value: "\(state.cycleCount)", icon: "arrow.triangle.2.circlepath", iconColor: tint)
            StatCard(title: "System Load", value: formatWatts(state.electronicsWatts), icon: "desktopcomputer", iconColor: tint)
            StatCard(title: "Adapter Load", value: formatWatts(state.adapterWatts), icon: "bolt.horizontal.fill", iconColor: adapterTint)
            StatCard(title: "Battery Load", value: formatWatts(state.batteryWatts), icon: "bolt.horizontal.fill", iconColor: tint)

            // Row 1
            StatCard(title: "Battery Served",
                value: ageShowYears
                    ? (state.batteryAgeYears.isEmpty ? "—" : state.batteryAgeYears)
                    : (state.batteryAgeDays.isEmpty ? "—" : state.batteryAgeDays),
                icon: "calendar.badge.clock", iconColor: tint, onTap: {
                    ageShowYears.toggle()
                })
            StatCard(title: "Temperature", value: tempValue, icon: "thermometer.medium", iconColor: tint, onTap: {
                useFahrenheit.toggle()
            })
            StatCard(title: "Adapter Voltage", value: voltageValue(state.adapterVoltage), icon: "bolt.fill", iconColor: adapterTint)
            StatCard(title: "Battery Voltage", value: voltageValue(state.voltage), icon: "bolt.fill", iconColor: tint)

            // Row 2
            StatCard(title: "Health", value: healthValue, icon: "stethoscope", iconColor: tint, onTap: {
                healthShowPercent.toggle()
            })
            StatCard(title: "Raw Charge",
                value: rawChargeShowMAh
                    ? "\(state.currentCapacity)/\(state.maxCapacity) mAh"
                    : (state.maxCapacity > 0
                        ? String(format: "%.1f%%", Double(state.currentCapacity) / Double(state.maxCapacity) * 100)
                        : "\(state.percentage)%"),
                icon: "percent", iconColor: tint, onTap: {
                    rawChargeShowMAh.toggle()
                })
            StatCard(title: "Adapter Current", value: amperageValue(state.adapterAmperage), icon: "directcurrent", iconColor: adapterTint, onTap: {
                amperageShowMA.toggle()
            })
            StatCard(title: "Battery Current", value: amperageValue(state.amperage), icon: "directcurrent", iconColor: tint, onTap: {
                amperageShowMA.toggle()
            })
        }
        .padding(.horizontal, 16)
    }

    private func amperageValue(_ milliamps: Double?) -> String {
        guard let milliamps else { return "—" }
        if amperageShowMA {
            return String(format: "%.0f mA", milliamps)
        }
        return String(format: "%.2f A", milliamps / 1000.0)
    }

    private func voltageValue(_ volts: Double?) -> String {
        guard let volts else { return "—" }
        return String(format: "%.2f V", volts)
    }

    /// Disclosure header for the settings rows. While collapsed it shows
    /// compact status icons so auto-manage / launch-at-login / registration
    /// state stays visible at a glance — the registration row is the only
    /// entry point to the registration window, so its status must not
    /// disappear entirely when folded.
    private func settingsHeader() -> some View {
        Button(action: { settingsExpanded.toggle() }) {
            HStack {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                Text("Settings")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if !settingsExpanded {
                    Image(systemName: "arrow.up.arrow.down.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(monitor.autoManageEnabled ? .accentColor : .secondary)
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(launchAtLogin ? .accentColor : .secondary)
                    Image(systemName: "percent")
                        .font(.system(size: 12))
                        .foregroundColor(monitor.showMenuBarPercent ? .accentColor : .secondary)
                    Image(systemName: registration.isRegistered ? "checkmark.seal.fill" : "xmark.seal.fill")
                        .font(.system(size: 12))
                        .foregroundColor(registration.isRegistered ? .accentColor : .orange)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(settingsExpanded ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .help(settingsExpanded ? "Collapse settings" : "Expand settings")
    }

    private func launchAtLoginRow() -> some View {
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
    }

    private func menuBarPercentRow() -> some View {
        HStack {
            Image(systemName: "percent")
                .font(.system(size: 14))
                .foregroundColor(monitor.showMenuBarPercent ? .accentColor : .secondary)
            Text("Percent in Menu Bar")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Toggle("", isOn: Binding(
                get: { monitor.showMenuBarPercent },
                set: { monitor.showMenuBarPercent = $0 }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .help("Show the charge percentage next to the battery icon in the menu bar; off shows the icon only (the freed space is reclaimed when this panel closes)")
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
                        // Rule-1 entry condition: if currently below the lower
                        // bound on AC, the documented behavior is to charge to
                        // upper. The state machine's branch 3 requires
                        // chargingPaused=true which a manual→auto transition
                        // doesn't have, so set chargeToUpperBound here.
                        if let state = monitor.state,
                           state.adapterConnected,
                           state.percentage < monitor.chargeLowerBound {
                            monitor.chargeToUpperBound = true
                        }
                        monitor.ensureSudoInstalled { ok in
                            if ok {
                                // Act on the new mode now (inhibit/allow per
                                // the state machine) instead of waiting up to
                                // a poll cycle.
                                monitor.refresh()
                            } else {
                                monitor.autoManageEnabled = false
                                monitor.lastError = "Admin access required for auto charge management"
                            }
                        }
                    } else {
                        monitor.autoManageEnabled = false
                        monitor.chargeToUpperBound = false
                        // Any pending error in auto-manage mode (most commonly
                        // "Admin access required for auto charge management"
                        // from a failed prior enable) is no longer relevant
                        // once the user has disabled auto-manage.
                        monitor.lastError = nil
                        if monitor.chargingPaused {
                            monitor.toggleCharging()
                        }
                        // If a discharge is active, refresh()'s
                        // "!autoManageEnabled" branch stops it (CHIE + sleep
                        // restore) immediately rather than on the next tick —
                        // without this, the UI shows manual mode while the
                        // SMC is still actively discharging.
                        monitor.refresh()
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
                minGap: Double(BatteryMonitor.chargeBoundMinGap)
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
                            // Start/stop the discharge now — refresh()'s
                            // auto-discharge branches handle both directions.
                            monitor.refresh()
                        }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
            } else if state.percentage >= monitor.chargeLowerBound && state.percentage < monitor.chargeUpperBound {
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
                            if newValue {
                                // Kick the state machine so charging starts
                                // now, not on the next poll tick.
                                monitor.refresh()
                            } else {
                                monitor.inhibitCharging()
                            }
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

    // MARK: - Registration

    /// Footer control for a pending update. Idle/failed → a clickable
    /// "Update to X" button (failed adds a warning icon whose tooltip carries
    /// the error and the brew fallback); while working → progress text. The
    /// install quits and relaunches the app, which is the same
    /// persisted-state path as a normal quit/restart.
    @ViewBuilder
    private func updateControl(_ update: AvailableUpdate) -> some View {
        switch monitor.updateState {
        case .downloading(let fraction):
            Text("Downloading… \(Int((fraction * 100).rounded()))%")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        case .installing:
            Text("Installing…")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        case .idle, .failed:
            HStack(spacing: 4) {
                if case .failed(let message) = monitor.updateState {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                        .help("Update failed: \(message)\n\nFallback: brew upgrade --cask ampere")
                }
                Button {
                    monitor.installUpdate()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up.circle.fill")
                        Text("Update to \(update.version)")
                    }
                }
                .font(.system(size: 12))
                .foregroundColor(.orange)
                .buttonStyle(.plain)
                .help("Download v\(update.version), verify, install, and relaunch. Currently on \(AppVersion.current).")
            }
        }
    }

    private func registrationRow() -> some View {
        HStack {
            Image(systemName: registration.isRegistered ? "checkmark.seal.fill" : "xmark.seal.fill")
                .font(.system(size: 14))
                .foregroundColor(registration.isRegistered ? .accentColor : .orange)
            Text("Registration")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button(action: {
                NotificationCenter.default.post(name: .ampereShowRegistrationWindow, object: nil)
            }) {
                // Licensee name when known; the registration window this
                // opens shows the email, so the row doesn't need to.
                Text(registration.isRegistered
                    ? (registration.name.isEmpty ? registration.email : registration.name)
                    : "Unregistered")
                    .font(.system(size: 12))
                    .foregroundColor(registration.isRegistered ? .secondary : .orange)
            }
            .buttonStyle(.plain)
            .help(registration.isRegistered
                ? "Registered to \(registration.email) — click to manage"
                : "Unregistered — click to enter your registration key")
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
        // Match the diagram/cards by deferring to the live current direction
        // first. This keeps the status dot consistent with the Sankey ribbons
        // during transients where IOKit's `isCharging` / `activeDischarging`
        // intent disagrees with the actual amperage sign (e.g. just after a
        // "Discharge to Upper Bound" restart, before the SMC has engaged).
        if (state.amperage ?? 0) > 0 { return .green }
        if state.isCharging { return .green }
        if monitor.activeDischarging { return .orange }
        if state.adapterConnected { return .blue }
        if state.percentage <= 15 { return .red }
        return .secondary
    }

    private func statusText(_ state: BatteryState) -> String {
        if (state.amperage ?? 0) > 0 { return "Charging" }
        if monitor.activeDischarging { return "Discharging" }
        if monitor.chargingPaused && state.adapterConnected { return "On AC Power (Not Charging)" }
        if state.isCharging { return "Charging" }
        if state.adapterConnected { return "On AC Power" }
        return "On Battery"
    }
}

// MARK: - Pure helpers (routers / formatters)

enum BatteryMode: Equatable {
    case charging
    case discharging
    case onACNotCharging
    case onBattery
}

/// Single source of truth for the "%.1f W" / "—" wattage label format.
/// Used by both the stat cards (`ContentView.statusGrid`) and the Sankey
/// diagram nodes (`PowerFlowDiagram.node` / `batteryNode`) — keeping the
/// formatter shared so the two displays can never disagree on rounding
/// or the "unknown" sentinel.
func formatWatts(_ watts: Double?) -> String {
    guard let watts else { return "—" }
    return String(format: "%.1f W", watts)
}

/// Decides which target the ETA label should aim at, then delegates the
/// formatting to `BatteryETACalculator`. Returns "" when amperage is 0/nil
/// (no flow) so the caller can fall back to IOKit's `timeRemaining`.
///
/// Targets:
/// - charging on auto-manage → upper bound
/// - charging manually → 100 % ("to full")
/// - discharging via "Discharge to Upper Bound" → upper bound
/// - discharging otherwise → 0 % ("remaining")
enum TimeRemainingRouter {
    static func label(
        percentage: Int,
        maxCapacity: Int,
        amperage: Double?,
        autoManageEnabled: Bool,
        activeDischarging: Bool,
        upperBound: Int
    ) -> String {
        guard let amperage = amperage else { return "" }
        if amperage > 0 {
            let target = autoManageEnabled ? upperBound : 100
            return BatteryETACalculator.chargingETA(
                percentage: percentage, maxCapacity: maxCapacity,
                amperage: amperage, target: target
            )
        } else if amperage < 0 {
            let target = activeDischarging ? upperBound : 0
            return BatteryETACalculator.dischargeETA(
                percentage: percentage, maxCapacity: maxCapacity,
                amperage: amperage, target: target
            )
        }
        return ""
    }
}

/// Computes the "Xh Ym to NN%" / "Xh Ym remaining" labels shown next to
/// the charging status. Pure inputs so it can be unit-tested independently
/// of the SwiftUI view that consumes it.
///
/// Sign convention for `amperage`: positive = into battery (charging),
/// negative = out of battery (discharging), zero/nil = no flow.
enum BatteryETACalculator {
    /// ETA to reach `target`% while charging. Returns "" when inputs don't
    /// support a charging computation (gap ≤ 0, amperage missing or
    /// non-positive, max capacity missing) or when the answer is so large
    /// it's almost certainly a sensor artifact rather than a real estimate.
    static func chargingETA(percentage: Int, maxCapacity: Int, amperage: Double?, target: Int) -> String {
        let gap = target - percentage
        guard gap > 0, maxCapacity > 0,
              let amperage = amperage, amperage > 0 else {
            return ""
        }
        // amperage is in mA, capacity in mAh — hours = mAh / mA.
        let remainingMAh = Double(gap) * Double(maxCapacity) / 100.0
        guard let totalMinutes = safeMinutes(remainingMAh: remainingMAh, currentMA: amperage) else {
            return ""
        }
        let suffix = target == 100 ? "to full" : "to \(target)%"
        return formatMinutes(totalMinutes, suffix: suffix)
    }

    /// ETA to drain to `target`% from the live discharge current.
    static func dischargeETA(percentage: Int, maxCapacity: Int, amperage: Double?, target: Int) -> String {
        let gap = percentage - target
        guard gap > 0, maxCapacity > 0,
              let amperage = amperage, amperage < 0 else {
            return ""
        }
        let remainingMAh = Double(gap) * Double(maxCapacity) / 100.0
        guard let totalMinutes = safeMinutes(remainingMAh: remainingMAh, currentMA: abs(amperage)) else {
            return ""
        }
        let suffix = target == 0 ? "remaining" : "to \(target)%"
        return formatMinutes(totalMinutes, suffix: suffix)
    }

    static func formatMinutes(_ totalMinutes: Int, suffix: String) -> String {
        if totalMinutes < 1 { return "<1m \(suffix)" }
        if totalMinutes < 60 { return "\(totalMinutes)m \(suffix)" }
        return "\(totalMinutes / 60)h \(totalMinutes % 60)m \(suffix)"
    }

    /// Convert mAh / mA into rounded minutes, guarding against NaN/Inf and
    /// absurdly large values caused by near-zero current readings during
    /// state transitions. The 7-day ceiling is a sanity cap — no real
    /// charge or discharge takes longer than that, and showing "5000h 0m"
    /// labels would be worse than showing nothing.
    private static func safeMinutes(remainingMAh: Double, currentMA: Double) -> Int? {
        let minutes = (remainingMAh / currentMA * 60).rounded()
        guard minutes.isFinite, minutes >= 0, minutes <= 60 * 24 * 7 else { return nil }
        return Int(minutes)
    }
}

/// Pure helper that picks the `BatteryMode` for stat-card tinting from the
/// live inputs. Extracted from `ContentView.batteryMode(_:)` so the
/// transient-consistency invariant (lean on amperage's sign before falling
/// back to `isCharging` / `activeDischarging`) can be pinned by tests.
enum BatteryModeRouter {
    static func compute(
        amperage: Double?,
        isCharging: Bool,
        activeDischarging: Bool,
        adapterConnected: Bool
    ) -> BatteryMode {
        if let amperage = amperage {
            if amperage > 0 { return .charging }
            if amperage < 0 {
                return adapterConnected ? .discharging : .onBattery
            }
        }
        if isCharging { return .charging }
        if activeDischarging { return .discharging }
        if adapterConnected { return .onACNotCharging }
        return .onBattery
    }
}

// MARK: - Power Flow (Sankey) Diagram

/// Which Sankey case to render. The choice is driven purely from live
/// telemetry (adapter connected? adapter delivering? battery sign?), not
/// from IOKit's `isCharging` flag — `isCharging` can lag the actual current
/// direction during auto-manage transitions.
///
/// Exposed at module scope (rather than nested inside PowerFlowDiagram) so
/// `PowerFlowRouterTests` can pin the routing invariant.
enum PowerFlowCase: Equatable {
    case acToBoth      // AC → Computer + Battery
    case acAndBattery  // AC (weak) + Battery → Computer
    case acOnly        // AC → Computer
    case batteryOnly   // Battery → Computer
}

enum PowerFlowRouter {
    static func compute(
        adapterConnected: Bool,
        adapterWatts: Double?,
        batteryWatts: Double?
    ) -> PowerFlowCase {
        // nil adapterWatts (very old Macs without PowerTelemetryData) — assume
        // the cable is delivering an unknown but non-zero amount. A measured
        // exactly 0 W with the cable plugged in is the "dead adapter" case
        // (broken cable, brick unplugged at the wall, etc.) and should render
        // as pure on-battery so we don't draw an empty node.
        let acDelivering: Bool = (adapterWatts ?? 1) != 0
        if !adapterConnected || !acDelivering { return .batteryOnly }
        // Base direction on batteryWatts' sign — the same raw measurement the
        // Battery Load card displays. Relying on IOKit's `isCharging` here
        // breaks consistency during state transitions (e.g. "Discharge to
        // Upper Bound" startup, where isCharging is already false but the
        // battery is still receiving current).
        if (batteryWatts ?? 0) < 0 { return .acAndBattery }
        if (batteryWatts ?? 0) > 0 { return .acToBoth }
        return .acOnly
    }
}

/// Sankey-style diagram of live power flow. Sources on the left, sinks on the
/// right; band widths are proportional to the wattage of each flow. Four cases:
/// - charging: AC → (Computer + Battery)
/// - AC too weak: (AC + Battery) → Computer (battery supplements an underpowered adapter)
/// - AC, not charging: AC → Computer
/// - on battery: Battery → Computer
private struct PowerFlowDiagram: View {
    let adapterConnected: Bool
    let percentage: Int
    let adapterWatts: Double?
    let batteryWatts: Double?     // + = into battery (charging), - = out of battery (drain)
    let electronicsWatts: Double?
    var animate: Bool = false

    private static let nodeAreaWidth: CGFloat = 44
    private static let maxRibbonH: CGFloat = 26
    private static let twoNodeOffset: CGFloat = 24
    private static let flowDuration: TimeInterval = 2.0
    // Fixed icon-row height so SF Symbol nodes and the custom BatteryGlyph
    // node end up the same vertical size; without this the wattage labels
    // beneath each node would sit at different y positions.
    private static let glyphAreaH: CGFloat = 28
    private static let nodeTextH: CGFloat = 14
    private static let nodeVStackSpacing: CGFloat = 1
    // Offset between the node VStack's geometric center and the icon's
    // geometric center. The VStack stacks icon + spacing + text, so the
    // icon sits `(text + spacing) / 2` above the VStack center; we shift
    // the position by that amount so `.position(p)` lands the *icon* (not
    // the icon+text midpoint) on the ribbon attach point — the Sankey
    // bands then connect to where the visual symbol actually is.
    private static let nodeIconOffsetY: CGFloat = (Self.nodeTextH + Self.nodeVStackSpacing) / 2

    private var flow: PowerFlowCase {
        PowerFlowRouter.compute(
            adapterConnected: adapterConnected,
            adapterWatts: adapterWatts,
            batteryWatts: batteryWatts
        )
    }

    private var acColor: Color { .cyan }
    private var chargeColor: Color { .green }
    private var drainColor: Color { .orange }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let leftX = Self.nodeAreaWidth / 2
            let rightX = w - Self.nodeAreaWidth / 2
            let leftRX = Self.nodeAreaWidth
            let rightRX = w - Self.nodeAreaWidth
            let midY = h / 2

            ZStack {
                switch flow {
                case .acToBoth:
                    acToBothBody(leftX: leftX, rightX: rightX,
                                  leftRX: leftRX, rightRX: rightRX, midY: midY)
                case .acAndBattery:
                    acAndBatteryBody(leftX: leftX, rightX: rightX,
                                      leftRX: leftRX, rightRX: rightRX, midY: midY)
                case .acOnly:
                    singleBandBody(leftX: leftX, rightX: rightX,
                                    leftRX: leftRX, rightRX: rightRX, midY: midY,
                                    sourceIcon: "powerplug.fill", sourceLabel: adapterWatts,
                                    sinkIcon: "laptopcomputer", sinkLabel: electronicsWatts,
                                    color: acColor)
                case .batteryOnly:
                    batteryOnlyBody(leftX: leftX, rightX: rightX,
                                     leftRX: leftRX, rightRX: rightRX, midY: midY)
                }
            }
            .frame(width: w, height: h)
        }
    }

    // MARK: case bodies

    @ViewBuilder
    private func acToBothBody(leftX: CGFloat, rightX: CGFloat,
                               leftRX: CGFloat, rightRX: CGFloat, midY: CGFloat) -> some View {
        let elec = max(0.1, electronicsWatts ?? 0)
        let batt = max(0.1, batteryWatts ?? 0)
        let total = elec + batt
        let elecH = Self.maxRibbonH * CGFloat(elec / total)
        let battH = Self.maxRibbonH * CGFloat(batt / total)
        let acTop = midY - Self.maxRibbonH / 2
        let acElecBot = acTop + elecH
        let acBattBot = acElecBot + battH
        let elecY = midY - Self.twoNodeOffset
        let battY = midY + Self.twoNodeOffset

        let elecRibbon = RibbonShape(x1: leftRX, y1a: acTop, y1b: acElecBot,
                                     x2: rightRX, y2a: elecY - elecH / 2, y2b: elecY + elecH / 2)
        let battRibbon = RibbonShape(x1: leftRX, y1a: acElecBot, y1b: acBattBot,
                                     x2: rightRX, y2a: battY - battH / 2, y2b: battY + battH / 2)

        flowRibbon(elecRibbon, color: acColor)
        flowRibbon(battRibbon, color: chargeColor)
        node(icon: "powerplug.fill", watts: adapterWatts, tint: acColor, at: CGPoint(x: leftX, y: midY))
        node(icon: "laptopcomputer", watts: electronicsWatts, tint: acColor, at: CGPoint(x: rightX, y: elecY))
        batteryNode(watts: batteryWatts, tint: chargeColor, at: CGPoint(x: rightX, y: battY))
    }

    @ViewBuilder
    private func acAndBatteryBody(leftX: CGFloat, rightX: CGFloat,
                                   leftRX: CGFloat, rightRX: CGFloat, midY: CGFloat) -> some View {
        let fromAC = max(0.1, adapterWatts ?? 0)
        let fromBatt = max(0.1, -(batteryWatts ?? 0))
        let total = fromAC + fromBatt
        let acH = Self.maxRibbonH * CGFloat(fromAC / total)
        let battH = Self.maxRibbonH * CGFloat(fromBatt / total)
        let acY = midY - Self.twoNodeOffset
        let battY = midY + Self.twoNodeOffset
        let compTop = midY - Self.maxRibbonH / 2
        let compACBot = compTop + acH
        let compBattBot = compACBot + battH

        let acRibbon = RibbonShape(x1: leftRX, y1a: acY - acH / 2, y1b: acY + acH / 2,
                                   x2: rightRX, y2a: compTop, y2b: compACBot)
        let battRibbon = RibbonShape(x1: leftRX, y1a: battY - battH / 2, y1b: battY + battH / 2,
                                     x2: rightRX, y2a: compACBot, y2b: compBattBot)

        flowRibbon(acRibbon, color: acColor)
        flowRibbon(battRibbon, color: drainColor)
        node(icon: "powerplug.fill", watts: adapterWatts, tint: acColor, at: CGPoint(x: leftX, y: acY))
        batteryNode(watts: batteryWatts, tint: drainColor, at: CGPoint(x: leftX, y: battY))
        node(icon: "laptopcomputer", watts: electronicsWatts, tint: drainColor, at: CGPoint(x: rightX, y: midY))
    }

    @ViewBuilder
    private func singleBandBody(leftX: CGFloat, rightX: CGFloat,
                                 leftRX: CGFloat, rightRX: CGFloat, midY: CGFloat,
                                 sourceIcon: String, sourceLabel: Double?,
                                 sinkIcon: String, sinkLabel: Double?,
                                 color: Color) -> some View {
        let h2 = Self.maxRibbonH / 2
        let ribbon = RibbonShape(x1: leftRX, y1a: midY - h2, y1b: midY + h2,
                                 x2: rightRX, y2a: midY - h2, y2b: midY + h2)
        flowRibbon(ribbon, color: color)
        node(icon: sourceIcon, watts: sourceLabel, tint: color, at: CGPoint(x: leftX, y: midY))
        node(icon: sinkIcon, watts: sinkLabel, tint: color, at: CGPoint(x: rightX, y: midY))
    }

    @ViewBuilder
    private func batteryOnlyBody(leftX: CGFloat, rightX: CGFloat,
                                  leftRX: CGFloat, rightRX: CGFloat, midY: CGFloat) -> some View {
        let h2 = Self.maxRibbonH / 2
        let ribbon = RibbonShape(x1: leftRX, y1a: midY - h2, y1b: midY + h2,
                                 x2: rightRX, y2a: midY - h2, y2b: midY + h2)
        flowRibbon(ribbon, color: drainColor)
        batteryNode(watts: batteryWatts, tint: drainColor, at: CGPoint(x: leftX, y: midY))
        node(icon: "laptopcomputer", watts: electronicsWatts, tint: drainColor, at: CGPoint(x: rightX, y: midY))
    }

    // MARK: ribbon + node helpers

    /// Filled ribbon with an optional animated highlight gliding from source
    /// (left) to sink (right). The highlight uses TimelineView, the same
    /// approach the prior battery shimmer used.
    @ViewBuilder
    private func flowRibbon(_ shape: RibbonShape, color: Color) -> some View {
        ZStack {
            shape.fill(color.opacity(0.55))
            shape.stroke(color.opacity(0.85), lineWidth: 0.6)
            if animate {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
                    GeometryReader { geo in
                        let phase = timeline.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: Self.flowDuration) / Self.flowDuration
                        let travel = geo.size.width + geo.size.width * 0.4
                        let dx = CGFloat(phase) * travel - geo.size.width * 0.4
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.45), .clear],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: geo.size.width * 0.4)
                        .offset(x: dx)
                    }
                    .clipShape(shape)
                }
            }
        }
    }

    /// Always renders the node. Zero-flow visibility is handled at the
    /// `flow`-getter level: a case body only references the nodes that
    /// belong to its scenario, so hiding individual nodes here would only
    /// strip out essential sinks (the Computer node renders `electronicsWatts`
    /// which can clamp to 0 when adapter and battery telemetry briefly
    /// disagree — the node must stay visible or the diagram makes no sense).
    private func node(icon: String, watts: Double?, tint: Color, at p: CGPoint) -> some View {
        VStack(spacing: Self.nodeVStackSpacing) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(tint)
                .frame(height: Self.glyphAreaH)
            Text(formatWatts(watts))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .frame(height: Self.nodeTextH)
        }
        .frame(width: Self.nodeAreaWidth)
        .position(x: p.x, y: p.y + Self.nodeIconOffsetY)
    }

    /// Battery node that renders a proportional-fill battery glyph (instead
    /// of an SF Symbol) so the visible fill level matches the actual charge
    /// percentage. Always renders for the same reason as `node`.
    private func batteryNode(watts: Double?, tint: Color, at p: CGPoint) -> some View {
        VStack(spacing: Self.nodeVStackSpacing) {
            BatteryGlyph(percentage: percentage, tint: tint)
                .frame(width: 40, height: Self.glyphAreaH)
            Text(formatWatts(watts))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .frame(height: Self.nodeTextH)
        }
        .frame(width: Self.nodeAreaWidth)
        .position(x: p.x, y: p.y + Self.nodeIconOffsetY)
    }
}

/// Horizontal battery glyph (rounded body + cap) with a proportional fill
/// from the left. Drawn manually because SF Symbols' battery variants only
/// come in 0/25/50/75/100 increments and can't render an arbitrary level.
private struct BatteryGlyph: View {
    let percentage: Int
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            // Pick the largest body that fits within the parent frame while
            // keeping a sensible aspect ratio (~2.5:1) and leaving room for
            // the cap. Centered both axes so the glyph sits mid-row.
            let availW = geo.size.width
            let availH = geo.size.height
            let aspect: CGFloat = 2.5
            let bodyH = min(min(availH, availW / aspect / 1.1), 18)
            let bodyW = bodyH * aspect
            let capW = max(1, bodyH * 0.18)
            let capH = bodyH * 0.5
            let totalW = bodyW + capW + 0.5
            let originX = (availW - totalW) / 2
            let originY = (availH - bodyH) / 2

            let inset = max(1, bodyH * 0.18)
            let fillMaxW = bodyW - inset * 2
            let pct = max(0, min(100, percentage))
            let fillW = fillMaxW * CGFloat(pct) / 100

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: bodyH * 0.22)
                    .stroke(tint, lineWidth: max(0.8, bodyH * 0.09))
                    .frame(width: bodyW, height: bodyH)
                    .offset(x: originX, y: originY)

                RoundedRectangle(cornerRadius: bodyH * 0.12)
                    .fill(tint)
                    .frame(width: fillW, height: bodyH - inset * 2)
                    .offset(x: originX + inset, y: originY + inset)

                RoundedRectangle(cornerRadius: capW * 0.4)
                    .fill(tint)
                    .frame(width: capW, height: capH)
                    .offset(x: originX + bodyW + 0.5, y: originY + (bodyH - capH) / 2)
            }
        }
    }
}

private struct RibbonShape: Shape {
    let x1: CGFloat
    let y1a: CGFloat
    let y1b: CGFloat
    let x2: CGFloat
    let y2a: CGFloat
    let y2b: CGFloat

    func path(in rect: CGRect) -> Path {
        Path { p in
            let midX = (x1 + x2) / 2
            p.move(to: CGPoint(x: x1, y: y1a))
            p.addCurve(to: CGPoint(x: x2, y: y2a),
                       control1: CGPoint(x: midX, y: y1a),
                       control2: CGPoint(x: midX, y: y2a))
            p.addLine(to: CGPoint(x: x2, y: y2b))
            p.addCurve(to: CGPoint(x: x1, y: y1b),
                       control1: CGPoint(x: midX, y: y2b),
                       control2: CGPoint(x: midX, y: y1b))
            p.closeSubpath()
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
            let bodyW = geo.size.width
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

// MARK: - Registration Window

extension Notification.Name {
    /// Posted by the panel's Registration row; AppDelegate owns the window.
    static let ampereShowRegistrationWindow = Notification.Name("ampere.showRegistrationWindow")
}

/// Content of the standalone registration window. A fresh instance is
/// installed on every open, so state resets and `onAppear` prefills reliably.
struct RegistrationView: View {
    @ObservedObject var registration: RegistrationManager
    var close: () -> Void

    @State private var emailInput = ""
    @State private var keyInput = ""
    private enum Field: Hashable { case email, key }
    @FocusState private var focus: Field?
    @State private var lastFocus: Field = .email

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if registration.isRegistered {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundColor(.green)
                    Text(registration.name.isEmpty
                        ? "Registered to \(registration.email)"
                        : "Registered to \(registration.name) (\(registration.email))")
                        .font(.system(size: 12, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = registration.lastError {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                Text("Deregistering frees the key so it can be registered on another Mac.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(registration.isBusy ? "Deregistering…" : "Deregister This Mac") {
                        registration.deregister { _ in }
                    }
                    .disabled(registration.isBusy)
                    Spacer()
                    Button("Done") { close() }
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                Text("Enter the email you purchased with and your registration key to activate Ampere on this Mac.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Email", text: $emailInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .focused($focus, equals: .email)
                TextField("Registration Key", text: $keyInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($focus, equals: .key)
                if let error = registration.lastError {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { close() }
                        .keyboardShortcut(.cancelAction)
                    Button(registration.isBusy ? "Registering…" : "Register") {
                        registration.register(email: emailInput, key: keyInput) { _ in }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(registration.isBusy
                        || emailInput.trimmingCharacters(in: .whitespaces).isEmpty
                        || keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .textSelection(.enabled)
        .padding(20)
        .frame(width: 340)
        .onChange(of: focus) {
            if let focus { lastFocus = focus }
        }
        .background(SheetKeyActivator {
            guard !registration.isRegistered else { return }
            // Focus is torn down while the app is inactive, and re-setting
            // the same FocusState value is a no-op — bounce through nil so
            // SwiftUI re-establishes the first responder.
            focus = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                focus = lastFocus
            }
        })
        .onAppear {
            emailInput = registration.email
            keyInput = registration.licenseKey
            registration.lastError = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if !registration.isRegistered { focus = .email }
            }
        }
    }
}

// MARK: - Sheet Key Activator

/// Keeps the hosting window key while it's on screen. Accessory-app windows
/// don't always become key when shown or when the app regains focus, which
/// leaves text fields without a blinking insertion point and Return-key
/// shortcuts dead. Drop into the root view's background; `onReactivate`
/// fires after key status is re-asserted so the host can restore focus.
struct SheetKeyActivator: NSViewRepresentable {
    /// Called after key status is re-asserted on app reactivation, so the
    /// host view can restore field focus (SwiftUI tears down the first
    /// responder while the app is inactive; key status alone won't bring
    /// the insertion point back).
    var onReactivate: (() -> Void)? = nil

    func makeNSView(context: Context) -> NSView {
        let view = KeyGrabView()
        view.onReactivate = onReactivate
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? KeyGrabView)?.onReactivate = onReactivate
    }

    private class KeyGrabView: NSView {
        var onReactivate: (() -> Void)?
        private var activationObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let activationObserver {
                NotificationCenter.default.removeObserver(activationObserver)
                self.activationObserver = nil
            }
            guard let window else { return }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKey()
            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: NSApp, queue: .main
            ) { [weak self] _ in
                // Let AppKit finish its own post-activation key-window
                // juggling first — it hands key back to the popover's
                // panel, and an immediate makeKey here would lose the race.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    guard let self, let window = self.window else { return }
                    window.makeKey()
                    self.onReactivate?()
                }
            }
        }

        deinit {
            if let activationObserver {
                NotificationCenter.default.removeObserver(activationObserver)
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
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(iconColor)
                .frame(height: 24)

            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .frame(height: 18)

            Text(title)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .frame(height: 14)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 76)
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
