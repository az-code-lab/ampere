import SwiftUI
import AppKit
import Shared
import ServiceManagement

// MARK: - Settings Window

extension Notification.Name {
    /// Posted by the panel's Settings… link; AppDelegate owns the window
    /// (showSettingsWindow), and the Settings… menu command (Cmd+,) calls
    /// it directly.
    static let ampereShowSettingsWindow = Notification.Name("ampere.showSettingsWindow")
}

/// The login item behind Launch at Login. The app's own is macOS's to keep
/// (SMAppService); a test hands the settings view a fake, so a click there
/// registers nothing for the test runner.
struct LoginItem {
    var isEnabled: () -> Bool
    var setEnabled: (Bool) throws -> Void

    static let mainApp = LoginItem(
        isEnabled: { SMAppService.mainApp.status == .enabled },
        setEnabled: { enabled in
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        })
}

/// Content of the standalone settings window. The settings used to be rows
/// that unfolded under the panel's footer; the list outgrew the panel, and
/// every new row made the panel taller. Here they are a grouped form, one
/// section per subject: a new setting is one more row in its section (a
/// Toggle or a LabeledContent with a SettingsLabel), a new subject one more
/// Section, and the window sizes itself to whatever the form holds, up to
/// the height its screen has room for (scrollHeight).
///
/// A fresh instance is installed on every open and dropped when the window
/// closes (AppDelegate.showSettingsWindow), so the login item is read anew
/// each time and nothing here runs while the window is closed.
struct SettingsView: View {
    @ObservedObject var monitor: BatteryMonitor
    @ObservedObject var registration: RegistrationManager
    private let loginItem: LoginItem
    /// What macOS says the login item is. macOS keeps it, and it can change
    /// behind the app's back (System Settings > General > Login Items &
    /// Extensions): read when the window opens, again whenever the app
    /// becomes active, and after every change made here.
    @State private var launchAtLogin: Bool
    /// Why the last change to the login item did not take, shown in the
    /// row in place of its description; nil once a change has.
    @State private var launchAtLoginFailure: String?

    /// Nil: the form is as tall as its rows, and the window with it. A
    /// height: the form keeps that height and scrolls, for a screen with
    /// no room for all the rows (AppDelegate.showSettingsWindow decides).
    private let scrollHeight: CGFloat?

    static let width: CGFloat = 480

    init(monitor: BatteryMonitor, registration: RegistrationManager, loginItem: LoginItem = .mainApp,
         scrollHeight: CGFloat? = nil) {
        self.monitor = monitor
        self.registration = registration
        self.loginItem = loginItem
        self.scrollHeight = scrollHeight
        _launchAtLogin = State(initialValue: loginItem.isEnabled())
    }

