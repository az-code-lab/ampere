import SwiftUI
import Shared
import AppKit
import Combine

// MARK: - Menu Bar App

/// The app: its menu bar item, the panel that hangs from it, and its
/// windows (the panel torn off into a window, the settings window, the
/// registration window). All of them are AppKit's, made and owned here;
/// main.swift runs the app on AppKit's own loop, and the menu bar is built
/// in MainMenu.
class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSMenuItemValidation {
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
    /// The settings live in a window of their own (showSettingsWindow).
    private var settingsWindow: NSWindow?
    private var settingsShowObserver: NSObjectProtocol?
    private var settingsCloseObserver: NSObjectProtocol?
    private var settingsMoveObserver: NSObjectProtocol?
    /// The panel as a window of its own, which is what tearing it off the
    /// menu bar item makes of it (detachableWindow(for:)). Made on first
    /// use and reused; its view is installed as it opens and dropped when
    /// it closes.
    private var panelWindow: NSWindow?
    /// True from the moment the torn-off panel is that window until the
    /// window is closed. Kept here and not read off the window: a minimized
    /// window and the windows of a hidden app report themselves as not
    /// visible, and both are still open.
    private var panelWindowOpen = false
    private var panelWindowObservers: [NSObjectProtocol] = []
    /// How tall the panel's view may be in its window on the screen that
    /// window is on; past that the view scrolls (fitPanelWindow).
    private let panelWindowLayout = PanelWindowLayout()
    /// Waits for the Dock to take the keyboard, on the way to showing the
    /// app's menu bar (takeMenuBar), and how many times that was begun.
    private var menuBarHandover: NSObjectProtocol?
    private var menuBarHandovers = 0
    /// True from a launch that reopened the panel's window without taking
    /// the keyboard until the app is first made active: the menu bar is
    /// looked at once then (applicationDidBecomeActive).
    private var menuBarUnchecked = false
    /// True once the app is on its way out (applicationWillTerminate).
    private var terminating = false
    private var pinnedObserver: AnyCancellable?
    private var stateObserver: AnyCancellable?
    private var registrationObserver: AnyCancellable?
    private var mouseMonitor: Any?
    private var globalMouseMonitor: Any?
    /// Re-renders the icon when the menu bar flips light/dark. Needed
    /// because the update badge forces non-template rendering (a colored
    /// dot cannot survive template recoloring), so the battery color must
    /// track the appearance manually instead of letting the system tint it.
    private var appearanceObservation: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The app is a menu bar app already: main.swift sets the accessory
        // policy before anything else runs. It turns regular only for the
        // panel's own window (setRegularApp), which the last step here
        // reopens when the previous run ended with it open.

