import XCTest
import SwiftUI
import AppKit
@testable import Ampere

/// Renders the real panel in the states the product video shows
/// (Video/make-video.sh). Nothing here touches hardware: the monitor is
/// built with a fake IO and never started, and every state is set
/// directly. Skipped unless AMPERE_VIDEO_DIR names the output directory,
/// so a normal `swift test` run is unaffected.
///
/// The panel goes through a real NSHostingView in a window rather than
/// ImageRenderer: the switch toggles and the range slider are AppKit-backed
/// on macOS, and ImageRenderer draws those as placeholders. The window sits
/// below the desktop picture, so nothing appears on screen.
@MainActor
final class VideoSnapshotTests: XCTestCase {
    private struct ExportError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private final class CapturePanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private static let registrationKeys = [
        "registration.active", "registration.email", "registration.name",
        "registration.licenseKey", "registration.serverURL",
    ]

    func testExportPanels() throws {
        guard let dir = ProcessInfo.processInfo.environment["AMPERE_VIDEO_DIR"] else {
            throw XCTSkip("AMPERE_VIDEO_DIR not set; only Video/make-video.sh runs this exporter")
        }
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try Self.stampReleaseVersion()

        // RegistrationManager reads UserDefaults.standard, which in a test
        // process is the xctest tool's domain: seed it for the registered
        // renders and clean up afterwards. The server override guarantees
        // the manager's deferred verify (15 s after init) can never reach
        // the real license server with the placeholder registration, even
        // if the process outlives that timer.
        let defaults = UserDefaults.standard
        defer { for key in Self.registrationKeys { defaults.removeObject(forKey: key) } }
        for key in Self.registrationKeys { defaults.removeObject(forKey: key) }
        defaults.set("http://127.0.0.1:9", forKey: "registration.serverURL")
        let unregistered = RegistrationManager()
        defaults.set(true, forKey: "registration.active")
        defaults.set("alex@example.com", forKey: "registration.email")
        defaults.set("Alex Appleseed", forKey: "registration.name")
        let registered = RegistrationManager()
        XCTAssertFalse(unregistered.isRegistered)
        XCTAssertTrue(registered.isRegistered)

        let charging = Self.battery(percentage: 47, amperage: 3390, adapterWatts: 65.1, electronicsWatts: 23.3)
        let holding = Self.battery(percentage: 60, amperage: 0, adapterWatts: 23.1, electronicsWatts: 23.1)
        let draining = Self.battery(percentage: 74, amperage: -1850, adapterWatts: 0, electronicsWatts: 22.6)
        let toFull = Self.battery(percentage: 81, amperage: 2140, adapterWatts: 52.4, electronicsWatts: 26.1)

        var panels: [(String, BatteryMonitor, RegistrationManager)] = []

        let chargingMonitor = Self.monitor()
        chargingMonitor.state = charging
        chargingMonitor.chargeToUpperBound = true
        panels.append(("charging", chargingMonitor, registered))

        let holdingMonitor = Self.monitor()
        holdingMonitor.state = holding
        holdingMonitor.chargingPaused = true
        panels.append(("holding", holdingMonitor, registered))

        let dischargeMonitor = Self.monitor(prefs: ["autoDischargeEnabled": true])
        dischargeMonitor.state = draining
        dischargeMonitor.chargingPaused = true
        dischargeMonitor.activeDischarging = true
        panels.append(("discharge", dischargeMonitor, registered))

        let fullMonitor = Self.monitor(prefs: ["chargeToFull": true])
        fullMonitor.state = toFull
        panels.append(("full", fullMonitor, registered))

        // A mid-afternoon deadline reads naturally in the "until 3:45 PM"
        // label whatever the clock says at export time.
        var deadline = Calendar.current.date(bySettingHour: 15, minute: 45, second: 0, of: Date())!
        if deadline <= Date() { deadline = deadline.addingTimeInterval(24 * 3600) }
        let awakeMonitor = Self.monitor(prefs: [
            "keepAwakeEnabled": true,
            "keepAwakeMinutes": 120,
            "keepAwakeDeadline": deadline.timeIntervalSince1970,
        ])
        awakeMonitor.state = holding
        awakeMonitor.chargingPaused = true
        panels.append(("keepawake", awakeMonitor, registered))

        let settingsMonitor = Self.monitor()
        settingsMonitor.state = holding
        settingsMonitor.chargingPaused = true
        settingsMonitor.settingsExpanded = true
        panels.append(("settings", settingsMonitor, registered))

        let manualMonitor = Self.monitor(prefs: ["autoManageEnabled": false])
        manualMonitor.state = charging
        panels.append(("manual", manualMonitor, registered))

        let lockedMonitor = Self.monitor(locked: true)
        lockedMonitor.state = holding
        lockedMonitor.chargingPaused = true
        panels.append(("unregistered", lockedMonitor, unregistered))

        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        for (name, monitor, registration) in panels {
            try Self.render(monitor: monitor, registration: registration,
                            to: out.appendingPathComponent("\(name).png"))
        }
    }