    var body: some View {
        Form {
            // The panel's status line says why charge control is on hold
            // and what last went wrong; this window has no status line and
            // the panel is usually closed while it is open, so the same
            // notice leads the form (BatteryMonitor.chargeControlNotice).
            if let notice = monitor.chargeControlNotice {
                Section {
                    noticeRow(notice)
                }
            }
            Section("Charging") {
                autoChargeRow
            }
            Section("General") {
                launchAtLoginRow
            }
            Section("Menu Bar") {
                menuBarPercentRow
                // A setting of Keep Awake's, so offered with it: a copy
                // without the paid license has no session to show.
                if !monitor.keepAwakeLocked {
                    menuBarKeepAwakeTimeRow
                }
            }
            Section("License") {
                licenseRow
            }
            // Only while this account holds passwordless access and this
            // instance manages charge control: another account's rule is
            // not ours to revoke, and neither is its running session.
            // Revoking publishes state changes when it completes, so the
            // section goes on success and stays if the prompt is cancelled.
            if monitor.accountAuthorized && !monitor.standingBy && monitor.isSudoRuleInstalled {
                Section("Advanced") {
                    adminAccessRow
                }
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .frame(width: Self.width)
        .modifier(SettingsFormHeight(scrollHeight: scrollHeight))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin = loginItem.isEnabled()
        }
    }

    // MARK: Rows

    private func noticeRow(_ notice: BatteryMonitor.ChargeControlNotice) -> some View {
        Label {
            Text(notice.text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } icon: {
            Image(systemName: notice.kind == .standby ? "info.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(notice.kind.color)
        }
    }

    private var autoChargeRow: some View {
        Toggle(isOn: Binding(
            get: { monitor.autoManageEnabled },
            set: { monitor.setAutoManage($0) }
        )) {
            SettingsLabel(title: "Auto Charge",
                          caption: "Keeps the battery between the charge bounds on the panel.",
                          icon: "arrow.up.arrow.down.circle.fill",
                          active: monitor.autoManageEnabled)
        }
        // Nothing to switch while nothing this instance could write would
        // apply, and no intent changes behind a password prompt of
        // Ampere's own (BatteryMonitor.adminPromptUp); the notice above
        // says which.
        .disabled(monitor.controlsUnavailable || monitor.adminPromptUp)
        // State-dependent like the other switches: each side says what is
        // active now and what flipping the switch changes.
        .help(monitor.autoManageEnabled
            ? (monitor.nativeLimitMode
                ? "On: Ampere keeps the battery between the bounds through the macOS charge limit; charging starts below the lower bound and stops at the upper bound, awake or asleep. Turn off for standard macOS charging with manual Pause/Resume."
                : "On: Ampere keeps the battery between the bounds; charging starts below the lower bound and stops at the upper bound. A below-lower charge keeps the Mac awake until it finishes; other charges pause during sleep and resume on wake. Turn off for standard macOS charging with manual Pause/Resume.")
            : "Off: standard macOS charging to full, with manual Pause/Resume while on AC. Turn on to keep the battery between the lower and upper bounds automatically. Requires admin access.")
    }

    private var launchAtLoginRow: some View {
        Toggle(isOn: Binding(
            get: { launchAtLogin },
            set: { setLaunchAtLogin($0) }
        )) {
            SettingsLabel(title: "Launch at Login",
                          caption: launchAtLoginFailure ?? "Starts Ampere when you log in to this Mac.",
                          captionColor: launchAtLoginFailure == nil ? .secondary : .red,
                          icon: "arrow.right.circle.fill",
                          active: launchAtLogin)
        }
        .help(launchAtLogin
            ? "On: Ampere starts by itself when you log in. Turn off to start it yourself."
            : "Off: Ampere runs only when you open it. Turn on to start it automatically when you log in.")
    }

    private var menuBarPercentRow: some View {
        Toggle(isOn: Binding(
            get: { monitor.showMenuBarPercent },
            set: { monitor.showMenuBarPercent = $0 }
        )) {
            // number.circle.fill, not `percent`: SF Symbols has no filled-
            // circle percent glyph, and the settings rows keep to one
            // *.circle.fill family so the icons match in size and weight
            // (bare glyphs read smaller at the same point size).
            SettingsLabel(title: "Percent in Menu Bar",
                          caption: "Shows the charge percentage beside the battery icon.",
                          icon: "number.circle.fill",
                          active: monitor.showMenuBarPercent)
        }
        .help(monitor.showMenuBarPercent
            ? "On: the charge percentage shows beside the battery icon in the menu bar. Turn off to show the icon alone and keep the menu bar item narrow (while the panel hangs from the item, the freed space is reclaimed when the panel closes)."
            : "Off: the menu bar shows the battery icon alone. Turn on to show the charge percentage beside it.")
    }

    private var menuBarKeepAwakeTimeRow: some View {
        Toggle(isOn: Binding(
            get: { monitor.showMenuBarKeepAwakeTime },
            set: { monitor.showMenuBarKeepAwakeTime = $0 }
        )) {
            SettingsLabel(title: "Keep Awake Time in Menu Bar",
                          caption: "Shows the time a Keep Awake session has left beside its symbol.",
                          icon: "timer.circle.fill",
                          active: monitor.showMenuBarKeepAwakeTime)
        }
        .help(monitor.showMenuBarKeepAwakeTime
            ? "On: a timed Keep Awake session shows its remaining time beside its symbol in the menu bar. Turn off to show the symbol alone and keep the menu bar item narrow (while the panel hangs from the item, the freed space is reclaimed when the panel closes)."
            : "Off: a Keep Awake session shows only its symbol in the menu bar, a cup, or a display on the accent color while the display is kept on. Turn on to show a timed session's remaining time beside it.")
    }

    /// Whose license this copy runs on, and the way into the registration
    /// window, which is where a license is managed, moved or replaced. A
    /// copy with no license never shows this window (it is held at the
    /// registration window); the row is worded for it all the same.
    private var licenseRow: some View {
        let tier = registration.tier
        let holder = registration.name.isEmpty ? registration.email : registration.name
        return LabeledContent {
            Button(tier == .unlicensed ? "Register…" : "Manage…") {
                NotificationCenter.default.post(name: .ampereShowRegistrationWindow, object: nil)
            }
        } label: {
            switch tier {
            case .paid:
                // The email under the name; alone it is the title already.
                SettingsLabel(title: "Registered to \(holder)",
                              caption: registration.name.isEmpty ? nil : registration.email,
                              icon: "checkmark.circle.fill")
            case .free:
                SettingsLabel(title: "Free license",
                              caption: "Registered to \(holder)",
                              icon: "checkmark.circle.fill")
            case .unlicensed:
                SettingsLabel(title: "Registration",
                              caption: "Unregistered",
                              captionColor: .orange,
                              icon: "xmark.circle.fill",
                              tint: .orange)
            }
        }
        .help(tier == .paid
            ? "Registered to \(registration.email). Manage… opens the registration window, where this Mac can be deregistered."
            : tier == .free
            ? "Free license, registered to \(registration.email). Manage… opens the registration window, where you can move to a paid license for custom charge bounds and Keep Awake."
            : "Unregistered. Register… opens the registration window, where you can get a free license or enter the key from your purchase email.")
    }

    private var adminAccessRow: some View {
        LabeledContent {
            Button("Revoke") {
                monitor.removeSudoRule()
            }
            // One password prompt at a time (BatteryMonitor.adminPromptUp).
            .disabled(monitor.adminPromptUp)
        } label: {
            SettingsLabel(title: "Admin Access",
                          caption: "Ampere has passwordless admin access for charge control.",
                          icon: "lock.circle.fill")
        }
        .help("Revoke removes this account's passwordless sudo rule, and the helper binary once no other account uses it (prompts for your admin password). Charge control stops working until access is granted again.")
    }

    // MARK: Launch at Login

    /// Ask macOS for the change, then show what it now says, whichever way
    /// the call went: a refused change puts the switch back, with the
    /// reason in the row.
    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try loginItem.setEnabled(enabled)
            launchAtLoginFailure = nil
        } catch {
            AmpereLog.app("Ampere: Failed to \(enabled ? "enable" : "disable") launch at login: %@", error.localizedDescription)
            launchAtLoginFailure = "Could not turn Launch at Login \(enabled ? "on" : "off"): \(error.localizedDescription)"
        }
        launchAtLogin = loginItem.isEnabled()
        // The call went through and macOS still says otherwise: the login
        // item is waiting for the user under Login Items & Extensions.
        if launchAtLoginFailure == nil, launchAtLogin != enabled {
            launchAtLoginFailure = "macOS did not turn Launch at Login \(enabled ? "on" : "off"). Check System Settings > General > Login Items & Extensions."
        }
    }
}

// MARK: - Settings Form Height

/// The settings form's height. By default its own, not a scrolling one:
/// the hosting view sizes the window to it, so the window grows and shrinks
/// with the rows. Given a height (a screen with no room for all the rows),
/// the form keeps it and scrolls.
private struct SettingsFormHeight: ViewModifier {
    let scrollHeight: CGFloat?

    func body(content: Content) -> some View {
        if let scrollHeight {
            content.frame(height: scrollHeight)
        } else {
            content.fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Settings Label

/// The left side of a settings row: its symbol, in the accent color while
/// what it stands for is on and grey while it is off, its title, and under
/// the title a line on what the setting does (or, for the License row, whose
/// it is). The symbols are one *.circle.fill family, so they match in size
/// and weight from row to row.
struct SettingsLabel: View {
    let title: String
    var caption: String? = nil
    var captionColor: Color = .secondary
    let icon: String
    var active = true
    var tint: Color = .accentColor

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(captionColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(active ? tint : .secondary)
        }
    }
}