        // 1. Status bar item first, with a placeholder icon and no click
        // handler. The OS draws the menu bar slot before the heavy
        // BatteryMonitor init runs below, so the user sees Ampere appear
        // immediately rather than after a 1-2s blank gap.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = buildMenuBarIcon(percentage: 0, hasWarning: false)
        }
        // macOS lets the user hide any menu bar item (System Settings >
        // Menu Bar) and remembers that per item across launches. The item
        // is this app's only UI, so say so in the log: every "no icon"
        // report starts here. Reopening the app shows it again (below).
        if !statusItem.isVisible {
            AmpereLog.app("Ampere: status item starts hidden by the macOS Menu Bar setting; reopen the app to show it")
        }

        // 2. Heavy init — blocks the main thread on sudo SMC writes. The
        // placeholder icon is already visible during this; clicks land on a
        // button with no action and are no-ops, which is the right behavior
        // until the popover is wired up below.
        // RegistrationManager first (cheap: defaults reads and a timer). The
        // monitor's init reads the license tier: it locks the charge bounds
        // to the defaults unless the key is a paid one, withholds Keep
        // Awake, and leaves charge control on hold for an unregistered
        // copy, all settled before its launch-time decisions.
        registration = RegistrationManager()
        monitor = BatteryMonitor(license: registration.tier)

        // 3. Wire the button to togglePopover and refresh the icon with real
        // data. Done after monitor is ready so updateMenuBarIcon can read it.
        if let button = statusItem.button {
            button.action = #selector(togglePopover)
            button.target = self
        }
        updateMenuBarIcon()

        // Create popover with the battery panel
        popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        // The popover takes its size from the panel's view, as that view
        // says it (preferredContentSize), and so knows how tall the panel is
        // whenever it places it. It used to be told 580 by 632 once, while
        // the view kept itself at its own height by constraints, 866 points
        // with every row showing: the popover was placed for the 632 and
        // then grew by the difference, upwards. With a display arranged
        // above the menu bar's, the panel covered the menu bar and reached
        // onto the display above, and a change in the item's width, which
        // makes the popover place itself again (repinPanelAnchor), moved it
        // by hundreds of points (measured through the real delegate on such
        // an arrangement, 2026-11-15; with nothing above the menu bar's
        // display the panel has always been seen under the menu bar,
        // presumably held there by the top of the screen). Its height still
        // follows its rows in one step, from under the menu bar down.
        let panel = NSHostingController(rootView: ContentView(monitor: monitor, registration: registration))
        panel.sizingOptions = [.preferredContentSize]
        popover.contentViewController = panel

        // The menu bar, now that everything its commands reach exists. The
        // app's windows are not documents: no tabs, and none of the Window
        // menu's tab commands.
        NSWindow.allowsAutomaticWindowTabbing = false
        MainMenu.install(for: self)

        // Keep popover behavior in sync: transient (auto-closes on outside
        // clicks / app deactivation) only while neither pinned nor showing a
        // sheet. A visible sheet pins the popover open exactly like the pin
        // button — see BatteryMonitor.sheetVisible for why closing under a
        // sheet must never happen.
        pinnedObserver = monitor.$pinned.combineLatest(monitor.$sheetVisible)
            .sink { [weak self] pinned, sheetVisible in
                guard let self else { return }
                self.popover.behavior = (pinned || sheetVisible) ? .applicationDefined : .transient
                // A panel that now stays, or no longer does, takes the
                // app's own windows to its layer or lets them go.
                self.levelOwnWindows()
            }

        // What the license allows is the monitor's to act on: mirror the
        // registration's tier into it. Fires for the initial value too (a
        // no-op, init already applied it) and for every later change,
        // whether from the registration window (a free or a paid key
        // registered, Deregister This Mac) or a daily verify that finds this
        // Mac off its key (released under My Licenses, or replaced on a
        // one-Mac key) or the license ended or revoked. The bounds reset,
        // the end of a Keep Awake session and the charge-control hold must
        // not depend on the panel being open, hence here and not in the view.
        registrationObserver = registration.tierPublisher
            .sink { [weak self] tier in
                guard let self else { return }
                self.monitor.licenseTier = tier
                self.applyLicenseGate(tier: tier)
            }

        // The settings window's License row and the panel's Unlock… buttons
        // post this; the window is owned here.
        registrationShowObserver = NotificationCenter.default.addObserver(
            forName: .ampereShowRegistrationWindow, object: nil, queue: .main
        ) { [weak self] _ in
            self?.showRegistrationWindow()
        }

        // The panel's Settings… link posts this one (the Settings… menu
        // command, Cmd+, comes straight here: showSettings).
        settingsShowObserver = NotificationCenter.default.addObserver(
            forName: .ampereShowSettingsWindow, object: nil, queue: .main
        ) { [weak self] _ in
            self?.showSettingsWindow()
        }

        // Update menu bar icon whenever monitor state changes
        stateObserver = monitor.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateMenuBarIcon()
            }
        }

        // Track menu bar light/dark so the non-template badge rendering
        // recolors immediately (e.g. auto appearance switch at sunset)
        // instead of waiting for the next poll-driven redraw.
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.updateMenuBarIcon()
            }
        }

        // The display badge of a Keep Awake session is filled with the
        // accent color: redraw when the user picks another one (the redraw
        // itself is decided by the color comparison in updateMenuBarIcon).
        systemColorsObserver = NotificationCenter.default.addObserver(
            forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.updateMenuBarIcon()
        }

        // The status item's window moving is the second half of every
        // width change, and what a neighboring item does to this one: the
        // attached panel's anchor is set again each time (repinPanelAnchor).
        // Matched by window at delivery, so a window the status bar makes
        // later is followed too.
        statusWindowMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let window = note.object as? NSWindow,
                  window === self.statusItem.button?.window else { return }
            self.repinPanelAnchor()
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
        // Outside the app is checked, not taken from the kind of monitor
        // this is (clickLandsOnOwnWindow).
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.popover.isShown, self.popover.behavior == .transient,
                  !Self.clickLandsOnOwnWindow(at: Self.screenLocation(of: event)) else { return }
            self.popover.performClose(nil)
        }

        // The panel was a window when the last run ended: it is one again.
        restorePanelWindow()
    }

    /// Where a mouse event happened, on screen. An event from the global
    /// monitor has no window and says so directly.
    static func screenLocation(of event: NSEvent) -> NSPoint {
        event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? event.locationInWindow
    }

    /// Whether a mouse-down at `point` lands on one of this app's own
    /// windows: the panel, a menu it opened, any of them. Asked the way
    /// macOS decides where a mouse-down goes (the frontmost window there
    /// that takes one), so a window of another app that lies over one of
    /// the app's counts as that app's.
    ///
    /// The monitor for clicks in other apps cannot be taken at its word
    /// for this. macOS tells it of this app's own clicks as well once the
    /// app has asked for another process to be put in front, which is what
    /// showing the menu bar takes (takeMenuBar hands the keyboard to the
    /// Dock for a moment): from then on every click in the attached panel
    /// was reported as a click elsewhere too, and the monitor closed the
    /// panel under the click. Measured on macOS 27 with a scratch popover
    /// and real clicks: activating the Dock is enough by itself (hiding
    /// the app does the same), the reports were still coming five seconds
    /// later, adding the monitor again changes nothing, and no window of
    /// another app behind the panel is sent the click. A click on the menu
    /// bar item is reported both ways at all times (the menu bar is another
    /// process's).
    static func clickLandsOnOwnWindow(at point: NSPoint) -> Bool {
        let number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        return NSApp.window(withWindowNumber: number) != nil
    }

    /// Launching the app while it is already running is the user asking
    /// for it, and so is a click on its Dock icon, which it has while the
    /// panel is a window. That window comes forward (out of the Dock, if it
    /// was minimized). Otherwise the status item is the only thing they can
    /// be asking for: showing it again here is the standard recovery for a
    /// menu bar item the user hid; a login launch is not a reopen, so a
    /// deliberate hide still holds there.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let statusItem, !statusItem.isVisible {
            statusItem.isVisible = true
            AmpereLog.app("Ampere: status item shown again on reopen")
        }
        if panelWindowOpen { bringPanelWindowForward() }
        return false
    }

    /// Quitting closes every window once the delegate has been told
    /// (measured on macOS 27: willTerminate, then each window's willClose).
    /// Those are not the user closing them: the panel's window is still
    /// open as far as the next launch is concerned (panelWindowWillClose).
    func applicationWillTerminate(_ notification: Notification) {
        terminating = true
    }

    /// AppKit asks before it keeps any window state for the app; the
    /// answer every current app gives, and the one the SwiftUI app
    /// lifecycle used to give for this one.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    private var lastIconPct: Int = -1
    private var lastIconCharging: Bool = false
    private var lastIconWarning: Bool = false
    private var lastIconUpdate: Bool = false
    private var lastIconDark: Bool = false
    private var lastIconShowPct: Bool = true
    private var lastIconPanelAnchored: Bool = false
    private var lastIconGated: Bool = false
    private var lastIconKeepAwake: BatteryMonitor.KeepAwakeIndicator?
    /// The accent color the last icon was drawn with (the display badge of
    /// a Keep Awake session; see renderMenuBarIcon).
    private var lastIconAccent: NSColor?
    /// The icon's hover text while the copy is gated at the registration window.
    private static let gatedToolTip = "Ampere needs a license: register one (a free license takes a name and an email address), or quit. Click to open the registration window."
    /// Whether the last rendered title occupied its full width (visible or
    /// clear glyphs, as opposed to the empty icon-only title).
    private var lastTitleWide = true
    /// True while the popover is (or is about to be) anchored to the status
    /// item: set before showing, cleared when it closes (a tear-off closes
    /// it too, and the panel is a window from then on). While set, the
    /// item width may grow but never shrink; see the title logic in
    /// updateMenuBarIcon and, for the image, anchoredIconWidth.
    private var panelAnchored = false {
        didSet { if !panelAnchored { anchoredIconWidth = 0 } }
    }
    /// The widest icon image drawn since the panel was anchored, 0 while it
    /// is not. The image keeps at least this width until the panel closes
    /// or is torn off (buildMenuBarIcon): a Keep Awake group that narrows
    /// or goes (the countdown losing a digit, the session ending) leaves
    /// clear space on the left instead of narrowing the item under the
    /// panel. The same rule the title follows, for the same reason.
    private var anchoredIconWidth: CGFloat = 0
    /// How much of the status item's button, measured from its right edge,
    /// the panel hangs from: the battery and the percent, without the Keep
    /// Awake group to their left. Set when the panel is shown; see
    /// repinPanelAnchor.
    private var panelAnchorWidth: CGFloat = 0
    private var statusWindowMoveObserver: NSObjectProtocol?
    private var systemColorsObserver: NSObjectProtocol?
    private var animationTimer: Timer?
    private var animationPct: Int = 0
    /// Fires when the Keep Awake countdown beside the icon next changes
    /// (once a minute); see scheduleKeepAwakeTick.
    private var keepAwakeTickTimer: Timer?

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
        let hasWarning = monitor.healthWarning != nil || monitor.recoveryWarning != nil
        let hasUpdate = monitor.updateAvailable != nil
        let dark = menuBarIsDark
        let showPct = monitor.showMenuBarPercent
        let now = Date()
        let keepAwake = monitor.keepAwakeIndicator(now: now)
        let accent = Self.menuBarAccent(dark: dark)

        // The Keep Awake countdown changes with the clock, which no
        // published change announces: re-arm its redraw on every pass, so
        // a new deadline, the Settings switch and a late wake from sleep
        // all land on the right minute. Ahead of the gate and the skip
        // guard below, which both return early, and from the same instant
        // as the text above: read a moment apart, the two could straddle a
        // minute and leave the old text up for the whole of the next one.
        scheduleKeepAwakeTick(now: now)

        // Gated (no license): an empty outline with no level and no percent,
        // the animation stopped, and a tooltip that says what to do. Drawn
        // once per appearance; the regular path below redraws in full once
        // the gate lifts (lastIconPct is reset so its skip guard fails).
        if licenseGated {
            if !lastIconGated || dark != lastIconDark {
                animationTimer?.invalidate()
                animationTimer = nil
                button.image = Self.renderMenuBarIcon(percentage: 0, hasWarning: false, hasUpdate: false,
                                                      darkMenuBar: dark, gated: true)
                button.attributedTitle = NSAttributedString(string: "")
                lastTitleWide = false
                lastIconGated = true
                lastIconDark = dark
                lastIconPct = -1
            }
            if button.toolTip != Self.gatedToolTip { button.toolTip = Self.gatedToolTip }
            return
        }
        lastIconGated = false

        // Refresh the hover tooltip before the render-skip guard below: the
        // status line's ETA ticks along even when nothing the icon renders
        // has changed. Assign only on a real change: every assignment
        // re-installs the tooltip, which restarts the hover delay (and hides
        // an already-visible tooltip) whenever the cursor is on the icon.
        let toolTip = menuBarToolTip()
        if button.toolTip != toolTip {
            button.toolTip = toolTip
        }

        let isAnimatingDown = monitor.activeDischarging
        let needsAnimation = isCharging || isAnimatingDown

        // Every @Published change lands here via objectWillChange (health
        // check timestamps, error strings, …). Skip the NSImage rebuild when
        // nothing the menu bar renders has changed and the animation timer
        // already matches the desired state — the timer redraws animated
        // frames on its own.
        if pct == lastIconPct, isCharging == lastIconCharging, hasWarning == lastIconWarning,
           hasUpdate == lastIconUpdate, dark == lastIconDark,
           showPct == lastIconShowPct, panelAnchored == lastIconPanelAnchored,
           keepAwake == lastIconKeepAwake, accent == lastIconAccent,
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
                    target = self.monitor.autoManageEnabled ? self.monitor.effectiveUpperBound : 100
                    self.animationPct += 5
                    if self.animationPct > target { self.animationPct = curPct }
                } else {
                    target = self.monitor.chargeUpperBound
                    self.animationPct -= 5
                    if self.animationPct < target { self.animationPct = curPct }
                }
                let warn = self.monitor.healthWarning != nil || self.monitor.recoveryWarning != nil
                button.image = self.buildMenuBarIcon(
                    percentage: CGFloat(self.animationPct),
                    hasWarning: warn,
                    hasUpdate: self.monitor.updateAvailable != nil,
                    keepAwake: self.monitor.keepAwakeIndicator()
                )
            }
        }

        lastIconPct = pct
        lastIconCharging = isCharging
        lastIconWarning = hasWarning
        lastIconUpdate = hasUpdate
        lastIconDark = dark
        lastIconShowPct = showPct
        lastIconPanelAnchored = panelAnchored
        lastIconKeepAwake = keepAwake
        lastIconAccent = accent

        let displayPct = needsAnimation ? animationPct : pct
        button.image = buildMenuBarIcon(
            percentage: CGFloat(displayPct),
            hasWarning: hasWarning,
            hasUpdate: hasUpdate,
            keepAwake: keepAwake
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
                .font: Self.menuBarTextFont
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

    /// Arm the one redraw the Keep Awake countdown needs that nothing else
    /// asks for: the moment its text changes, once a minute. One shot,
    /// re-armed by every updateMenuBarIcon pass (the redraw it triggers
    /// included), and gone while there is no countdown to show: no
    /// session, a Forever session, the time switched off in Settings, or
    /// the last minute, which ends with the session's own expiry timer.
    /// In the common run loop modes, so an open menu or a slider drag does
    /// not hold the minute back.
    private func scheduleKeepAwakeTick(now: Date) {
        keepAwakeTickTimer?.invalidate()
        keepAwakeTickTimer = nil
        guard let delay = monitor.keepAwakeIndicatorNextChange(now: now) else { return }
        // A touch past the boundary, so the pass it triggers already reads
        // the next minute.
        let timer = Timer(timeInterval: delay + 0.05, repeats: false) { [weak self] _ in
            self?.keepAwakeTickTimer = nil
            self?.updateMenuBarIcon()
        }
        RunLoop.main.add(timer, forMode: .common)
        keepAwakeTickTimer = timer
    }

    /// Hover text for the menu bar icon: the same status line the panel
    /// header shows, prefixed with the charge percent (which may be hidden
    /// from the menu bar itself), plus a running Keep Awake session, the
    /// health warning and the pending update when present — the states the
    /// icon can only signal with a wordless symbol, the orange tint and
    /// the badge dot.
    private func menuBarToolTip() -> String? {
        var lines: [String] = []
        if let state = monitor.state {
            lines.append("\(state.percentage)% — \(monitor.statusLine(for: state))")
        }
        if let keepAwake = monitor.keepAwakeToolTip {
            lines.append(keepAwake)
        }
        if let warning = monitor.healthWarning {
            lines.append(warning)
        }
        if let update = monitor.updateAvailable {
            lines.append("Ampere \(update.version) is available. Click to open the panel and update.")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// True while the copy has no license: it is held at the registration
    /// window, where the choice is to register (a free license takes a name
    /// and an email address) or to quit (the owner's call, 2026-10-16).
    /// While it holds, the window cannot be closed and stands in for the
    /// panel: the menu bar item opens it, the icon is an empty outline, and
    /// nothing else of the app is reachable. Entered at launch and the
    /// moment a registration lapses; left the moment a key registers, after
    /// which the window closes like any other. The monitor's own hold
    /// (ChargeControlHold.unlicensed) sees to it that nothing is written
    /// meanwhile.
    ///
    /// Stored, not read off the registration: the tier sink that sets it
    /// runs while the registration's own properties still hold their old
    /// values (a published property emits before it changes), so the
    /// delivered tier is the only thing that is current there.
    private var licenseGated = false

    /// Bring the window up and take the panel down when the gate engages;
    /// let the window close again when it lifts. Run for the initial tier
    /// at launch and for every change after (the tier sink).
    private func applyLicenseGate(tier: LicenseTier) {
        licenseGated = tier == .unlicensed
        if licenseGated {
            // The panel goes, attached or as a window, and the settings
            // window with it; the registration window takes their place.
            // (A sheet keeps the attached panel open until it is dismissed,
            // see popoverShouldClose; the window still comes up in front,
            // on the panel's layer, see levelOwnWindows.)
            if popover.isShown { popover.performClose(nil) }
            closePanelWindow()
            settingsWindow?.close()
            showRegistrationWindow()
        }
        // Not closable while gated: the way out is a key, or Quit.
        registrationWindow?.styleMask = licenseGated ? [.titled] : [.titled, .closable]
        updateMenuBarIcon()
    }

    /// The registration window: what Manage… on the settings window's
    /// License row and the panel's Unlock… buttons open, and what a copy
    /// with no license is held at (applyLicenseGate).
    ///
    /// The panel goes on by the rule the settings window follows. One that
    /// would close at the next click outside it (attached, not pinned, no
    /// sheet up) closes now, since that click is about to land in this
    /// window. A pinned panel stays, and so does the panel's own window.
    /// It used to close whatever its state: Manage… took a pinned or
    /// torn-off panel away with it (the owner's report, 2026-11-15).
    private func showRegistrationWindow() {
        // Already open: just bring it forward — replacing the content view
        // mid-flight would wipe whatever the user has typed.
        if let window = registrationWindow, window.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        if popover.isShown, popover.behavior == .transient {
            popover.performClose(nil)
        }
        let window = registrationWindow ?? {
            let window = NSWindow(contentRect: .zero,
                                  styleMask: licenseGated ? [.titled] : [.titled, .closable],
                                  backing: .buffered, defer: false)
            window.title = "Ampere Registration"
            // Reused across opens; a fresh RegistrationView is installed
            // each time below so the form starts clean.
            window.isReleasedWhenClosed = false
            registrationWindow = window
            return window
        }()
        // A hosting view that takes the first click (FirstMouseHostingView),
        // with the sizing NSHostingController gives a window's content: the
        // window follows the view as the form changes.
        let content = FirstMouseHostingView(rootView: RegistrationView(registration: registration) { [weak self] in
            self?.registrationWindow?.close()
        })
        content.sizingOptions = [.minSize, .intrinsicContentSize, .maxSize]
        window.contentView = content
        window.setContentSize(content.fittingSize)
        window.center()
        // In front of a panel that stays, pinned or held open by a sheet
        // (levelOwnWindows).
        levelOwnWindows()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// The layer the app's own windows (settings, registration) belong on:
    /// the attached panel's while it is on screen to stay, the ordinary one
    /// otherwise. An attached panel stays when it is pinned or held open by
    /// a sheet; one that the next click elsewhere closes (`.transient`)
    /// does not count, and neither does one that is not shown. The panel
    /// torn off is an ordinary window itself (panelWindow) and asks for
    /// nothing here.
    static func ownWindowLevel(panelShown: Bool, panelBehavior: NSPopover.Behavior,
                               panelLevel: NSWindow.Level?) -> NSWindow.Level {
        guard panelShown, panelBehavior != .transient, let panelLevel else { return .normal }
        return panelLevel
    }

    /// Keep the settings and registration windows on the attached panel's
    /// layer for as long as that panel stays on screen. Attached, the panel
    /// is a popover hung from the menu bar item, and macOS draws it on the
    /// menu bar's layer (level 25, measured on macOS 27), above every
    /// ordinary window. Opened as an ordinary window, the settings window
    /// came up behind a pinned panel wherever the two overlapped, and no
    /// click could bring it in front. On the panel's layer the windows and
    /// the panel stack like any windows: the one clicked last is in front.
    /// With no such panel they are ordinary windows again, and do not float
    /// over other apps.
    ///
    /// macOS re-sorts a window whose layer changes while it shows: raised,
    /// it lands in front of everything on its new layer, the panel
    /// included (measured). So the windows that show are put back in the
    /// order they were in, behind the panel that was in front of them a
    /// moment ago. A window that is being opened is brought forward by its
    /// caller afterwards.
    private func levelOwnWindows() {
        // Nothing to place until one of them has been opened (this runs at
        // launch too, from the pin's observer).
        let own = [settingsWindow, registrationWindow].compactMap { $0 }
        guard !own.isEmpty else { return }
        let popoverWindow = popover.isShown ? popover.contentViewController?.view.window : nil
        let level = Self.ownWindowLevel(panelShown: popover.isShown, panelBehavior: popover.behavior,
                                        panelLevel: popoverWindow?.level)
        guard own.contains(where: { $0.level != level }) else { return }
        // Front to back, as they are now.
        let shown = NSApp.orderedWindows.filter { window in window.isVisible && own.contains { $0 === window } }
        own.forEach { $0.level = level }
        var above = level == .normal ? nil : popoverWindow
        for window in shown {
            if let above { window.order(.below, relativeTo: above.windowNumber) }
            above = window
        }
    }

    /// The settings window: what the panel's Settings… link and Cmd+, open.
    /// The settings used to unfold under the panel's footer, where every
    /// new row made the panel taller; a window has room for them and for a
    /// line on what each one does (SettingsView).
    ///
    /// The panel goes on by its own rule. One that would close at the next
    /// click outside it (attached, not pinned, no sheet up) closes now,
    /// since that click is about to land in this window. A pinned panel
    /// stays, and shows what a switch here changes as it changes; the
    /// window comes up in front of it, on its layer (levelOwnWindows). The
    /// panel's own window stays as any window would. A copy with no license
    /// has no settings: it is held at the registration window
    /// (licenseGated), which comes forward instead.
    private func showSettingsWindow() {
        if licenseGated {
            showRegistrationWindow()
            return
        }
        let firstOpen = settingsWindow == nil
        let window = settingsWindow ?? {
            let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable],
                                  backing: .buffered, defer: false)
            window.title = "Ampere Settings"
            // Reused across opens; a fresh SettingsView is installed each
            // time below.
            window.isReleasedWhenClosed = false
            // Where the user drags it is where it comes back, in this run
            // and the next (saveSettingsWindowPlace). Only while it shows:
            // the moves that size and place it before it opens are saved
            // once, when they are done.
            settingsMoveObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didMoveNotification, object: window, queue: .main
            ) { [weak self, weak window] _ in
                guard let self, let window, window.isVisible else { return }
                self.saveSettingsWindowPlace()
            }
            // Asked for from another Space while it is open, it comes to
            // that Space; the default takes the user to the Space it was
            // left on, or shows nothing where macOS is set not to switch.
            window.collectionBehavior = .moveToActiveSpace
            // The view goes when the window closes. Left installed in a
            // closed window it would go on following the monitor unseen,
            // and looking for the helper's files at every poll. A turn
            // later, so it is not torn down inside the close itself; a
            // window reopened by then keeps the view it was just given.
            settingsCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak window] _ in
                DispatchQueue.main.async {
                    guard let window, !window.isVisible else { return }
                    window.contentView = NSView()
                }
            }
            settingsWindow = window
            return window
        }()
        // Already open: it comes forward as it is. Otherwise it is filled
        // and placed first, while the panel still has the keyboard (see
        // the centering below).
        if !window.isVisible {
            // A fresh view on every open: it reads the login item, which is
            // macOS's to keep and may have changed while the window was
            // closed. The hosting view takes the first click and sizes the
            // window to its rows, as the registration window's does: rows
            // come and go with the license and with admin access.
            let content = FirstMouseHostingView(rootView: SettingsView(monitor: monitor, registration: registration))
            content.sizingOptions = [.minSize, .intrinsicContentSize, .maxSize]
            window.contentView = content
            // Where it was last left: in this run, or in an earlier one
            // (the preferences keep it). It goes back there while a display
            // still shows enough of its title bar to move it by.
            let titleBar = window.frame.height - window.contentRect(forFrameRect: window.frame).height
            let lastTopLeft = firstOpen
                ? Self.savedWindowTopLeft(Self.settingsWindowTopLeftKey, in: .standard)
                : NSPoint(x: window.frame.minX, y: window.frame.maxY)
            let home = lastTopLeft.flatMap {
                Self.windowScreen(topLeft: $0, width: SettingsView.width, titleBarHeight: titleBar,
                                  screens: NSScreen.screens.map(\.visibleFrame))
            }
            // Never taller than its screen has room for (the visible
            // height less the title bar): on a small display, or with more
            // rows than there are today, the form keeps the height there
            // is and scrolls.
            if let visible = home ?? NSScreen.main?.visibleFrame {
                let room = max(visible.height - titleBar, 0)
                if content.fittingSize.height > room {
                    content.rootView = SettingsView(monitor: monitor, registration: registration,
                                                    scrollHeight: room)
                }
            }
            window.setContentSize(content.fittingSize)
            if let lastTopLeft, let home {
                // By its top-left corner, since its height follows its
                // rows, and moved up where it would now run off the bottom.
                window.setFrameOrigin(Self.windowOrigin(topLeft: lastTopLeft, size: window.frame.size, on: home))
            } else {
                // Never placed, or the display it was left on is gone:
                // centered on the screen of the key window, which is the
                // display the panel was opened on.
                window.center()
            }
            saveSettingsWindowPlace()
        }
        if popover.isShown, popover.behavior == .transient {
            popover.performClose(nil)
        }
        // Onto the layer of a panel that stays, so that it can come up in
        // front of it (levelOwnWindows).
        levelOwnWindows()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Where the settings window is kept between runs: its top-left corner
    /// in screen coordinates, as NSStringFromPoint writes it.
    static let settingsWindowTopLeftKey = "ui.settingsWindowTopLeft"

    /// The same for the panel's own window, whether that window was open,
    /// and whether it was in the Dock: the panel torn off is a window the
    /// next launch opens again as it was left (restorePanelWindow).
    static let panelWindowTopLeftKey = "ui.panelWindowTopLeft"
    static let panelWindowOpenKey = "ui.panelWindowOpen"
    static let panelWindowMinimizedKey = "ui.panelWindowMinimized"

    /// How wide the panel is, attached or as a window.
    static let panelWidth: CGFloat = 580

    /// How much of a window's title bar a display has to show for the
    /// window to count as still on it: enough to drag it by.
    static let windowGrabWidth: CGFloat = 60

    /// Keep where the settings window is, so it comes back there after a
    /// relaunch or a crash, as the settings in it do (CLAUDE.md requirement
    /// 3). The top-left corner and not the frame: the height follows the
    /// rows, which differ from one open to the next.
    private func saveSettingsWindowPlace() {
        guard let window = settingsWindow else { return }
        Self.saveWindowTopLeft(of: window, as: Self.settingsWindowTopLeftKey, in: .standard)
    }

    /// Keep a window's top-left corner under `key`.
    static func saveWindowTopLeft(of window: NSWindow, as key: String, in defaults: UserDefaults) {
        let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        defaults.set(NSStringFromPoint(topLeft), forKey: key)
    }

    /// A window's top-left corner as an earlier run left it under `key`,
    /// or nil when none ever saved one.
    static func savedWindowTopLeft(_ key: String, in defaults: UserDefaults) -> NSPoint? {
        defaults.string(forKey: key).map(NSPointFromString)
    }

    /// The display a window left at `topLeft` is still on: the one that
    /// shows the most of its title bar, as long as that is enough to drag
    /// the window by (windowGrabWidth, and half the bar's height). Nil when
    /// no display shows that much, which is a window left on a display that
    /// has since been disconnected or rearranged: it is centered then, not
    /// put back out of reach. `screens`: the visible frames of the
    /// connected displays (under the menu bar, clear of the Dock).
    static func windowScreen(topLeft: NSPoint, width: CGFloat, titleBarHeight: CGFloat,
                             screens: [NSRect]) -> NSRect? {
        let bar = NSRect(x: topLeft.x, y: topLeft.y - titleBarHeight, width: width, height: titleBarHeight)
        func shown(_ screen: NSRect) -> NSRect {
            let part = bar.intersection(screen)
            return part.isNull ? .zero : part
        }
        guard let screen = screens.max(by: { shown($0).width * shown($0).height < shown($1).width * shown($1).height })
        else { return nil }
        let part = shown(screen)
        return part.width >= windowGrabWidth && part.height >= titleBarHeight / 2 ? screen : nil
    }

    /// The frame origin (bottom-left) of a window of `size` whose top-left
    /// corner was left at `topLeft`, on the display with the visible frame
    /// `visible`. The corner is kept, except that a window that would run
    /// off the bottom is moved up to show whole (it has more rows than when
    /// it was left), and one whose top is above the visible frame is moved
    /// down under it. The top wins where both cannot hold.
    static func windowOrigin(topLeft: NSPoint, size: NSSize, on visible: NSRect) -> NSPoint {
        let y = min(max(topLeft.y - size.height, visible.minY), visible.maxY - size.height)
        return NSPoint(x: topLeft.x, y: y)
    }

    // MARK: Menu commands (MainMenu)

    /// Settings… in the application menu, Cmd+,.
    @objc func showSettings(_ sender: Any?) {
        showSettingsWindow()
    }

    /// About Ampere in the application menu: the About sheet of the panel's
    /// window, which is what has the menu bar showing in the first place
    /// (setRegularApp). The window comes forward, out of the Dock if it was
    /// minimized, and its view opens the sheet (ContentView). The attached
    /// panel has the same sheet behind About in its footer.
    @objc func showAbout(_ sender: Any?) {
        guard panelWindowOpen else { return }
        bringPanelWindowForward()
        NotificationCenter.default.post(name: .ampereShowAbout, object: nil)
    }

    /// The Help menu's links, each to the page it carries.
    @objc func openLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    /// Close Window in the File menu, Cmd+W. The attached panel closes the
    /// way a click on the menu bar item closes it (a sheet over it still
    /// refuses, see popoverShouldClose); any other window closes as its
    /// close button would, the panel's own window included, and one without
    /// a close button (the registration window while it is the only way on,
    /// a sheet) answers with the system's beep.
    @objc func closeKeyWindow(_ sender: Any?) {
        guard let window = NSApp.keyWindow else { return }
        if popover.isShown, window === popover.contentViewController?.view.window {
            popover.performClose(nil)
        } else {
            window.performClose(nil)
        }
    }

    /// What the menu bar offers right now. Close Window needs a window
    /// that has the keyboard. About Ampere needs the panel's window, with
    /// no sheet over it already (a second sheet would only wait behind the
    /// first), and showing a battery: the sheet hangs from the battery
    /// view's footer, and with no reading there is no such view to open it
    /// on (ContentView).
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(closeKeyWindow(_:)):
            return NSApp.keyWindow != nil
        case #selector(showAbout(_:)):
            return panelWindowOpen && panelWindow?.attachedSheet == nil && monitor?.state != nil
        default:
            return true
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        // Gated (no license): the registration window stands in for the panel.
        if licenseGated {
            showRegistrationWindow()
            return
        }
        // The panel is a window: the menu bar item brings it forward. It
        // may be under other windows, on another Space or in the Dock, and
        // a second panel hanging from the item beside it would show the
        // same thing twice.
        if panelWindowOpen {
            bringPanelWindowForward()
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            setPanelOnScreen(true)
            // Set before the pre-show render: the width-shrink deferral in
            // updateMenuBarIcon must be active from the first anchored frame.
            panelAnchored = true
            updateMenuBarIcon()
            // The panel hangs from the battery and the percent, not from a
            // Keep Awake group to their left: it then opens in the same
            // place with or without a session, and stays there when one
            // starts while it is open (repinPanelAnchor).
            let groupWidth = max(0, (button.image?.size.width ?? 0) - Self.menuBarBatteryWidth)
            panelAnchorWidth = max(button.bounds.width - groupWidth, 1)
            // The popover's own window, opaque again. AppKit fades that
            // window out as it turns the popover into the panel's window on
            // a tear-off, and leaves it faded: shown again, the popover was
            // in its place, with the keyboard, and fully transparent. With
            // the panel's window closed, a click on the menu bar item then
            // opened nothing that could be seen (the owner's report,
            // 2026-11-15; reproduced with a scratch popover and through
            // this delegate, the window server reporting the window at
            // alpha 0 with isShown true). Put right here, before the show
            // and not when the tear-off ends, so that nothing AppKit still
            // has running for the tear-off comes after it. Before the first
            // show the view has no window and this does nothing.
            popover.contentViewController?.view.window?.alphaValue = 1
            popover.show(relativeTo: Self.panelAnchorRect(buttonBounds: button.bounds, anchorWidth: panelAnchorWidth),
                         of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            // Force the popover's panel key so SwiftUI drag gestures (the
            // charge-bound slider thumbs) track. An accessory app's popover
            // is a non-activating panel that can come up non-key, most
            // visibly right after an in-app update relaunch, where the
            // updater's `open` and the one-time helper admin prompt disturb
            // the app's activation state. Clicks still work (the global
            // click monitor reactivates the app), but a drag needs the
            // window to stay key across the whole down/move/up sequence.
            // Re-assert once after AppKit's own post-show focus juggling
            // settles, mirroring SheetKeyActivator's 0.05s bounce.
            makePopoverWindowKey()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self, self.popover.isShown else { return }
                self.makePopoverWindowKey()
            }
        }
    }

    /// Make the popover's hosting panel the key window. See the call site in
    /// togglePopover for why an accessory app's popover needs this nudge.
    private func makePopoverWindowKey() {
        popover.contentViewController?.view.window?.makeKey()
    }

    /// The part of the status item's button the panel hangs from: its
    /// right-hand `anchorWidth` points, or all of it once it is narrower
    /// than that. Measured from the right edge because that is the edge a
    /// menu bar item keeps when its width changes.
    static func panelAnchorRect(buttonBounds: NSRect, anchorWidth: CGFloat) -> NSRect {
        let width = min(max(anchorWidth, 0), buttonBounds.width)
        return NSRect(x: buttonBounds.maxX - width, y: buttonBounds.minY, width: width, height: buttonBounds.height)
    }

    /// Keep the attached panel where it is while the status item changes
    /// around it. A popover follows its positioning rect, which is in the
    /// button's coordinates, and those start at the button's LEFT edge:
    /// the edge that moves when the item widens (a Keep Awake session
    /// started from the panel adds its group there). macOS widens an item
    /// in two steps, measured on macOS 27 with a scratch status item: the
    /// button grows in place, then, a frame or two later, its window moves
    /// so that the right edge is back where it was. The popover re-reads
    /// its rect on the first step only, where the old rect still names the
    /// right spot, and ignores the move, after which the old rect names a
    /// spot further left: the next thing that makes the popover lay itself
    /// out again (a row coming or going, which changes the panel's height)
    /// would carry the panel there. So the rect is set again, as the same
    /// right-hand part of the button, on the move: the panel does not move
    /// at all when the item widens, and follows the icon when the whole
    /// item is pushed along by a neighbor. Setting it on the first step
    /// instead makes the panel jump sideways and back. Narrowing is the
    /// case this cannot keep still (the popover clips the rect to the
    /// narrower button on the first step), which is why the item never
    /// narrows while the panel is attached: see anchoredIconWidth and the
    /// title logic in updateMenuBarIcon.
    private func repinPanelAnchor() {
        guard panelAnchored, popover.isShown, let button = statusItem.button else { return }
        popover.positioningRect = Self.panelAnchorRect(buttonBounds: button.bounds, anchorWidth: panelAnchorWidth)
    }

    // MARK: The panel as a window

    /// The panel can be dragged off the menu bar item, and what comes off
    /// is a window like any other (detachableWindow(for:)). Not while a
    /// sheet is over it: the sheet belongs to the attached panel's view,
    /// and the panel closing under it is what popoverShouldClose exists to
    /// prevent.
    func popoverShouldDetach(_ popover: NSPopover) -> Bool {
        !monitor.sheetVisible && !panelWindowOpen
    }

    /// The window the torn-off panel becomes: titled, with a close and a
    /// minimize button, on the ordinary window layer, and with it the app's
    /// own menu bar and Dock icon (setRegularApp).
    ///
    /// Left to itself AppKit keeps the popover's own window, without its
    /// arrow: a panel on the menu bar's layer, above every other window on
    /// screen, with no title bar, and still the window of an app with no
    /// menus. That is what the torn-off panel was until the owner asked for
    /// a normal window (2026-11-15).
    ///
    /// What AppKit does with the answer, measured on macOS 27 with a
    /// scratch popover and real drags: it asks once the drag has gone far
    /// enough, with the button still down, and goes on moving the popover
    /// itself under the cursor. When the button comes up it shows this
    /// window with the top-left corner of its content where the popover's
    /// content was (moved back onto the screen where that would leave its
    /// title bar under the menu bar or its foot under the Dock), makes it
    /// the key window, and closes the popover with the reason
    /// detachToWindow: see popoverDidClose. It never calls
    /// popoverDidDetach on this path, the popover never reads as detached,
    /// popoverShouldClose is not asked, and a drag let go right where it
    /// began still tears the panel off.
    func detachableWindow(for popover: NSPopover) -> NSWindow? {
        preparedPanelWindow()
    }

    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        // Refuse every close request while a sheet is up — including the
        // programmatic performClose from togglePopover (menu bar icon click).
        // The sheet must be dismissed first; then the popover closes normally.
        !monitor.sheetVisible
    }

    func popoverDidClose(_ notification: Notification) {
        // Nothing hangs from the item anymore: unpin (the next panel opens
        // unpinned), and release the deferred width shrink (this is where
        // the item narrows when the percent was hidden while the panel was
        // open).
        monitor.pinned = false
        panelAnchored = false
        updateMenuBarIcon()
        let reason = notification.userInfo?[NSPopover.closeReasonUserInfoKey] as? NSPopover.CloseReason
        if reason == .detachToWindow {
            // Torn off: the window AppKit has just put in its place is the
            // panel from here on.
            panelWindowDidOpen()
        } else if !panelWindowOpen {
            // Closed for good. A window made ready for a tear-off that
            // never came about gives its view back. (A popover closed in
            // the middle of the drag is torn off all the same: it reports
            // the tear-off and then the close, measured, and by the close
            // the window is the panel already.)
            panelWindow?.contentView = NSView()
        }
        refreshPanelOnScreen()
    }

    /// The panel's window with a fresh view in it, sized to that view, not
    /// yet on screen. The view is the panel's own in its window form (no
    /// header row: the title bar says what that row said, and a window is
    /// not pinned). A view of its own and not the popover's: AppKit shows
    /// the two side by side while it turns one into the other. `visible`:
    /// the visible frame of the screen the window is about to open on,
    /// where the caller knows it (fitPanelWindow).
    private func preparedPanelWindow(on visible: NSRect? = nil) -> NSWindow {
        let window = panelWindowShell()
        fitPanelWindow(to: visible)
        // A hosting view that takes the first click and sizes the window
        // to the panel, as the other windows' do: the panel's rows come
        // and go with the power adapter, the mode and the license.
        let content = FirstMouseHostingView(rootView: ContentView(monitor: monitor, registration: registration,
                                                                  presentation: .window,
                                                                  windowLayout: panelWindowLayout))
        content.sizingOptions = [.minSize, .intrinsicContentSize, .maxSize]
        window.contentView = content
        window.setContentSize(content.fittingSize)
        return window
    }

    /// The panel's window itself, made on first use and kept.
    private func panelWindowShell() -> NSWindow {
        if let panelWindow { return panelWindow }
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Ampere \(AppVersion.current)"
        // Reused across opens; a fresh view is installed each time.
        window.isReleasedWhenClosed = false
        // The app says itself whether this window reopens at launch, and
        // where (restorePanelWindow).
        window.isRestorable = false
        // Asked for from another Space (the menu bar item, the Dock icon),
        // it comes to that Space, as the settings window does.
        window.collectionBehavior = .moveToActiveSpace
        let center = NotificationCenter.default
        func observe(_ name: Notification.Name, _ object: Any?, _ handler: @escaping (AppDelegate) -> Void) {
            panelWindowObservers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                guard let self else { return }
                handler(self)
            })
        }
        // Where it is dragged is where the next launch opens it. Only once
        // it is the panel: AppKit moves it about on its way in.
        observe(NSWindow.didMoveNotification, window) { delegate in
            guard delegate.panelWindowOpen else { return }
            delegate.savePanelWindowPlace()
        }
        observe(NSWindow.willCloseNotification, window) { $0.panelWindowWillClose() }
        // Covered, minimized, on another Space, hidden with the app:
        // nobody is looking, and the polling slows down.
        observe(NSWindow.didChangeOcclusionStateNotification, window) { $0.refreshPanelOnScreen() }
        // In the Dock or out of it: the next launch leaves it where it was.
        observe(NSWindow.didMiniaturizeNotification, window) { $0.savePanelWindowMinimized(true) }
        observe(NSWindow.didDeminiaturizeNotification, window) { $0.savePanelWindowMinimized(false) }
        // Another screen, or the same one with another Dock or menu bar:
        // another height to fit.
        observe(NSWindow.didChangeScreenNotification, window) { $0.fitPanelWindow(to: nil) }
        observe(NSApplication.didChangeScreenParametersNotification, nil) { $0.fitPanelWindow(to: nil) }
        panelWindow = window
        return window
    }

    /// The least a screen leaves the panel's view to show itself in: under
    /// this the window keeps this height whatever the screen.
    static let panelWindowLeastRoom: CGFloat = 240

    /// How tall the panel's view may be in its window on a screen whose
    /// visible frame (under the menu bar, clear of the Dock) is
    /// `visibleHeight` tall: what the title bar leaves of it.
    static func panelWindowRoom(visibleHeight: CGFloat, titleBarHeight: CGFloat) -> CGFloat {
        max(visibleHeight - titleBarHeight, panelWindowLeastRoom)
    }

    /// Tell the panel's view how tall it may be on the screen its window is
    /// on (`visible`: that screen's visible frame, where the window is not
    /// on it yet). With every row showing the panel is 842 points tall, and
    /// 874 with its title bar: more than a 13 inch MacBook's screen has
    /// between its menu bar and a Dock at the bottom (956 points in all at
    /// its default scaling). Attached, the panel is drawn over the Dock, on
    /// the menu bar's layer; an ordinary window is not, so its last row
    /// (Settings…, About, Quit) would sit under the Dock there, with the
    /// title bar already against the menu bar and nowhere to move the
    /// window to. So the view is as tall as its rows up to the room there
    /// is, and scrolls past that (PanelWindowScroll),
    /// which is what the settings window does on a small screen.
    private func fitPanelWindow(to visible: NSRect?) {
        guard let window = panelWindow,
              let visible = visible ?? window.screen?.visibleFrame
                ?? statusItem.button?.window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        else { return }
        let titleBar = window.frame.height - window.contentRect(forFrameRect: window.frame).height
        let room = Self.panelWindowRoom(visibleHeight: visible.height, titleBarHeight: titleBar)
        // Only a change: every assignment lays the view out again.
        if panelWindowLayout.maxHeight != room { panelWindowLayout.maxHeight = room }
    }

    /// The window is the panel from here on: open as far as the next
    /// launch is concerned, and the app a regular one. Torn off just now,
    /// it is in front with the keyboard. A copy with no license has no
    /// panel (a license that lapsed in the middle of the drag): its window
    /// closes again.
    ///
    /// `restoring`: a launch reopening the window the last run left open.
    /// It comes back as it was left, in the Dock if it was minimized, and
    /// does not take the keyboard: a launch at login, or the relaunch after
    /// an update, comes while the user is doing something else. Shown that
    /// way it is in view, in front, and the app is not active (measured);
    /// the first click on it makes it so.
    private func panelWindowDidOpen(restoring: Bool = false) {
        guard let window = panelWindow, !panelWindowOpen else { return }
        guard !licenseGated else {
            window.close()
            window.contentView = NSView()
            return
        }
        let defaults = UserDefaults.standard
        let minimized = restoring && defaults.bool(forKey: Self.panelWindowMinimizedKey)
        panelWindowOpen = true
        defaults.set(true, forKey: Self.panelWindowOpenKey)
        defaults.set(minimized, forKey: Self.panelWindowMinimizedKey)
        // On its screen now, which a tear-off could only guess at.
        if !restoring { fitPanelWindow(to: nil) }
        savePanelWindowPlace()
        setRegularApp(true, takingKeyboard: !restoring)
        if minimized {
            window.miniaturize(nil)
        } else if !restoring || NSApp.isActive {
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
        }
        refreshPanelOnScreen()
    }

    /// The panel's window is closing: by its close button, Cmd+W, or
    /// because the license lapsed (closePanelWindow). The next launch does
    /// not reopen it, the view goes, and the app is a menu bar app again.
    /// Not when the app is quitting, which closes every window on its way
    /// out (applicationWillTerminate): that window is open when the next
    /// launch comes, as it is after a crash.
    private func panelWindowWillClose() {
        guard panelWindowOpen, !terminating else { return }
        panelWindowOpen = false
        UserDefaults.standard.set(false, forKey: Self.panelWindowOpenKey)
        UserDefaults.standard.set(false, forKey: Self.panelWindowMinimizedKey)
        refreshPanelOnScreen()
        // A turn later, so nothing is torn down inside the close itself; a
        // window reopened by then keeps its view and the app its Dock icon.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.panelWindowOpen else { return }
            self.panelWindow?.contentView = NSView()
            self.setRegularApp(false)
        }
    }

    /// Close the panel's window, sheet and all (the license lapsed).
    private func closePanelWindow() {
        guard panelWindowOpen, let window = panelWindow else { return }
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
        window.close()
    }

    /// Bring the panel's window in front, with the keyboard: out of the
    /// Dock if it was minimized, and back on screen if the app was hidden
    /// (activating does that).
    private func bringPanelWindowForward() {
        guard let window = panelWindow else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func savePanelWindowPlace() {
        guard let window = panelWindow else { return }
        Self.saveWindowTopLeft(of: window, as: Self.panelWindowTopLeftKey, in: .standard)
    }

    /// Keep whether the panel's window is in the Dock. Only while it is
    /// the panel, and not on the way out: quitting does not take a window
    /// out of the Dock, and whatever it does to one is not the user's doing.
    private func savePanelWindowMinimized(_ minimized: Bool) {
        guard panelWindowOpen, !terminating else { return }
        UserDefaults.standard.set(minimized, forKey: Self.panelWindowMinimizedKey)
    }

    /// Whether a launch reopens the panel's window: it was open when the
    /// last run ended, and this copy has a license to show a panel with.
    static func reopensPanelWindow(wasOpen: Bool, tier: LicenseTier) -> Bool {
        wasOpen && tier != .unlicensed
    }

    /// The panel was a window when the last run ended, by a quit, an
    /// update's relaunch or a crash: it is a window again, as it was left
    /// (CLAUDE.md requirement 3). Where it was, by its top-left corner,
    /// since its height follows its rows; moved up if it would now run off
    /// the bottom of its screen, and centered if the display it was left on
    /// is gone, the rules the settings window is placed by. In the Dock if
    /// that is where it was, and without taking the keyboard
    /// (panelWindowDidOpen). A copy with no license has no panel, and its
    /// next launch does not bring one back either.
    private func restorePanelWindow() {
        let defaults = UserDefaults.standard
        let wasOpen = defaults.bool(forKey: Self.panelWindowOpenKey)
        guard Self.reopensPanelWindow(wasOpen: wasOpen, tier: registration.tier) else {
            if wasOpen {
                defaults.set(false, forKey: Self.panelWindowOpenKey)
                defaults.set(false, forKey: Self.panelWindowMinimizedKey)
            }
            return
        }
        // The screen it was left on decides how tall it may be, so the
        // screen comes first: the window's width and title bar are the
        // same whatever is in it.
        let shell = panelWindowShell()
        let titleBar = shell.frame.height - shell.contentRect(forFrameRect: shell.frame).height
        let topLeft = Self.savedWindowTopLeft(Self.panelWindowTopLeftKey, in: defaults)
        let home = topLeft.flatMap {
            Self.windowScreen(topLeft: $0, width: Self.panelWidth, titleBarHeight: titleBar,
                              screens: NSScreen.screens.map(\.visibleFrame))
        }
        let window = preparedPanelWindow(on: home ?? NSScreen.main?.visibleFrame)
        if let topLeft, let home {
            window.setFrameOrigin(Self.windowOrigin(topLeft: topLeft, size: window.frame.size, on: home))
        } else {
            window.center()
        }
        panelWindowDidOpen(restoring: true)
    }

    /// Whether the panel can be seen: attached to the menu bar item, or a
    /// window with any part of it showing. Polling is fast (10 s) exactly
    /// while it can. The attached panel is always in view, on the menu
    /// bar's layer; its window can sit under others, in the Dock or on
    /// another Space for days, and what macOS says of it is what counts.
    static func panelIsOnScreen(popoverShown: Bool, windowOpen: Bool, windowSeen: Bool) -> Bool {
        popoverShown || (windowOpen && windowSeen)
    }

    private func refreshPanelOnScreen() {
        let seen = panelWindow?.occlusionState.contains(.visible) ?? false
        setPanelOnScreen(Self.panelIsOnScreen(popoverShown: popover.isShown, windowOpen: panelWindowOpen,
                                              windowSeen: seen))
    }

    /// Tell the monitor when the answer changes (it keeps the answer:
    /// isPanelVisible); it refreshes at once when the panel comes into view.
    private func setPanelOnScreen(_ onScreen: Bool) {
        guard onScreen != monitor.isPanelVisible else { return }
        monitor.setFastPolling(onScreen)
    }

    // MARK: Regular app while the panel is a window

    /// A regular app (Dock icon, its own menu bar, Cmd+Tab) for as long as
    /// the panel is a window, a menu bar app otherwise. A window like any
    /// other belongs to an app like any other: without this the panel's
    /// window would sit under the menus of whichever app was in front
    /// before it, with nothing in the Dock or in Cmd+Tab to find it by.
    /// The settings and registration windows go along with whatever the
    /// app is at the time.
    ///
    /// Back to a menu bar app, macOS takes the keyboard away from the app
    /// and puts the app that had it before in front (measured), which
    /// would bury a settings or registration window that is still open: the
    /// app takes the keyboard back for that window, if it had it.
    ///
    /// Neither switch reconfigured a display on macOS 27 with two external
    /// displays and no built-in one (CGDisplayRegisterReconfigurationCallback
    /// stayed silent over a dozen runs, 2026-11-15); the note in main.swift
    /// is about the launch of an earlier build.
    ///
    /// `takingKeyboard` false: a launch reopening the window, which leaves
    /// the keyboard where it is (panelWindowDidOpen). An app that is not
    /// active needs no menu bar; the first time it is made active the
    /// menus are looked at once (applicationDidBecomeActive). One that the
    /// system has already made active gets them as after a tear-off.
    private func setRegularApp(_ regular: Bool, takingKeyboard: Bool = true) {
        guard (NSApp.activationPolicy() == .regular) != regular else { return }
        if regular {
            NSApp.setActivationPolicy(.regular)
            if takingKeyboard || NSApp.isActive {
                takeMenuBar()
            } else {
                menuBarUnchecked = true
            }
        } else {
            menuBarUnchecked = false
            endMenuBarHandover()
            let wasActive = NSApp.isActive
            NSApp.setActivationPolicy(.accessory)
            if wasActive, let window = NSApp.orderedWindows.first(where: { window in
                window.isVisible && (window === settingsWindow || window === registrationWindow)
            }) {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// Show the app's menu bar, now that it is a regular app. macOS hands
    /// the menu bar over when an app becomes active, and an app that turns
    /// regular while it already is active (it is: the panel was just
    /// dragged) keeps showing the menus of the app in front before it.
    /// Activating again does nothing, with or without ignoring other apps,
    /// and neither does resigning first; hiding and showing the app works
    /// but blinks the window. What works without that is letting the Dock
    /// have the keyboard for a moment and taking it back the instant it is
    /// gone: the menu bar was the app's 20 ms later, the window never left
    /// the screen (each of these measured with a scratch app on macOS 27,
    /// read from NSWorkspace.menuBarOwningApplication).
    ///
    /// An app that is not active, as at launch, just activates, which
    /// brought its menus with it in every scratch app. Run from a test
    /// process it did not, so the outcome is read back half a second later
    /// and the Dock is asked after all where the menus are still another
    /// app's.
    private func takeMenuBar() {
        guard NSApp.isActive else {
            NSApp.activate(ignoringOtherApps: true)
            takeMenuBarIfStillAnothers()
            return
        }
        takeMenuBarThroughDock()
    }

    /// Half a second after the app was made active from not being so: the
    /// menus should be its own by now, and the Dock is asked where they are
    /// not. Once per activation it is called for, never from the handover
    /// itself, so a Mac on which the handover does not work is asked once
    /// and left alone.
    private func takeMenuBarIfStillAnothers() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.panelWindowOpen, NSApp.isActive, NSApp.activationPolicy() == .regular,
                  !Self.ownsMenuBar(NSWorkspace.shared.menuBarOwningApplication) else { return }
            self.takeMenuBarThroughDock()
        }
    }

    /// The app was made active. After a launch that reopened the panel's
    /// window without taking the keyboard this is the first time, and the
    /// moment its menus are due (setRegularApp).
    func applicationDidBecomeActive(_ notification: Notification) {
        guard menuBarUnchecked else { return }
        menuBarUnchecked = false
        takeMenuBarIfStillAnothers()
    }

    static let dockBundleIdentifier = "com.apple.dock"

    /// Whether the menu bar on screen is this app's.
    static func ownsMenuBar(_ owner: NSRunningApplication?) -> Bool {
        owner?.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }

    private func takeMenuBarThroughDock() {
        endMenuBarHandover()
        menuBarHandovers += 1
        let handover = menuBarHandovers
        menuBarHandover = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.endMenuBarHandover()
            // Only from the Dock, which is in front at this moment when the
            // handover is what took the keyboard away (measured). Anything
            // else in front is where the user has just gone, and stays.
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.dockBundleIdentifier else { return }
            NSApp.activate(ignoringOtherApps: true)
            if self.panelWindowOpen { self.panelWindow?.makeKeyAndOrderFront(nil) }
        }
        let dock = NSRunningApplication.runningApplications(withBundleIdentifier: Self.dockBundleIdentifier).first
        guard dock?.activate(options: []) == true else {
            // No Dock to hand to: the menus follow at the next activation.
            endMenuBarHandover()
            return
        }
        // The Dock never took the keyboard: stop waiting, so that the next
        // time the user turns to another app is not answered by taking the
        // keyboard back from it. (A handover begun since is not this one's
        // to end.)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.menuBarHandovers == handover else { return }
            self.endMenuBarHandover()
        }
    }

    private func endMenuBarHandover() {
        if let menuBarHandover {
            NotificationCenter.default.removeObserver(menuBarHandover)
        }
        menuBarHandover = nil
    }

    deinit {
        // pinnedObserver / stateObserver / registrationObserver are
        // AnyCancellable — they cancel
        // automatically when this AppDelegate's stored properties go out of
        // scope, so no explicit .cancel() needed here. NSKeyValueObservation
        // also self-invalidates on deinit; the explicit call just makes the
        // teardown order obvious.
        appearanceObservation?.invalidate()
        animationTimer?.invalidate()
        keepAwakeTickTimer?.invalidate()
        if let registrationShowObserver {
            NotificationCenter.default.removeObserver(registrationShowObserver)
        }
        if let settingsShowObserver {
            NotificationCenter.default.removeObserver(settingsShowObserver)
        }
        if let settingsCloseObserver {
            NotificationCenter.default.removeObserver(settingsCloseObserver)
        }
        if let settingsMoveObserver {
            NotificationCenter.default.removeObserver(settingsMoveObserver)
        }
        panelWindowObservers.forEach(NotificationCenter.default.removeObserver)
        if let menuBarHandover {
            NotificationCenter.default.removeObserver(menuBarHandover)
        }
        if let systemColorsObserver {
            NotificationCenter.default.removeObserver(systemColorsObserver)
        }
        if let statusWindowMoveObserver {
            NotificationCenter.default.removeObserver(statusWindowMoveObserver)
        }
        if let mouseMonitor = mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
        }
        if let globalMouseMonitor = globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
        }
    }

    /// True when the menu bar around the status item renders dark. Read from
    /// the button (not NSApp) so wallpaper-tinted menu bars resolve correctly.
    /// False when the status item doesn't exist yet.
    private var menuBarIsDark: Bool {
        statusItem?.button?.effectiveAppearance
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private func buildMenuBarIcon(percentage: CGFloat, hasWarning: Bool = false,
                                  hasUpdate: Bool = false,
                                  keepAwake: BatteryMonitor.KeepAwakeIndicator? = nil) -> NSImage {
        let dark = menuBarIsDark
        let image = Self.renderMenuBarIcon(
            percentage: percentage, hasWarning: hasWarning, hasUpdate: hasUpdate, darkMenuBar: dark,
            keepAwake: keepAwake, accent: Self.menuBarAccent(dark: dark), timeY: menuBarTimeY,
            minWidth: panelAnchored ? anchoredIconWidth : 0)
        // Wider while the panel is attached, never narrower (anchoredIconWidth).
        if panelAnchored { anchoredIconWidth = max(anchoredIconWidth, image.size.width) }
        return image
    }

    /// The accent color as the menu bar's own light or dark look resolves
    /// it, as a fixed color. The icon is drawn into an image, where a
    /// dynamic color would resolve against whatever appearance happens to
    /// be current, and the menu bar's follows the wallpaper, not the app.
    static func menuBarAccent(dark: Bool) -> NSColor {
        var accent = NSColor.controlAccentColor
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? accent
        }
        return accent
    }

    /// How strongly the system draws a template image and the title beside
    /// it in the menu bar: white at 90% on a dark menu bar, black at 85% on
    /// a light one. Read off the status bar button's own drawing on macOS
    /// 27 (a scratch status item, captured under each appearance); the
    /// values are the button's, not a named system color's, so they are
    /// written out here.
    static func menuBarTintAlpha(dark: Bool) -> CGFloat {
        dark ? 0.9 : 0.85
    }

    /// The battery alone: the icon's width without a Keep Awake group.
    static let menuBarBatteryWidth: CGFloat = 24 + 2.8 + 1
    static let menuBarIconHeight: CGFloat = 18
    /// The percent beside the icon (the button's title) and the Keep Awake
    /// time inside it are one font, so they read as one line of text.
    static let menuBarTextFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    private static let menuBarTextLineHeight: CGFloat =
        ceil(NSAttributedString(string: "0", attributes: [.font: menuBarTextFont]).size().height)
    /// The room a session's symbol takes, the same for both: the display
    /// badge fills it and the cup, narrower, sits against its right. So
    /// the display option switching on or off changes the symbol and
    /// nothing else; the item does not resize under the sheet that
    /// confirms the option.
    static let keepAwakeSymbolSlot: CGFloat = 24
    /// The display badge: as wide as the battery beside it, and an even
    /// height, so it sits on the battery's center line with whole points
    /// above and below.
    static let keepAwakeBadgeSize = NSSize(width: keepAwakeSymbolSlot, height: 14)
    private static let keepAwakeSymbolToTime: CGFloat = 3
    private static let keepAwakeGroupToBattery: CGFloat = 7

    /// Where the Keep Awake time sits in the icon image (the bottom of its
    /// line, from the image's bottom) when the button has no title to line
    /// it up with. Measured on macOS 27 with a scratch status item: in the
    /// 22-point button the title's 15-point line starts 3 points down and
    /// the 18-point image 2 points down, which puts the line 2 points up
    /// from the image's bottom. At that height text drawn into the image
    /// lands on the very pixel rows of the title beside it.
    static let menuBarTimeDefaultY: CGFloat = 2

    /// The same from where the button's cell puts the title and the image
    /// (their tops, in the button's flipped coordinates). Read from the
    /// cell so the two stay on one baseline wherever the system aligns the
    /// title: the measurement above is from a display with one pixel per
    /// point, and a Retina display has half points to align to. An answer
    /// more than a point off the measured one is not a layout this code
    /// knows, and falls back to it.
    static func menuBarTimeY(titleTop: CGFloat, imageTop: CGFloat) -> CGFloat {
        let y = menuBarIconHeight - (titleTop - imageTop) - menuBarTextLineHeight
        return abs(y - menuBarTimeDefaultY) <= 1 ? y : menuBarTimeDefaultY
    }

    private var menuBarTimeY: CGFloat {
        guard let button = statusItem?.button, let cell = button.cell as? NSButtonCell,
              button.image != nil, !button.attributedTitle.string.isEmpty else {
            return Self.menuBarTimeDefaultY
        }
        return Self.menuBarTimeY(titleTop: cell.titleRect(forBounds: button.bounds).minY,
                                 imageTop: cell.imageRect(forBounds: button.bounds).minY)
    }

    /// The width a Keep Awake group adds to the left of the battery, its
    /// gap to the battery included. Whole points, so the battery keeps its
    /// place on the pixel grid whatever the group holds.
    static func keepAwakeGroupWidth(_ indicator: BatteryMonitor.KeepAwakeIndicator) -> CGFloat {
        var width = keepAwakeSymbolSlot
        if let time = indicator.time {
            width += keepAwakeSymbolToTime
                + ceil(NSAttributedString(string: time, attributes: [.font: menuBarTextFont]).size().width)
        }
        return width + keepAwakeGroupToBattery
    }

    /// The cup of a session that keeps only the Mac awake, in one color
    /// (the panel row's own symbol).
    private static func keepAwakeCup(color: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    /// The badge of a session that keeps the display on: a white display
    /// on a rounded rectangle in the accent color, which is how the panel's
    /// Keep Display On button looks while it is on (the owner's pick,
    /// 2026-11-12, over a display symbol in the accent color alone). The
    /// display is drawn here, not taken from the symbol font: its outline
    /// is a one-point line on the pixel grid, which stays a clean white
    /// line where a display has one pixel per point; the symbol scaled
    /// down to this size comes out thin and pale there. `x`: the badge's
    /// left edge, a whole number of points.
    private static func drawKeepAwakeDisplayBadge(x: CGFloat, iconHeight: CGFloat, accent: NSColor) {
        let badge = keepAwakeBadgeSize
        let y = ((iconHeight - badge.height) / 2).rounded(.down)
        accent.setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: badge.width, height: badge.height),
                     xRadius: 4, yRadius: 4).fill()
        // A screen and, under it, a stub of a stand, centered in the badge.
        let screen = NSSize(width: 12, height: 8)
        let stand = NSSize(width: 4, height: 2)
        let glyphX = x + ((badge.width - screen.width) / 2).rounded(.down)
        let glyphY = y + ((badge.height - screen.height - stand.height) / 2).rounded(.down)
        NSColor.white.setStroke()
        let outline = NSBezierPath(roundedRect: NSRect(x: glyphX + 0.5, y: glyphY + stand.height + 0.5,
                                                       width: screen.width - 1, height: screen.height - 1),
                                   xRadius: 1.5, yRadius: 1.5)
        outline.lineWidth = 1
        outline.stroke()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: glyphX + ((screen.width - stand.width) / 2).rounded(.down), y: glyphY,
                                  width: stand.width, height: stand.height)).fill()
    }

    /// The icon's size: the battery, plus the Keep Awake group when a
    /// session runs, and never narrower than `minWidth` (the widest icon
    /// drawn since the panel was attached; see anchoredIconWidth).
    static func menuBarIconSize(keepAwake: BatteryMonitor.KeepAwakeIndicator? = nil,
                                minWidth: CGFloat = 0) -> NSSize {
        let group = keepAwake.map(keepAwakeGroupWidth) ?? 0
        // Every icon is a whole number of points plus the battery, and
        // `minWidth` was one of them: rounding takes it back to that
        // number exactly, so the battery cannot drift off the pixel grid.
        let reserved = (minWidth - menuBarBatteryWidth).rounded()
        return NSSize(width: max(group, reserved) + menuBarBatteryWidth, height: menuBarIconHeight)
    }

    /// Pure icon renderer. Internal (not private) so headless snapshot tests
    /// can exercise every variant without instantiating the app.
    ///
    /// Template rendering only survives while the icon is monochrome: the
    /// system recolors template images from their alpha alone, which would
    /// erase the update dot's blue, the warning's orange and the accent color
    /// of a Keep Awake session's display badge. Those variants render
    /// non-template, picking the neutral color from `darkMenuBar` manually.
    ///
    /// `keepAwake`: a running Keep Awake session, drawn to the left of the
    /// battery as its symbol and, when it has one to show, its remaining
    /// time. To the left because a menu bar item keeps its right edge when
    /// its width changes: the battery and the percent stay where they are
    /// when a session starts or ends and as the countdown loses digits.
    /// The symbol comes first so the time cannot be read as the battery's.
    /// While the display is kept on (so the Mac does not lock on its own)
    /// the symbol is a badge filled with `accent`, the one colored part,
    /// to draw the eye to that state (drawKeepAwakeDisplayBadge); the cup,
    /// the time and, unless a warning tints it, the battery stay neutral.
    /// `timeY`: see menuBarTimeY.
    static func renderMenuBarIcon(percentage: CGFloat, hasWarning: Bool,
                                  hasUpdate: Bool, darkMenuBar: Bool, gated: Bool = false,
                                  keepAwake: BatteryMonitor.KeepAwakeIndicator? = nil,
                                  accent: NSColor = .controlAccentColor,
                                  timeY: CGFloat = menuBarTimeDefaultY,
                                  minWidth: CGFloat = 0) -> NSImage {
        let size = menuBarIconSize(keepAwake: keepAwake, minWidth: minWidth)
        let image = NSImage(size: size)
        image.lockFocus()
        drawMenuBarIcon(size: size, percentage: percentage, hasWarning: hasWarning, hasUpdate: hasUpdate,
                        darkMenuBar: darkMenuBar, gated: gated, keepAwake: keepAwake, accent: accent, timeY: timeY)
        image.unlockFocus()
        image.isTemplate = menuBarIconIsTemplate(hasWarning: hasWarning, hasUpdate: hasUpdate, keepAwake: keepAwake)
        return image
    }

    static func menuBarIconIsTemplate(hasWarning: Bool, hasUpdate: Bool,
                                      keepAwake: BatteryMonitor.KeepAwakeIndicator?) -> Bool {
        !hasWarning && !hasUpdate && keepAwake?.display != true
    }

    /// Draws the icon into the current graphics context, in a `size` from
    /// menuBarIconSize: the battery against the right edge, the Keep Awake
    /// group against the battery, and any spare width clear on the left.
    /// Apart from renderMenuBarIcon so a snapshot can draw it at any scale.
    static func drawMenuBarIcon(size: NSSize, percentage: CGFloat, hasWarning: Bool,
                                hasUpdate: Bool, darkMenuBar: Bool, gated: Bool = false,
                                keepAwake: BatteryMonitor.KeepAwakeIndicator? = nil,
                                accent: NSColor = .controlAccentColor,
                                timeY: CGFloat = menuBarTimeDefaultY) {
        let battW: CGFloat = 24
        let battH: CGFloat = 11
        let capW: CGFloat = 2.8
        let totalH = size.height
        // Where the battery starts: a whole number of points (menuBarIconSize).
        let battX = (size.width - menuBarBatteryWidth).rounded()

        let templated = menuBarIconIsTemplate(hasWarning: hasWarning, hasUpdate: hasUpdate, keepAwake: keepAwake)
        // Off template rendering the neutral parts are colored by hand, in
        // the color the system gives a template image and the title beside
        // it (menuBarTintAlpha): at full strength they would come out
        // brighter than the percent next to them, and the battery would
        // brighten the moment the update dot or the display badge appeared.
        let neutralAlpha: CGFloat = templated ? 1 : menuBarTintAlpha(dark: darkMenuBar)
        let neutral = (!templated && darkMenuBar ? NSColor.white : NSColor.black).withAlphaComponent(neutralAlpha)
        let color: NSColor = hasWarning ? .systemOrange : neutral
        let colorAlpha: CGFloat = hasWarning ? 1 : neutralAlpha
        let battY = (totalH - battH) / 2

        if let keepAwake {
            let groupX = battX - keepAwakeGroupWidth(keepAwake)
            if keepAwake.display {
                drawKeepAwakeDisplayBadge(x: groupX, iconHeight: totalH, accent: accent)
            } else if let cup = keepAwakeCup(color: neutral) {
                // Against the right of the slot, so the gap to the time is
                // the badge's; on whole points, where a one-pixel-per-point
                // display draws it sharpest.
                let cupSize = cup.size
                cup.draw(in: NSRect(x: groupX + (keepAwakeSymbolSlot - cupSize.width).rounded(.down),
                                    y: ((totalH - cupSize.height) / 2).rounded(),
                                    width: cupSize.width, height: cupSize.height))
            }
            if let time = keepAwake.time {
                NSAttributedString(string: time, attributes: [.font: menuBarTextFont, .foregroundColor: neutral])
                    .draw(at: NSPoint(x: groupX + keepAwakeSymbolSlot + keepAwakeSymbolToTime, y: timeY))
            }
        }

        // Battery outline. Gated (no license, see AppDelegate.licenseGated):
        // the outline alone, dimmed, and nothing inside it.
        let outlineAlpha: CGFloat = gated ? 0.35 : 0.7
        let bodyRect = NSRect(x: battX + 0.5, y: battY + 0.5, width: battW - 1, height: battH - 1)
        let path = NSBezierPath(roundedRect: bodyRect, xRadius: 2, yRadius: 2)
        color.withAlphaComponent(outlineAlpha * colorAlpha).setStroke()
        path.lineWidth = 1
        path.stroke()

        // Battery cap
        let capRect = NSRect(x: battX + battW, y: battY + battH * 0.3, width: capW, height: battH * 0.4)
        color.withAlphaComponent(outlineAlpha * colorAlpha).setFill()
        NSBezierPath(roundedRect: capRect, xRadius: 0.8, yRadius: 0.8).fill()

        // Fill level. Clamp to [0, fillMaxW] because the animation timer
        // can briefly overshoot 100% (it bumps by +5 before the > target
        // reset fires), and without an upper clamp the fill would render
        // past the outlined boundary.
        let inset: CGFloat = 2
        let fillMaxW = battW - 1 - inset * 2
        let fillW = gated ? 0 : min(fillMaxW, max(0, fillMaxW * percentage / 100))
        let fillRect = NSRect(x: battX + 0.5 + inset, y: battY + 0.5 + inset,
                              width: fillW, height: battH - 1 - inset * 2)
        color.setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: 1, yRadius: 1).fill()

        // Update-available badge: a small blue dot over the top-right corner,
        // separated from the battery by a knocked-out ring so it reads
        // crisply over the outline, the fill, and any menu bar background.
        if hasUpdate {
            let center = NSPoint(x: battX + battW - 1, y: battY + battH - 1)
            let ringR: CGFloat = 4.6
            let dotR: CGFloat = 3.2
            if let ctx = NSGraphicsContext.current {
                ctx.compositingOperation = .destinationOut
                NSColor.black.setFill()  // only the alpha matters for the punch-out
                NSBezierPath(ovalIn: NSRect(x: center.x - ringR, y: center.y - ringR,
                                            width: ringR * 2, height: ringR * 2)).fill()
                ctx.compositingOperation = .sourceOver
            }
            NSColor.systemBlue.setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - dotR, y: center.y - dotR,
                                        width: dotR * 2, height: dotR * 2)).fill()
        }
    }
}