    // MARK: - Fixtures

    /// The panel header shows AppVersion.current, which a dev build takes
    /// from `git describe` ("v0.0.65-1-g2198675"); a release build reads
    /// the bare tag from its bundle. The video should show what users
    /// install, so this points git (through GIT_DIR, for the one describe
    /// call the lazily computed version makes) at a throwaway repository
    /// whose only tag is the latest release tag of this checkout.
    private static func stampReleaseVersion() throws {
        let latest = try git(["describe", "--tags", "--abbrev=0"], in: FileManager.default.currentDirectoryPath)
        let version = latest.hasPrefix("v") ? String(latest.dropFirst()) : latest
        let stamp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ampere-video-version-\(getpid())", isDirectory: true)
        try FileManager.default.createDirectory(at: stamp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stamp) }
        let identity = ["-c", "user.name=Ampere", "-c", "user.email=video@ampere.invalid",
                        "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false"]
        _ = try git(["init", "-q"], in: stamp.path)
        _ = try git(identity + ["commit", "-q", "--allow-empty", "-m", version], in: stamp.path)
        _ = try git(identity + ["tag", version], in: stamp.path)
        setenv("GIT_DIR", stamp.appendingPathComponent(".git").path, 1)
        defer { unsetenv("GIT_DIR") }
        XCTAssertEqual(AppVersion.current, version)
    }

    private static func git(_ arguments: [String], in directory: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ExportError("git \(arguments.joined(separator: " ")) failed in \(directory)")
        }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func battery(percentage: Int, amperage: Double, adapterWatts: Double,
                                electronicsWatts: Double) -> BatteryState {
        let voltage = 12.33
        let maxCapacity = 5874
        let adapterVoltage = 20.02
        return BatteryState(
            percentage: percentage, cycleCount: 112, isCharging: amperage > 0,
            adapterConnected: true, health: "94%", temperature: 30.4, timeRemaining: "",
            designCapacity: 6249, maxCapacity: maxCapacity,
            currentCapacity: percentage * maxCapacity / 100,
            amperage: amperage, voltage: voltage, adapterWatts: adapterWatts,
            adapterAmperage: adapterWatts / adapterVoltage * 1000, adapterVoltage: adapterVoltage,
            electronicsWatts: electronicsWatts, batteryWatts: voltage * amperage / 1000,
            batteryAgeYears: "1y 8m", batteryAgeDays: "608d", fullyCharged: false)
    }

    /// A monitor that is never started: no helper install, no SMC read or
    /// write, no cleanup-job registration. Any privileged call fails the
    /// test instead of touching the system.
    private static func monitor(prefs: [String: Any] = [:], locked: Bool = false) -> BatteryMonitor {
        let preferences = MemoryBatteryPreferences()
        preferences.values["chargeLowerBound"] = 40
        preferences.values["chargeUpperBound"] = 60
        for (key, value) in prefs { preferences.values[key] = value }
        var io = BatteryMonitor.IO()
        io.battery = { XCTFail("battery read during snapshot"); return nil }
        io.lidClosed = { false }
        io.sleepDisabled = { false }
        io.readKey = { _ in nil }
        io.chargeTerminateKey = { .present }
        io.registeredNativeLimits = { [] }
        io.writeHelper = { _ in XCTFail("helper write during snapshot"); return false }
        io.helperInstalled = { true }
        io.helperAuthorized = { true }
        io.helperStale = { false }
        io.installHelper = { XCTFail("helper install during snapshot"); return false }
        io.setupRefusal = { nil }
        io.competingInstance = { nil }
        io.runAsAdmin = { _ in XCTFail("administrator command during snapshot"); return false }
        io.cleanupDaemonBundlePath = { nil }
        io.cleanupDaemonRegistered = { _ in true }
        return BatteryMonitor(chargeBoundsLocked: locked, defaults: preferences,
                              io: io, startMonitoring: false)
    }

    private static func render(monitor: BatteryMonitor, registration: RegistrationManager,
                               to url: URL) throws {
        let scale: CGFloat = 3
        let light = NSAppearance(named: .aqua)
        let host = NSHostingView(rootView: ContentView(monitor: monitor, registration: registration))
        host.appearance = light
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        // A key window, or the switches draw in the gray inactive style;
        // a non-activating panel takes key status without activating this
        // process, so the user's frontmost app stays where it is.
        let window = CapturePanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = light
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        // On screen as far as AppKit is concerned (so layout and display
        // run), yet under the desktop picture so nobody sees it.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.setFrameOrigin(.zero)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        guard size.width > 0, size.height > 0 else { throw ExportError("empty layout for \(url.lastPathComponent)") }
        window.setContentSize(size)
        host.frame = NSRect(origin: .zero, size: size)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { throw ExportError("bitmap allocation failed for \(url.lastPathComponent)") }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw ExportError("PNG encoding failed for \(url.lastPathComponent)")
        }
        try png.write(to: url)
    }
}