// MARK: - Content View

struct ContentView: View {
    /// Where the panel is shown. Attached, it hangs from the menu bar
    /// item: it leads with a row of its own that names the app and holds
    /// the pin, and a sheet over it keeps it from closing. Torn off it is a
    /// window (AppDelegate.panelWindow): the title bar says what that row
    /// said, and a window needs no pin.
    enum Presentation {
        case attached, window
    }

    @ObservedObject var monitor: BatteryMonitor
    @ObservedObject var registration: RegistrationManager
    var presentation: Presentation = .attached
    /// The window's word on how tall the view may be on its screen
    /// (PanelWindowScroll). Nil attached, where the panel is as tall as its
    /// rows.
    var windowLayout: PanelWindowLayout? = nil
    // Display preferences persist across restarts per CLAUDE.md requirement 3.
    // showAbout remains @State: it is sheet visibility, not a preference.
    // The temperature unit has no default of its own: nil until the card is
    // first clicked, and the card shows macOS's unit until then
    // (TemperatureDisplay).
    @AppStorage("ui.useFahrenheit") private var temperatureChoice: Bool?
    @AppStorage("ui.healthShowPercent") private var healthShowPercent = true
    @AppStorage("ui.ageShowYears") private var ageShowYears = true
    @AppStorage("ui.amperageShowMA") private var amperageShowMA = false
    @AppStorage("ui.rawChargeShowMAh") private var rawChargeShowMAh = false
    @State private var showAbout = false
    /// The warning sheet shown before Keep Awake's display option turns on.
    @State private var confirmKeepAwakeDisplay = false
    /// Why the authentication behind that sheet could not confirm the
    /// owner, shown in the sheet; nil until a prompt fails.
    @State private var keepAwakeDisplayFailure: String?
    @State private var pinHovering = false

    private var healthCheckTimeString: String {
        guard let time = monitor.lastHealthCheckTime else { return "n/a" }
        return healthCheckTimeLabel(time)
    }

    var body: some View {
        Group {
            // In its window the panel is never taller than the screen has
            // room for (PanelWindowScroll). Which of the two this view is
            // never changes while it lives, so nothing is rebuilt here.
            if let windowLayout {
                PanelWindowScroll(layout: windowLayout) { panel }
            } else {
                panel
            }
        }
        .onChange(of: showAbout) { mirrorSheetVisibility() }
        .onChange(of: confirmKeepAwakeDisplay) { mirrorSheetVisibility() }
        .onReceive(NotificationCenter.default.publisher(for: .ampereShowAbout)) { _ in
            // About Ampere in the menu bar (AppDelegate.showAbout), which
            // shows while the panel is a window: this view's to answer. The
            // sheet hangs from the battery view's footer, so with no battery
            // to show there is nothing to open it on.
            if presentation == .window, monitor.state != nil { showAbout = true }
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            if let state = monitor.state {
                batteryView(state)
            } else {
                noBatteryView
            }
        }
        .frame(width: AppDelegate.panelWidth)
        .background(Color(.windowBackgroundColor))
    }

    /// Mirror sheet visibility into the monitor so AppDelegate keeps the
    /// popover from closing (and breaking) underneath the sheet. The
    /// attached panel's view only: a window carries its own sheets, and a
    /// flag left set by a window that closed under one would keep the next
    /// attached panel open for good.
    private func mirrorSheetVisibility() {
        guard presentation == .attached else { return }
        monitor.sheetVisible = showAbout || confirmKeepAwakeDisplay
    }

    // MARK: - Battery View

    private func batteryView(_ state: BatteryState) -> some View {
        VStack(spacing: 16) {
            // App name centered, pin button top-right. Attached only: the
            // panel's window has the name in its title bar and no pin.
            if presentation == .attached {
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
                                .foregroundColor(monitor.pinned ? .accentColor : (pinHovering ? .primary : .secondary))
                                .rotationEffect(.degrees(monitor.pinned ? 0 : 45))
                        }
                        .buttonStyle(.plain)
                        .onHover { pinHovering = $0 }
                        .animation(.easeOut(duration: 0.15), value: monitor.pinned)
                        .animation(.easeOut(duration: 0.12), value: pinHovering)
                        .help(monitor.pinned
                            ? "Pinned: the panel stays open when you click elsewhere. Click to unpin. Drag the panel off the menu bar to make it a window."
                            : "Pin the panel open, so a click elsewhere does not close it. Drag the panel off the menu bar to make it a window.")
                    }
                }
                .padding(.top, -8)
                .padding(.trailing, 12)
            }

            // Header with battery icon
            batteryHeader(state)

            Divider().padding(.horizontal)

            // Status grid
            statusGrid(state)

            // Both mode sections write to the SMC; neither is offered while
            // another Ampere process holds charge control, this Mac has no
            // mechanism to hold a charge, or the copy has no license (the
            // status line says which; a copy with no license is held at the
            // registration window and shows this panel only while a sheet
            // keeps it from closing).
            if !monitor.controlsUnavailable {
                // While a password prompt of Ampere's own is open the
                // sections stay where they are but take no input
                // (BatteryMonitor.adminPromptUp): the panel does not jump
                // under the prompt, and no intent changes behind the
                // frozen state.
                if !monitor.autoManageEnabled && state.adapterConnected {
                    Divider().padding(.horizontal)

                    // Charge control: pause/discharge/resume
                    chargeControlSection()
                        .disabled(monitor.adminPromptUp)
                }

                if monitor.autoManageEnabled {
                    Divider().padding(.horizontal)

                    // Auto charge content (slider + discharge toggle)
                    autoManageContent(state)
                        .disabled(monitor.adminPromptUp)
                }
            }

            Divider().padding(.horizontal)

            // Keep Awake lives on the main panel, outside the mode
            // sections: it works in manual and auto mode alike, and stays
            // visible on battery, where its controls are disabled (a
            // session is AC-only: unplugging ends it, and plugging back
            // in starts nothing).
            keepAwakeRow()

            Divider().padding(.horizontal).padding(.top, 8)

            // Footer actions
            HStack(spacing: 12) {
                // The settings are a window of their own, which AppDelegate
                // owns (showSettingsWindow).
                Button {
                    NotificationCenter.default.post(name: .ampereShowSettingsWindow, object: nil)
                } label: {
                    HStack(spacing: 6) {
                        Text("Settings…")
                        // Unregistered is the one settings state worth
                        // surfacing on the link. A copy with no license is
                        // held at the registration window and shows this
                        // panel only while a sheet keeps it from closing;
                        // the link then opens that window, not the
                        // settings. The explicit color keeps the button
                        // style's tint from recoloring it. Gone entirely
                        // once registered.
                        if !registration.isRegistered {
                            Text("Unregistered")
                                .foregroundColor(.orange)
                        }
                    }
                }
                .buttonStyle(FooterButtonStyle())
                .help(registration.isRegistered
                    ? "Open the settings window: auto charge, launch at login, the menu bar item, the license, and admin access"
                    : "Unregistered: opens the registration window, where you can get a free license or enter the key from your purchase email")
                Spacer()
                if let update = monitor.updateAvailable {
                    updateControl(update)
                } else {
                    switch monitor.manualUpdateCheck {
                    case .none:
                        Button("Check for Updates") {
                            monitor.checkForUpdateNow()
                        }
                        .buttonStyle(FooterButtonStyle())
                        .help("Check for a newer version now; Ampere also checks automatically once a day")
                    case .checking:
                        Text("Checking…")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .help("Checking the Homebrew tap for a newer version")
                    case .upToDate:
                        Text("Up to Date")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .help("Ampere \(AppVersion.current) is the latest version")
                    case .failed:
                        Text("Check Failed")
                            .font(.system(size: 12))
                            .foregroundColor(.orange)
                            .help("Could not reach the update feed. Check your connection and try again, or run: brew upgrade --cask ampere")
                    case .needsNewerMacOS(let update, let macOS):
                        Text("Needs macOS \(macOS)")
                            .font(.system(size: 12))
                            .foregroundColor(.orange)
                            .help("Ampere \(update) needs macOS \(macOS) or later, and this Mac runs macOS \(SystemVersion.current). Ampere \(AppVersion.current) stays installed.")
                    }
                }
                Button("About") {
                    showAbout = true
                }
                .buttonStyle(FooterButtonStyle())
                .help("Version, website, health check result, and admin access status")
                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(FooterButtonStyle())
                .help("Quit Ampere and return the battery to standard macOS charging")
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
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Text("Website:")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                            Link("amperebattery.app", destination: AmpereLinks.website)
                                .font(.system(size: 12))
                        }
                        HStack(spacing: 4) {
                            Text("Changelog:")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                            // Display text drops the ".html" so the row fits
                            // the 300pt sheet on one line (the full URL
                            // wraps); the destination needs the extension —
                            // the extensionless path 404s on the server.
                            Link("amperebattery.app/changelog", destination: AmpereLinks.changelog)
                                .font(.system(size: 12))
                        }
                        HStack(spacing: 4) {
                            Text("Support:")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                            Link("azcode.dev", destination: AmpereLinks.support)
                                .font(.system(size: 12))
                        }
                    }
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
                                    : monitor.lastHealthCheckStatus == "FAIL" ? .red
                                    : monitor.lastHealthCheckStatus == "suspended" ? .orange : .primary)
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
                    Text(monitor.accountAuthorized
                        ? "Admin access granted for charge control."
                        : "Requires admin privileges for charge control.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    // Which mechanism is holding the charge: the inhibit key
                    // on firmware that still has it, otherwise the macOS
                    // charge limit, or neither (see chargeControlMechanism).
                    if monitor.nativeLimitMode {
                        Text("Charge control: macOS charge limit (this firmware has no CHTE key).")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        // macOS's own calibration charge, which that limit
                        // cannot stop (BatteryMonitor.nativeChargeToFullOverride),
                        // and the wait for powerd's clock once the battery is
                        // full (nativeCalibrationChargeDone).
                        if monitor.nativeChargeToFullOverride, monitor.state?.adapterConnected == true {
                            Text(monitor.nativeCalibrationChargeDone
                                ? "The calibration charge is done: the battery is full and resting. macOS keeps ignoring the charge limit until its next policy check, about 12 hours after the charge began, later if the Mac sleeps through it; nothing ends it sooner, a restart included. Ampere then holds at the level reached; Discharge to Upper Bound brings it back down."
                                : "macOS is charging the battery to full to calibrate its gauge, as it does every few weeks under a charge limit, and ignores the limit until it finishes. Ampere then holds at the level reached; Discharge to Upper Bound brings it back down.")
                                .font(.system(size: 12))
                                .foregroundColor(.orange)
                        }
                    } else if monitor.chargeControlHold == .noMechanism {
                        Text("Charge control: unavailable. This firmware has no CHTE key, and this macOS has no charge limit (System Settings > Battery) to hand a target to; Ampere monitors only, and checks again at every poll.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    } else if monitor.chargeControlHold == .mechanismUnknown {
                        Text("Charge control: not decided yet. The SMC did not answer when asked for its CHTE key; Ampere asks again at every poll and writes nothing until it does.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    } else if monitor.chargeControlHold == .unlicensed {
                        // Registered again, with the takeover waiting for
                        // a password prompt of Ampere's own that is still
                        // open (BatteryMonitor.chargeControlResuming).
                        Text(monitor.chargeControlResuming
                            ? "Charge control: the license is registered. Ampere takes charge control once the admin password prompt that is still open has been answered."
                            : "Charge control: on hold until this copy is registered. A free license is enough; a paid license adds custom charge bounds and Keep Awake.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    } else if monitor.chargeControlHold == .adminPrompt {
                        Text("Charge control: frozen while an admin password prompt of Ampere's is open. An active discharge was stopped and a charge short of full paused first, as before a sleep; nothing is written until the prompt is answered, and charge control goes on from there.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
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
                    animate: monitor.isPanelVisible
                )
                .frame(width: 240, height: 110)

                Text("\(state.percentage)%")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(.primary)
                    .contentTransition(.numericText(value: Double(state.percentage)))
                    .animation(.snappy(duration: 0.3), value: state.percentage)
            }

            // Charging status label + time remaining
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor(state))
                    .frame(width: 8, height: 8)

                Text(monitor.statusLine(for: state))
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
        // A hold, or the last error, ahead of everything about the battery
        // (BatteryMonitor.chargeControlNotice; the settings window shows
        // the same notice).
        if let notice = monitor.chargeControlNotice { return notice.text }
        if let warning = monitor.healthWarning { return warning }
        if let warning = monitor.recoveryWarning { return warning }
        // macOS's own calibration charge (BatteryMonitor.
        // nativeChargeToFullOverride): the limit that does the holding on
        // this firmware is ignored until it ends, so neither "holding" nor
        // "charging to 70%" would be true, and nothing of ours can stop it.
        // Once the battery is full the charge is done but the override is
        // not: powerd lifts it by the clock, about 12 hours after it began
        // (nativeCalibrationChargeDone), so the line says that instead of
        // "charging to full" for a battery that is full and resting.
        if monitor.chargeLimitOverridden && state.adapterConnected {
            if monitor.nativeCalibrationChargeDone {
                return monitor.autoManageEnabled
                    ? "Auto: overridden — calibration charge done, macOS lifts the override within about 12 hours"
                    : "Pause overridden — calibration charge done, macOS lifts the override within about 12 hours"
            }
            return monitor.autoManageEnabled
                ? "Auto: overridden — macOS is charging to full to calibrate the battery"
                : "Pause overridden — macOS is charging to full to calibrate the battery"
        }
        if monitor.activeDischarging {
            // Native mode: the firmware drains to the bound on its own once
            // the macOS charge limit applies (up to a minute after the
            // target is set); sleep is never overridden there.
            if monitor.nativeLimitMode {
                if (state.amperage ?? 0) > 0 {
                    return "Discharge starting: macOS charge limit set to \(monitor.chargeUpperBound)%"
                }
                return "Discharging to \(monitor.chargeUpperBound)% through the macOS charge limit"
            }
            // SMC discharge has been requested but may not have engaged yet
            // (transient at startup or just after toggling the feature on).
            // Describe the *current* state — the battery is still gaining
            // charge — instead of claiming the system is discharging.
            if (state.amperage ?? 0) > 0 {
                return "Discharge starting — sleep is temporarily disabled"
            }
            return "Discharging to \(monitor.chargeUpperBound)% — sleep is temporarily disabled"
        }
        // Sleep hold: a below-lower charge is keeping the Mac awake so a
        // closed lid can't strand it mid-charge. Announced like the
        // discharge override above — the user should know why their Mac
        // isn't sleeping.
        if monitor.autoManageEnabled && monitor.sleepHoldActive && state.adapterConnected {
            return "Auto: charging to \(monitor.chargeUpperBound)% — sleep is disabled until then"
        }
        // Charge-to-full: announce the target even while the allow write is
        // still in flight (amperage ≤ 0 for a beat after toggling) — without
        // this, the paused branch below would flash "not charging" copy the
        // instant after the user asked for a full charge.
        if monitor.autoManageEnabled && monitor.chargeToFull && state.adapterConnected {
            return "Auto: charging to full"
        }
        if monitor.autoManageEnabled && monitor.chargingPaused {
            // "drains to X% under load" implies passive drain via the adapter
            // rail — only accurate on AC. On battery, the battery drains
            // directly regardless of CHTE, so fall through to the generic
            // "holding" message which is still accurate. In native mode a
            // hold pins the level exactly (the Mac runs from the adapter),
            // so the generic message is the accurate one there too.
            if !monitor.nativeLimitMode && state.adapterConnected && state.percentage > monitor.chargeUpperBound {
                return "Auto: not charging — drains to \(monitor.chargeUpperBound)% under load"
            }
            return "Auto: holding — charges below \(monitor.chargeLowerBound)% or on demand"
        }
        // Use amperage's sign rather than `state.isCharging` for the same
        // transient-consistency reason as `BatteryModeRouter` — IOKit's
        // `isCharging` can lag the actual current direction.
        if monitor.autoManageEnabled, (state.amperage ?? 0) > 0 {
            return "Auto: charging to \(monitor.effectiveUpperBound)%"
        }
        // chargingPaused can briefly persist after a manual-mode unplug
        // (until the next refresh tick clears it), so require adapterConnected
        // here to avoid "Running on AC power" while actually on battery.
        if monitor.chargingPaused && state.adapterConnected { return "Running on AC power — battery will not charge" }
        if !state.adapterConnected { return "Connect power adapter to control charging" }
        return ""
    }

    private func statusMessageColor(_ state: BatteryState) -> Color {
        // Mirrors statusMessage's first branch.
        if let notice = monitor.chargeControlNotice { return notice.kind.color }
        if monitor.healthWarning != nil { return .red }
        if monitor.recoveryWarning != nil { return .red }
        // Mirrors statusMessage's override branch: orange, like the other
        // states where something other than the user's setting has the
        // battery.
        if monitor.chargeLimitOverridden && state.adapterConnected { return .orange }
        if monitor.activeDischarging { return .orange }
        // Mirrors statusMessage's sleep-hold branch: same orange treatment
        // as discharge, since both mean "sleep is being overridden".
        if monitor.autoManageEnabled && monitor.sleepHoldActive && state.adapterConnected { return .orange }
        // Match statusMessage's branching: blue for auto-hold (regardless of AC)
        // or manual pause while on AC. A manual-mode chargingPaused with no
        // adapter falls through to the "Connect power adapter" prompt, which
        // should be secondary, not blue.
        if monitor.chargingPaused && (monitor.autoManageEnabled || state.adapterConnected) { return .blue }
        return .secondary
    }

    private func statusGrid(_ state: BatteryState) -> some View {
        // Read at every render, so a card that was never clicked follows
        // the unit macOS is set to.
        let useFahrenheit = TemperatureDisplay.usesFahrenheit(stored: temperatureChoice)
        let tempValue = TemperatureDisplay.label(celsius: state.temperature, fahrenheit: useFahrenheit)

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
            StatCard(title: "Cycle Count", value: "\(state.cycleCount)", icon: "arrow.triangle.2.circlepath", iconColor: tint,
                help: "Completed charge cycles over the battery's life")
            StatCard(title: "System Load", value: formatWatts(state.electronicsWatts), icon: "desktopcomputer", iconColor: tint,
                help: "Power the Mac's electronics are drawing right now")
            StatCard(title: "Adapter Load", value: formatWatts(state.adapterWatts), icon: "bolt.horizontal.fill", iconColor: adapterTint,
                help: "Power the adapter is delivering right now")
            StatCard(title: "Battery Load", value: formatWatts(state.batteryWatts), icon: "bolt.horizontal.fill", iconColor: tint,
                help: "Power flowing into the battery (charging) or out of it (draining)")

            // Row 1
            StatCard(title: "Battery Served",
                value: ageShowYears
                    ? (state.batteryAgeYears.isEmpty ? "—" : state.batteryAgeYears)
                    : (state.batteryAgeDays.isEmpty ? "—" : state.batteryAgeDays),
                icon: "calendar.badge.clock", iconColor: tint, onTap: {
                    ageShowYears.toggle()
                }, help: "Battery age since manufacture — click to show in \(ageShowYears ? "days" : "years")")
            StatCard(title: "Temperature", value: tempValue, icon: "thermometer.medium", iconColor: tint, onTap: {
                // The click's choice is kept from here on, whichever unit
                // macOS is set to.
                temperatureChoice = !useFahrenheit
            }, help: "Battery temperature — click to show in °\(useFahrenheit ? "C" : "F")")
            StatCard(title: "Adapter Voltage", value: voltageValue(state.adapterVoltage), icon: "bolt.fill", iconColor: adapterTint,
                help: "Voltage at the power adapter")
            StatCard(title: "Battery Voltage", value: voltageValue(state.voltage), icon: "bolt.fill", iconColor: tint,
                help: "Voltage across the battery")

            // Row 2
            StatCard(title: "Health", value: healthValue, icon: "stethoscope", iconColor: tint, onTap: {
                healthShowPercent.toggle()
            }, help: "Full-charge capacity vs design capacity — click to show \(healthShowPercent ? "mAh" : "percent")")
            StatCard(title: "Raw Charge",
                value: rawChargeShowMAh
                    ? "\(state.currentCapacity)/\(state.maxCapacity) mAh"
                    : (state.maxCapacity > 0
                        ? String(format: "%.1f%%", Double(state.currentCapacity) / Double(state.maxCapacity) * 100)
                        : "\(state.percentage)%"),
                icon: "percent", iconColor: tint, onTap: {
                    rawChargeShowMAh.toggle()
                }, help: "Current charge vs full-charge capacity — click to show \(rawChargeShowMAh ? "percent" : "mAh")")
            StatCard(title: "Adapter Current", value: amperageValue(state.adapterAmperage), icon: "directcurrent", iconColor: adapterTint, onTap: {
                amperageShowMA.toggle()
            }, help: "Current from the power adapter — click to show \(amperageShowMA ? "amps" : "milliamps")")
            StatCard(title: "Battery Current", value: amperageValue(state.amperage), icon: "directcurrent", iconColor: tint, onTap: {
                amperageShowMA.toggle()
            }, help: "Current into or out of the battery — click to show \(amperageShowMA ? "amps" : "milliamps")")
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

    private func keepAwakeRow() -> some View {
        let onPower = monitor.state?.adapterConnected ?? false
        let locked = monitor.keepAwakeLocked
        return HStack {
            // Bare glyph in the shared 26 pt frame like the other main-panel
            // rows (the *.circle.fill family is the settings window's).
            // Coffee cup: the universal keep-awake metaphor (caffeinate). A
            // lock while the feature is withheld, like the bounds row's.
            Image(systemName: locked ? "lock.fill" : "cup.and.saucer.fill")
                .font(.system(size: 14))
                .foregroundColor(!locked && monitor.keepAwakeEnabled ? .accentColor : .secondary)
                .frame(width: 26)
            Text("Keep Awake")
                .font(.system(size: 13, weight: .semibold))
            if monitor.keepAwakeEnabled, let deadline = monitor.keepAwakeDeadline {
                Text("until " + deadline.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
            if locked {
                // Keep Awake is a paid feature: the controls make way for
                // the Unlock… button the bounds row ends in too (a quiet
                // text control, not a sales line; the owner's call,
                // 2026-10-16). The lock stays grey for the same reason: a
                // free license is nothing to put right.
                UnlockButton()
            } else {
                keepAwakeControls(onPower: onPower)
            }
        }
        .padding(.horizontal, 16)
        .help(locked
            ? "Keep Awake needs a paid license: it keeps the Mac awake while a power adapter is connected, for a chosen duration, with an option to keep the display on. Unlock… opens the registration window; a paid license also unlocks custom charge bounds."
            : !onPower
            ? "Unavailable on battery: the Mac sleeps normally. Connect a power adapter to turn Keep Awake on; unplugging ends a session, and plugging back in does not restart it."
            : monitor.keepAwakeEnabled
            ? "On: keeping the Mac awake for the selected duration. \(monitor.keepAwakeDisplay ? "The display is kept on too, so the Mac does not lock on its own." : "The display still sleeps on its own schedule.") Turn off to allow normal sleep; unplugging the power adapter ends the session too."
            : "Off: normal macOS sleep. Turn on to keep the Mac awake for the selected duration while the power adapter is connected; unplugging ends the session. The display sleeps normally unless the display button beside the duration is on.")
        .sheet(isPresented: $confirmKeepAwakeDisplay) {
            keepAwakeDisplayWarning
        }
    }

    /// The row's controls while Keep Awake is offered (a paid license):
    /// the display option, the duration, the switch.
    @ViewBuilder
    private func keepAwakeControls(onPower: Bool) -> some View {
        // Both switches are AC-only and disabled (not hidden) on
        // battery, where a session cannot exist: unplugging ends the
        // session and turns both off, and plugging back in starts
        // nothing. The display option is an option of the running
        // session, so it is also disabled while the toggle is off, and
        // on the way on it is confirmed (the sheet below) and then
        // the owner authenticates (requestKeepAwakeDisplay): it is the
        // one switch here that changes who can use the Mac, not just
        // whether it sleeps.
        Toggle(isOn: Binding(
            get: { monitor.keepAwakeDisplay },
            set: { on in
                if on {
                    keepAwakeDisplayFailure = nil
                    confirmKeepAwakeDisplay = true
                } else {
                    monitor.turnOffKeepAwakeDisplay()
                }
            }
        )) {
            Image(systemName: "display")
        }
        .toggleStyle(.button)
        .controlSize(.small)
        .disabled(!onPower || !monitor.keepAwakeEnabled)
        .help(!onPower
            ? "Unavailable on battery: the display sleeps and the screen locks on its own schedule. Connect a power adapter and turn Keep Awake on to keep the display on during the session."
            : !monitor.keepAwakeEnabled
            ? "Unavailable while Keep Awake is off: turn Keep Awake on first, then turn this on to keep the display on during the session; the Mac will then not lock on its own."
            : monitor.keepAwakeDisplay
            ? "On: the display stays on during this Keep Awake session, so the Mac does not lock on its own. Turn off to let the display sleep and the screen lock as usual. Turns off with Keep Awake."
            : "Off: the display sleeps and the screen locks on its own schedule. Turn on to keep the display on during this Keep Awake session; the Mac will then not lock on its own. Asks for Touch ID or your password.")
        Picker("", selection: Binding(
            get: { monitor.keepAwakeMinutes },
            set: { monitor.setKeepAwakeDuration(minutes: $0) }
        )) {
            ForEach(BatteryMonitor.keepAwakeDurations, id: \.self) { minutes in
                Text(BatteryMonitor.keepAwakeDurationLabel(minutes)).tag(minutes)
            }
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .fixedSize()
        .help("How long a keep-awake session lasts; Forever holds until toggled off. Changing it while on restarts the countdown from now.")
        Toggle("", isOn: Binding(
            get: { monitor.keepAwakeEnabled },
            set: { monitor.setKeepAwake($0) }
        ))
        .toggleStyle(.switch)
        .controlSize(.small)
        .disabled(!onPower)
    }

    /// Shown before the display option turns on: what it gives up, what
    /// it cannot promise, and that the owner confirms it. The option only
    /// turns on from its button, and only after the authentication prompt
    /// (requestKeepAwakeDisplay). The sheet waits for the prompt's answer
    /// with both buttons disabled (the prompt's own Cancel is the way
    /// out), and stays up on a declined or failed prompt so the user can
    /// try again or cancel; sheetVisible pins the popover open for the
    /// whole of it, prompt included.
    private var keepAwakeDisplayWarning: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Keep the display on?")
                .font(.headline)
            Text("While this Keep Awake session runs, the display stays on and the Mac does not lock on its own. Anyone at the Mac can use it until you lock it or the session ends, so turning this on asks for Touch ID or your password first.")
                .font(.system(size: 12))
            Text("A screen saver that is set to start may still start and lock the screen. Closing the lid, a hot corner, a manual lock, and a lock your organization manages all work as before. Turning Keep Awake off or unplugging the power adapter ends the session and turns this off.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            // A line of its own: beside the buttons, a long system
            // message would squeeze them into truncation.
            if let why = keepAwakeDisplayFailure {
                Text(why)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
            }
            HStack {
                if monitor.keepAwakeDisplayAuthenticating {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button("Cancel") { confirmKeepAwakeDisplay = false }
                    .keyboardShortcut(.cancelAction)
                    .disabled(monitor.keepAwakeDisplayAuthenticating)
                Button("Keep Display On") {
                    keepAwakeDisplayFailure = nil
                    monitor.requestKeepAwakeDisplay { end in
                        switch end {
                        case .on, .noSession: confirmKeepAwakeDisplay = false
                        case .declined: break
                        case .failed(let why): keepAwakeDisplayFailure = why
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(monitor.keepAwakeDisplayAuthenticating)
            }
        }
        .padding(20)
        .frame(width: 340)
        .background(SheetKeyActivator())
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
                minGap: Double(BatteryMonitor.chargeBoundMinGap),
                upperOverridden: monitor.chargeToFull,
                locked: monitor.chargeBoundsLocked
            )
            .frame(height: 68)
            .padding(.top, 2)
            .background(WindowDragBlocker())

            // Custom bounds are the paid feature. The slider stays fully
            // drawn while locked (the default range really is in force) but
            // its draggers refuse input, so this row explains the refusal
            // and links to the only way to lift it.
            if monitor.chargeBoundsLocked {
                ChargeBoundsLockRow(lower: monitor.chargeLowerBound, upper: monitor.chargeUpperBound)
            }

            // Both bound-relative rows are subsumed while charge-to-full is
            // active: charge-to-upper by the higher target, and discharge
            // because activating charge-to-full turned the preference off —
            // showing the row would invite re-enabling it against the
            // in-progress full charge. Both rows are also adapter-gated,
            // like Charge to Full below and the manual Pause/Resume button:
            // they drive AC charging behavior, so on battery the toggles
            // would be inert until the next plug-in.
            if !monitor.chargeToFull && state.adapterConnected {
                if state.percentage > monitor.chargeUpperBound {
                    HStack {
                        Image(systemName: "arrow.down.to.line")
                            .font(.system(size: 14))
                            .foregroundColor(monitor.autoDischargeEnabled ? .accentColor : .secondary)
                            .frame(width: 26)
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
                    .help(monitor.nativeLimitMode
                        ? "Actively drain the battery to the upper bound through the macOS charge limit; the firmware does the draining, so sleep is unaffected"
                        : "Actively drain the battery to the upper bound; sleep is disabled while discharging")
                } else if state.percentage >= monitor.chargeLowerBound && state.percentage < monitor.chargeUpperBound {
                    HStack {
                        Image(systemName: "arrow.up.to.line")
                            .font(.system(size: 14))
                            .foregroundColor(monitor.chargeToUpperBound ? .accentColor : .secondary)
                            .frame(width: 26)
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
                    .help("Charge to the upper bound now; otherwise charging waits until the battery falls below the lower bound")
                }
            }

            // One-shot full charge — the ticket-requested quick way to reach
            // full without touching the bounds. Needs AC to do anything, and
            // hides when the battery already reports full (fullyCharged
            // covers worn batteries whose BMS terminates below a displayed
            // 100%) — unless still active, so the user can see it complete.
            if state.adapterConnected
                && ((state.percentage < 100 && !state.fullyCharged) || monitor.chargeToFull) {
                HStack {
                    // Same arrow family as the two rows above, which this can
                    // stack with: to-line arrows stop at the bound, the bare
                    // up arrow runs to full. The shared fixed frame (also on
                    // those rows) keeps the stacked text edges aligned.
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14))
                        .foregroundColor(monitor.chargeToFull ? .accentColor : .secondary)
                        .frame(width: 26)
                    Text("Charge to Full")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { monitor.chargeToFull },
                        set: { monitor.setChargeToFull($0) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
                .help("One-time charge to full without changing the bounds. Turns Discharge to Upper Bound off; clears when full, when the adapter is unplugged, or when toggled off.")
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
                .help("Allow the battery to charge normally again")
            } else {
                Button(action: { monitor.toggleCharging() }) {
                    Label("Pause Charging", systemImage: "pause.fill")
                }
                .buttonStyle(ChargeButtonStyle(color: .orange))
                .help("Stop charging and hold the current level; the Mac keeps running on AC power")
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Footer (update control, About sheet)

    /// Footer control for a pending update. Idle/failed → a clickable
    /// "Update to X" button (failed adds a warning icon whose tooltip carries
    /// the error and the brew fallback); while working → progress text. The
    /// install quits and relaunches the app, which is the same
    /// persisted-state path as a normal quit/restart.
    @ViewBuilder
    private func updateControl(_ update: AvailableUpdate) -> some View {
        switch monitor.updateState {
        case .downloading(let fraction):
            HStack(spacing: 4) {
                Text("Downloading… \(Int((fraction * 100).rounded()))%")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                // A stalled connection would otherwise pin the footer here
                // until URLSession's timeouts fire, with quitting the app as
                // the only recourse.
                Button {
                    monitor.cancelUpdate()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                }
                .buttonStyle(FooterButtonStyle())
                .help("Cancel the download — the Update button returns and nothing is changed")
            }
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
                // Blue pairs with the menu bar badge dot: one color for
                // "update" everywhere, keeping orange exclusive to warnings
                // (the failed-state triangle above stays orange for that
                // reason).
                .buttonStyle(FooterButtonStyle(tint: .blue, hoverTint: .blue))
                .help("Download v\(update.version), verify, install, and relaunch. Currently on \(AppVersion.current).")
            }
        }
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

}

// MARK: - Panel Window Layout

/// What the panel's window tells its view about the screen it is on: how
/// tall the view may be there (AppDelegate.fitPanelWindow). No limit until
/// the window has said.
final class PanelWindowLayout: ObservableObject {
    @Published var maxHeight: CGFloat = .infinity
}

/// The panel in its window: as tall as its rows, up to the height its
/// screen has room for, and scrolling past that. A scroll view at all
/// times, so the panel is not rebuilt (and a sheet over it not dropped)
/// when the limit starts or stops to bind; while everything fits it has
/// nothing to scroll and no rubber band. Its width and height are fixed
/// both ways, which is what makes the hosting view size the window to it
/// and follow it as the rows come and go.
struct PanelWindowScroll<Content: View>: View {
    @ObservedObject var layout: PanelWindowLayout
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView(.vertical) { content() }
            .scrollBounceBehavior(.basedOnSize)
            .frame(width: AppDelegate.panelWidth)
            .frame(maxHeight: layout.maxHeight)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Status line (panel header + menu bar tooltip)

extension BatteryMonitor {
    /// "Charging — Xh Ym to NN%" / "Discharging — Xm remaining" / etc.
    /// Combines `statusText` with `displayedTimeRemaining` and computes the
    /// ETA once per call. Lives on the monitor (not ContentView) because the
    /// menu bar icon's hover tooltip shows the same line as the panel
    /// header — one source so the two can never disagree.
    func statusLine(for state: BatteryState) -> String {
        let trailing = displayedTimeRemaining(for: state)
        return trailing.isEmpty ? statusText(for: state) : "\(statusText(for: state)) — \(trailing)"
    }

    private func statusText(for state: BatteryState) -> String {
        if (state.amperage ?? 0) > 0 { return "Charging" }
        if activeDischarging { return "Discharging" }
        if chargingPaused && state.adapterConnected { return "On AC Power (Not Charging)" }
        if state.isCharging { return "Charging" }
        if state.adapterConnected { return "On AC Power" }
        return "On Battery"
    }

    /// Compute our own ETA from the live amperage so the label is consistent
    /// across charging/discharging modes and doesn't go silent in scenarios
    /// IOKit doesn't track (active SMC discharge, weak adapter making the
    /// battery supplement). Falls back to `state.timeRemaining` only when
    /// the computation can't run — that path still serves the on-battery
    /// "Xh Ym remaining" case via IOKit's smart `TimeToEmpty` estimator.
    private func displayedTimeRemaining(for state: BatteryState) -> String {
        let eta = TimeRemainingRouter.label(
            percentage: state.percentage,
            maxCapacity: state.maxCapacity,
            amperage: state.amperage,
            autoManageEnabled: autoManageEnabled,
            activeDischarging: activeDischarging,
            // Where the charge stops: 100 while charge-to-full is active
            // and during macOS's calibration charge, which also selects the
            // "to full" suffix; otherwise the upper bound.
            upperBound: chargingTarget
        )
        return eta.isEmpty ? state.timeRemaining : eta
    }
}

// MARK: - Charge control notice (panel status message + settings window)

extension BatteryMonitor {
    /// What charge control has to say ahead of anything about the battery:
    /// why this instance is not managing it, or the last thing that went
    /// wrong. The panel's status message leads with it. The settings
    /// window, which has no status line, shows it above its rows: its Auto
    /// Charge switch and Revoke are what a hold disables and what raise
    /// most of the errors, and the panel is usually closed while it is
    /// open. One source, so the two can never disagree.
    struct ChargeControlNotice: Equatable {
        enum Kind: Equatable {
            /// Another instance holds charge control; nothing is wrong here.
            case standby
            /// Charge control is on hold, for the reason the text gives.
            case hold
            /// The last charge-control action failed.
            case error
        }
        let text: String
        let kind: Kind
    }

    var chargeControlNotice: ChargeControlNotice? {
        switch chargeControlHold {
        case .otherInstance(let other):
            return ChargeControlNotice(text: "Charge control is in use by \(other)", kind: .standby)
        case .accessDeclined:
            return ChargeControlNotice(
                text: "Admin access required for charge control. Pause charging or re-enable Auto Charge to grant it.",
                kind: .hold)
        case .noMechanism:
            return ChargeControlNotice(
                text: "Charge control unavailable: this firmware has no CHTE key and this macOS has no charge limit. Monitoring only; Ampere checks again at every poll.",
                kind: .hold)
        case .mechanismUnknown:
            return ChargeControlNotice(
                text: "Charge control on hold: the SMC did not answer. Ampere asks again at every poll.",
                kind: .hold)
        case .unlicensed:
            // Registered again, with the takeover waiting for a password
            // prompt of Ampere's own that is still open
            // (chargeControlResuming): asking for a license here would be
            // asking for one it has.
            return ChargeControlNotice(
                text: chargeControlResuming
                    ? "Charge control on hold: waiting for the admin prompt that is still open. Ampere takes charge control once it is answered."
                    : "Charge control needs a license: register one in the registration window, or quit",
                kind: .hold)
        case .adminPrompt:
            return ChargeControlNotice(
                text: "Charge control is frozen while the admin password prompt is open. It goes on once the prompt is answered or cancelled.",
                kind: .hold)
        case nil:
            return lastError.map { ChargeControlNotice(text: $0, kind: .error) }
        }
    }
}

extension BatteryMonitor.ChargeControlNotice.Kind {
    /// Grey for a copy standing by, orange for a hold, red for an error.
    var color: Color {
        switch self {
        case .standby: return .secondary
        case .hold: return .orange
        case .error: return .red
        }
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

/// The About panel's "Checked at" text for the last health check: the time
/// with seconds, then the date, each the way macOS is set to show them (12
/// or 24 hour clock, the region's order of day and month, its calendar).
/// A fixed month/day/year pattern stood here before, which a day-first
/// region reads as another date (4 March as 3 April). On a Mac set to the
/// United States the text reads as that pattern's did, with the narrow
/// space macOS puts before AM and PM. Pure inputs, so the format is tested
/// without touching this Mac's settings.
func healthCheckTimeLabel(_ date: Date, locale: Locale = .autoupdatingCurrent,
                          timeZone: TimeZone = .autoupdatingCurrent) -> String {
    var calendar = locale.calendar
    calendar.timeZone = timeZone
    let time = Date.FormatStyle(date: .omitted, time: .standard, locale: locale,
                                calendar: calendar, timeZone: timeZone)
    let day = Date.FormatStyle(date: .numeric, time: .omitted, locale: locale,
                               calendar: calendar, timeZone: timeZone)
    return date.formatted(time) + " " + date.formatted(day)
}

/// The Temperature card's unit and text. The card has no unit of its own
/// to start in: until it is clicked it shows the unit macOS is set to
/// (System Settings > General > Language & Region > Temperature, or the
/// region's own unit where that was never changed). A click stores the unit
/// it switches to (`ui.useFahrenheit`), and from then on that choice is
/// shown whatever macOS says. Before this rule a new install showed
/// Fahrenheit on every Mac. Pure inputs, so the rule is tested without
/// touching this Mac's settings.
enum TemperatureDisplay {
    /// `stored` is the choice a click saved, nil while the card was never
    /// clicked. Anything macOS reports other than Fahrenheit reads as
    /// Celsius, the unit the sensor reports in.
    static func usesFahrenheit(stored: Bool?, locale: Locale = .autoupdatingCurrent) -> Bool {
        stored ?? (UnitTemperature(forLocale: locale) == .fahrenheit)
    }

    /// The card's text for a reading in degrees Celsius.
    static func label(celsius: Double, fahrenheit: Bool) -> String {
        fahrenheit
            ? String(format: "%.1f\u{00B0}F", celsius * 9.0 / 5.0 + 32.0)
            : String(format: "%.1f\u{00B0}C", celsius)
    }
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
        // nil adapterWatts is assumed to be a cable delivering an unknown but
        // non-zero amount: very old Macs without PowerTelemetryData, and a
        // snapshot whose input rail the SMC had not sampled yet (see
        // BatteryMonitor.adapterTelemetryUnmeasured). A measured exactly 0 W
        // with the cable plugged in is the "dead adapter" case (broken cable,
        // brick unplugged at the wall, etc.) only while the battery drains,
        // which is then the only place the Mac's power can come from; it
        // renders as pure on-battery so we don't draw an empty node. A 0 W
        // reading with the battery idle or charging cannot be true (an awake
        // Mac draws from one or the other), so the plug stays: routing it to
        // on-battery drew a Mac on AC as running on its battery for the
        // minute after a wake, until the registry entry was rewritten.
        if !adapterConnected { return .batteryOnly }
        let batteryDraining = (batteryWatts ?? 0) < 0
        if adapterWatts == 0 && batteryDraining { return .batteryOnly }
        // Base direction on batteryWatts' sign — the same raw measurement the
        // Battery Load card displays. Relying on IOKit's `isCharging` here
        // breaks consistency during state transitions (e.g. "Discharge to
        // Upper Bound" startup, where isCharging is already false but the
        // battery is still receiving current).
        if batteryDraining { return .acAndBattery }
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
                                    sourceIcon: "powerplug.fill", sourceMirrored: true,
                                    sourceLabel: adapterWatts,
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
        flowRibbon(battRibbon, color: acColor, endColor: chargeColor)
        node(icon: "powerplug.fill", watts: adapterWatts, tint: acColor,
             at: CGPoint(x: leftX, y: midY), mirrored: true)
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
        node(icon: "powerplug.fill", watts: adapterWatts, tint: acColor,
             at: CGPoint(x: leftX, y: acY), mirrored: true)
        batteryNode(watts: batteryWatts, tint: drainColor, at: CGPoint(x: leftX, y: battY))
        node(icon: "laptopcomputer", watts: electronicsWatts, tint: drainColor, at: CGPoint(x: rightX, y: midY))
    }

    @ViewBuilder
    private func singleBandBody(leftX: CGFloat, rightX: CGFloat,
                                 leftRX: CGFloat, rightRX: CGFloat, midY: CGFloat,
                                 sourceIcon: String, sourceMirrored: Bool = false,
                                 sourceLabel: Double?,
                                 sinkIcon: String, sinkLabel: Double?,
                                 color: Color) -> some View {
        let h2 = Self.maxRibbonH / 2
        let ribbon = RibbonShape(x1: leftRX, y1a: midY - h2, y1b: midY + h2,
                                 x2: rightRX, y2a: midY - h2, y2b: midY + h2)
        flowRibbon(ribbon, color: color)
        node(icon: sourceIcon, watts: sourceLabel, tint: color,
             at: CGPoint(x: leftX, y: midY), mirrored: sourceMirrored)
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
    /// approach the prior battery shimmer used. `endColor` blends the ribbon
    /// from the source node's color into the sink node's color (e.g. cyan AC
    /// power turning into green stored charge); omitted = solid `color`.
    private func flowRibbon(_ shape: RibbonShape, color: Color, endColor: Color? = nil) -> some View {
        let end = endColor ?? color
        return ZStack {
            shape.fill(LinearGradient(
                colors: [color.opacity(0.55), end.opacity(0.55)],
                startPoint: .leading, endPoint: .trailing))
            shape.stroke(LinearGradient(
                colors: [color.opacity(0.85), end.opacity(0.85)],
                startPoint: .leading, endPoint: .trailing), lineWidth: 0.6)
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
    /// `mirrored` flips the glyph horizontally — used for the plug, whose
    /// SF Symbol is drawn cord-left / prongs-right. Mirroring puts the
    /// prongs on the outer edge (the wall, off-diagram) and the cord end
    /// against the ribbon it feeds.
    private func node(icon: String, watts: Double?, tint: Color,
                      at p: CGPoint, mirrored: Bool = false) -> some View {
        VStack(spacing: Self.nodeVStackSpacing) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(tint)
                .scaleEffect(x: mirrored ? -1 : 1, y: 1)
                .frame(height: Self.glyphAreaH)
            Text(formatWatts(watts))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(.secondary)
                .lineLimit(1)
                // Negative and three-digit values ("-22.8 W" on battery,
                // "140.0 W" from a big adapter) are wider than the node
                // area; let the label overflow its 44 pt column rather
                // than truncate to "-22.8…".
                .fixedSize()
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
                // Negative and three-digit values ("-22.8 W" on battery,
                // "140.0 W" from a big adapter) are wider than the node
                // area; let the label overflow its 44 pt column rather
                // than truncate to "-22.8…".
                .fixedSize()
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
    /// True while "Charge to Full" temporarily overrides the ceiling to
    /// 100%: the upper dragger (thumb, label, marker, drag area) is hidden —
    /// it has no effect and dragging it mid-override would be misleading —
    /// and the target-range highlight extends to 100% to show the actual
    /// charge target. The stored bound is untouched throughout.
    var upperOverridden: Bool = false
    /// True while the bounds are pinned (a free license, see
    /// BatteryMonitor.chargeBoundsLocked): both draggers are drawn as usual,
    /// since the range they mark is in force, but ignore drags, keep the
    /// arrow cursor, and say why in their tooltips. The panel puts a
    /// ChargeBoundsLockRow with its Unlock… button beneath the slider.
    var locked: Bool = false

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

                // Target range highlight — extends to 100% while the upper
                // bound is overridden by Charge to Full.
                let rangeEndX = upperOverridden ? innerW : upperX
                let rangeW = max(0, rangeEndX - lowerX)
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
                    .help(locked
                        ? "Lower bound, locked at \(Int(lower))%: custom charge bounds need a paid license"
                        : "Lower bound: charging starts when battery drops below this level")
                    .onHover { hovering in
                        if hovering && !locked { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
                    }
                    .gesture(
                        DragGesture()
                            .onChanged { drag in
                                let raw = Double(drag.location.x - inset) / Double(innerW) * 100
                                lower = snap(max(0, min(raw, upper - minGap)))
                            },
                        including: locked ? .none : .all
                    )

                if !upperOverridden {
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
                        .help(locked
                            ? "Upper bound, locked at \(Int(upper))%: custom charge bounds need a paid license"
                            : "Upper bound: charging stops when battery reaches this level")
                        .onHover { hovering in
                            if hovering && !locked { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
                        }
                        .gesture(
                            DragGesture()
                                .onChanged { drag in
                                    let raw = Double(drag.location.x - inset) / Double(innerW) * 100
                                    upper = snap(min(100, max(raw, lower + minGap)))
                                },
                            including: locked ? .none : .all
                        )
                }
            }
        }
    }
}

// MARK: - Charge Bounds Lock Row

/// Shown beneath the range slider while the bounds are locked (a free
/// license; an unregistered copy has no slider, its charge control being on
/// hold): names the lock and ends in the Unlock… button (UnlockButton),
/// which opens the registration window, where the way to a paid license
/// is. Same layout as the toggle rows it sits among (icon in a 26pt
/// column, semibold label, trailing control), and as quiet: a grey lock
/// and a text button, since a free license is nothing to put right.
struct ChargeBoundsLockRow: View {
    let lower: Int
    let upper: Int

    var body: some View {
        HStack {
            Image(systemName: "lock.fill")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .frame(width: 26)
            Text("Charge Bounds")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            UnlockButton()
        }
        .help("Charge bounds are locked at the default \(lower) to \(upper)% on a free license; a paid license lets you set your own. Unlock… opens the registration window.")
    }
}

// MARK: - Unlock Button

/// The trailing control of a row whose feature a free license withholds
/// (ChargeBoundsLockRow, the Keep Awake row): "Unlock…", in the panel's
/// quiet text-button style (FooterButtonStyle, as the footer's links),
/// opening the registration window, where a paid license is explained and
/// bought. One word rather than a "Buy a license to…" line (the owner's
/// call, 2026-10-16): the lock in the row's icon column says what is
/// withheld, and the tooltips say why. Only a free license ever shows it;
/// an unregistered copy has no panel.
struct UnlockButton: View {
    var body: some View {
        Button("Unlock…") {
            NotificationCenter.default.post(name: .ampereShowRegistrationWindow, object: nil)
        }
        .buttonStyle(FooterButtonStyle())
        .help("Opens the registration window, where a paid license is explained and bought: it unlocks custom charge bounds and Keep Awake")
    }
}

// MARK: - Registration Window

extension Notification.Name {
    /// Posted by the settings window's License row and by the panel's
    /// Unlock… buttons; AppDelegate owns the window.
    static let ampereShowRegistrationWindow = Notification.Name("ampere.showRegistrationWindow")
    /// Posted by AppDelegate for About Ampere in the menu bar; the view of
    /// the panel's window opens its About sheet.
    static let ampereShowAbout = Notification.Name("ampere.showAbout")
}

/// Content of the standalone registration window. A fresh instance is
/// installed on every open, so state resets and `onAppear` prefills reliably.
/// Three faces: a paid registration (whose, how many Macs, Deregister This
/// Mac), a free one (whose, what a paid key adds, Buy a License…, Deregister
/// This Mac), and the form of an unregistered copy, which is also where a
/// free license is asked for (Get Free License, with the name and the email
/// address) and where the key that then comes by mail is entered and
/// registered, like a bought one.
struct RegistrationView: View {
    @ObservedObject var registration: RegistrationManager
    var close: () -> Void

    @State private var nameInput = ""
    @State private var emailInput = ""
    @State private var keyInput = ""
    /// True from Get Free License until the server answers, so the busy
    /// label lands on that button and not on Register.
    @State private var requestingFreeLicense = false
    private enum Field: Hashable { case name, email, key }
    @FocusState private var focus: Field?
    @State private var lastFocus: Field = .name

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if registration.isRegistered {
                registeredBody
            } else {
                unregisteredBody
            }
        }
        .textSelection(.enabled)
        .padding(20)
        // Wide enough for the unregistered face's four buttons (Get Free
        // License, Buy a License…, Quit Ampere, Register) at full length:
        // at 440 the first two truncated to "Get Free Lice…".
        .frame(width: 500)
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
            nameInput = registration.name
            emailInput = registration.email
            keyInput = registration.licenseKey
            registration.windowOpened()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if !registration.isRegistered { focus = firstEmptyField }
            }
        }
    }

    /// Where typing starts: the first field the copy could not fill in
    /// itself. A copy awaiting its free license key knows the name and the
    /// address, so the key's field is the one.
    private var firstEmptyField: Field {
        if nameInput.trimmingCharacters(in: .whitespaces).isEmpty { return .name }
        if emailInput.trimmingCharacters(in: .whitespaces).isEmpty { return .email }
        return .key
    }

    @ViewBuilder
    private var registeredBody: some View {
        let free = registration.isFree
        let holder = registration.name.isEmpty
            ? registration.email
            : "\(registration.name) (\(registration.email))"
        HStack(spacing: 6) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundColor(.green)
            Text(free ? "Free license, registered to \(holder)" : "Registered to \(holder)")
                .font(.system(size: 12, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
        // How many Macs the key is on, out of its room, as the server
        // said at the verify this window started when it opened (a free
        // license holds one Mac, so it has no line).
        if let usage = RegistrationManager.usage(macs: registration.deviceCount,
                                                 of: registration.maxDevices) {
            Text(usage)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        if let error = registration.lastError {
            Text(error)
                .font(.system(size: 12))
                .foregroundColor(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        Divider()
        // The key's own rules: what a free license gives and how to move to
        // a paid one, or by the Mac count the server gave a paid key (a
        // one-Mac key moves, a fuller one fills up and refuses).
        Text(free
            ? RegistrationManager.freeExplanation
            : RegistrationManager.explanation(macs: registration.maxDevices))
            .font(.system(size: 12))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        HStack {
            Button(registration.isBusy ? "Deregistering…" : "Deregister This Mac") {
                registration.deregister { _ in }
            }
            .disabled(registration.isBusy)
            if free {
                Button("Buy a License…") { NSWorkspace.shared.open(RegistrationManager.buyURL) }
                    .help("Opens the pricing page in your browser: a paid license adds custom charge bounds and Keep Awake")
            }
            Spacer()
            Button("Done") { close() }
                .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder
    private var unregisteredBody: some View {
        Text(RegistrationManager.unregisteredExplanation)
            .font(.system(size: 12))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        // The name is the free license's: a paid key registers by its
        // email and key alone.
        TextField("Name (for a free license)", text: $nameInput)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12))
            .focused($focus, equals: .name)
        TextField("Email", text: $emailInput)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12))
            .focused($focus, equals: .email)
        TextField("Registration Key", text: $keyInput)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced))
            .focused($focus, equals: .key)
        // What the last action has to say: why it was refused, in red; or,
        // for a copy that asked for a free license, where the key went,
        // or that this Mac is off its key.
        if let error = registration.lastError {
            Text(error)
                .font(.system(size: 12))
                .foregroundColor(.red)
                .fixedSize(horizontal: false, vertical: true)
        } else if let notice = freeLicenseNotice {
            Text(notice)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack {
            Button(requestingFreeLicense ? "Requesting…" : "Get Free License") {
                requestingFreeLicense = true
                registration.requestFreeLicense(name: nameInput, email: emailInput) { mailed in
                    requestingFreeLicense = false
                    // The key is in the mail, not in the answer: a key the
                    // form held makes way for it, and the address stays as
                    // the server took it.
                    if mailed {
                        keyInput = ""
                        emailInput = registration.email
                        focus = .key
                    }
                }
            }
            .disabled(registration.isBusy
                || nameInput.trimmingCharacters(in: .whitespaces).isEmpty
                || emailInput.trimmingCharacters(in: .whitespaces).isEmpty)
            .help("Emails a free license key to your name and email address. Enter the key under Registration Key and press Register to put this Mac on it: the default 40 to 60% charge range, for as long as you like.")
            Button("Buy a License…") { NSWorkspace.shared.open(RegistrationManager.buyURL) }
                .help("Opens the pricing page in your browser: a paid license adds custom charge bounds and Keep Awake")
            Spacer()
            // No license means no app: the other way out of this window is
            // quitting (the owner's call, 2026-10-16). The window has no
            // close button meanwhile (AppDelegate.licenseGated).
            Button("Quit Ampere") { NSApp.terminate(nil) }
                .keyboardShortcut(.cancelAction)
                .help("Quit Ampere without registering; the battery charges as macOS charges it")
            Button(registration.isBusy && !requestingFreeLicense ? "Registering…" : "Register") {
                registration.register(email: emailInput, key: keyInput) { _ in }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(registration.isBusy
                || emailInput.trimmingCharacters(in: .whitespaces).isEmpty
                || keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    /// What an unregistered copy that asked for a free license has to say
    /// for itself: the key is in the mail, or this Mac is off its key.
    private var freeLicenseNotice: String? {
        guard registration.isFree else { return nil }
        return registration.licenseKey.isEmpty
            ? RegistrationManager.pendingFreeKeyMessage(email: registration.email)
            : RegistrationManager.freeKeyHeldMessage
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

    /// Whether `window` takes the keyboard back when the app becomes
    /// active again, given the window AppKit has left it with (`key`). It
    /// does when no window has it, when it has it already (its field's
    /// focus still wants restoring), and when the window it is a sheet over
    /// has it, which is the case this exists for: AppKit hands the keyboard
    /// to the panel under a sheet. It does not when another window of the
    /// app has it. That window was clicked to bring the app back, or was
    /// the one in use before: with the panel kept open beside the
    /// registration window, the registration window took the keyboard from
    /// the panel 50 ms after every click that brought the app back, in the
    /// middle of a dragger's drag if that was the click.
    static func takesKeyboardBack(for window: NSWindow, from key: NSWindow?) -> Bool {
        key == nil || key === window || key === window.sheetParent
    }

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
                    guard let self, let window = self.window,
                          SheetKeyActivator.takesKeyboardBack(for: window, from: NSApp.keyWindow) else { return }
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

// MARK: - First Mouse Hosting View

/// The registration window's content view. SwiftUI's own hosting view
/// refuses the "first mouse", the click that makes a non-key window key,
/// so that click only keyed the window and the button under it never saw
/// it. In a menu bar app the window is non-key more often than not: the
/// popover's panel and other apps' windows take key status readily, and the
/// app itself is inactive whenever the user has been elsewhere. Every first
/// click on Register or Deregister was swallowed and the second one acted
/// (the owner, 2026-10-16). Accepting the first mouse delivers that click to
/// the control it landed on, as AppKit's own buttons and fields do.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Window Drag Blocker

/// Background that keeps a drag on the range slider from being taken for a
/// drag of the panel, on systems where the hosting view counts as window
/// background (through macOS 26). Written for the torn-off panel while
/// that was still the popover's own window, which AppKit moved by its
/// background: a dragger could not be dragged there. Torn off, the panel
/// is an ordinary window now, moved by its title bar alone, and on macOS
/// 27 the draggers keep their drags without this view, attached too
/// (measured with real drags, 2026-11-15). It stays for the attached panel
/// on the older systems, where nothing could be measured and a drag on
/// the panel's background is what tears it off.
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
        ChargeButtonBody(configuration: configuration, color: color)
    }

    // ButtonStyle itself can't hold @State (makeBody is re-invoked with a
    // fresh struct), so hover tracking lives in this nested view.
    private struct ChargeButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let color: Color
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .foregroundColor(.white)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(
                            colors: [color.opacity(0.95), color.opacity(0.8)],
                            startPoint: .top, endPoint: .bottom))
                        .brightness(isHovering && !configuration.isPressed ? 0.06 : 0)
                        .opacity(configuration.isPressed ? 0.85 : 1.0)
                )
                .scaleEffect(configuration.isPressed ? 0.985 : 1)
                .shadow(color: color.opacity(0.25), radius: isHovering ? 5 : 3, y: 1)
                .onHover { isHovering = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovering)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
        }
    }
}

// MARK: - Footer Button Style

/// Plain 12pt text button for the footer row: secondary at rest, brightens
/// to `hoverTint` on hover, dims while pressed, and shows the pointer
/// cursor. Pass a `tint` to keep a colored button (e.g. the orange update
/// action) colored in every state.
struct FooterButtonStyle: ButtonStyle {
    var tint: Color = .secondary
    var hoverTint: Color = .primary

    func makeBody(configuration: Configuration) -> some View {
        FooterButtonBody(configuration: configuration, tint: tint, hoverTint: hoverTint)
    }

    private struct FooterButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color
        let hoverTint: Color
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12))
                .foregroundColor(configuration.isPressed
                    ? hoverTint.opacity(0.7)
                    : (isHovering ? hoverTint : tint))
                .onHover { hovering in
                    isHovering = hovering
                    if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                }
                .animation(.easeOut(duration: 0.12), value: isHovering)
        }
    }
}

// MARK: - Stat Card

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    var iconColor: Color = .secondary
    var onTap: (() -> Void)? = nil
    /// Tooltip text; cards with an `onTap` should say what clicking switches to.
    var help: String = ""

    @State private var isHovering = false

    private var isInteractive: Bool { onTap != nil }

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(iconColor)
                .frame(height: 24)

            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
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
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(isInteractive && isHovering ? 0.09 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        // Clickable cards toggle their unit; surface that hidden affordance
        // with a swap glyph while hovered (plus the pointer cursor below).
        .overlay(alignment: .topTrailing) {
            if isInteractive && isHovering {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(6)
                    .transition(.opacity)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture {
            onTap?()
        }
        .onHover { hovering in
            guard isInteractive else { return }
            isHovering = hovering
            // .set() (not push/pop) so a missed exit event — e.g. the popover
            // closing under the cursor — can't leave an unbalanced stack.
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help(help)
    }
}
