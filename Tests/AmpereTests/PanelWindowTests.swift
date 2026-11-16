import XCTest
import AppKit
@testable import Ampere

/// The panel as a window of its own, which is what tearing it off the menu
/// bar item makes of it (AppDelegate.panelWindow): whether a launch opens
/// it again, where it is kept, when it counts as in view, and whose menu
/// bar is showing. The rules, tested without a window on screen; where the
/// window goes back to is the settings window's rule, in
/// SettingsWindowPlacementTests.
final class PanelWindowTests: XCTestCase {
    private func scratchDefaults() throws -> (UserDefaults, URL) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ampere-panel-window-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (try XCTUnwrap(UserDefaults(suiteName: folder.appendingPathComponent("window").path)), folder)
    }

    /// A window that was open when the last run ended is open again after
    /// a quit, an update's relaunch or a crash (CLAUDE.md requirement 3). A
    /// copy with no license has no panel to show in it.
    func testALaunchReopensTheWindowThatWasOpenForACopyWithALicense() {
        XCTAssertTrue(AppDelegate.reopensPanelWindow(wasOpen: true, tier: .paid))
        XCTAssertTrue(AppDelegate.reopensPanelWindow(wasOpen: true, tier: .free))
        XCTAssertFalse(AppDelegate.reopensPanelWindow(wasOpen: true, tier: .unlicensed))
        for tier in [LicenseTier.paid, .free, .unlicensed] {
            XCTAssertFalse(AppDelegate.reopensPanelWindow(wasOpen: false, tier: tier))
        }
    }

    /// Fast polling follows this. The attached panel is in view whenever
    /// it is shown; the window only while macOS says some of it shows, so
    /// one that is minimized, covered or on another Space costs nothing.
    func testThePanelIsInViewAttachedOrAsAWindowWithSomeOfItShowing() {
        XCTAssertTrue(AppDelegate.panelIsOnScreen(popoverShown: true, windowOpen: false, windowSeen: false))
        XCTAssertTrue(AppDelegate.panelIsOnScreen(popoverShown: false, windowOpen: true, windowSeen: true))
        XCTAssertFalse(AppDelegate.panelIsOnScreen(popoverShown: false, windowOpen: true, windowSeen: false),
                       "Minimized, covered, hidden with the app, or on another Space")
        XCTAssertFalse(AppDelegate.panelIsOnScreen(popoverShown: false, windowOpen: false, windowSeen: false))
        // A window that is not the panel (made ready for a tear-off, or
        // closed) does not count, whatever macOS says of it.
        XCTAssertFalse(AppDelegate.panelIsOnScreen(popoverShown: false, windowOpen: false, windowSeen: true))
    }

    /// The window's place is its top-left corner, since its height follows
    /// the panel's rows, kept under a key of its own.
    func testTheWindowsPlaceIsItsTopLeftCornerUnderItsOwnKey() throws {
        let (defaults, folder) = try scratchDefaults()
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = AppDelegate.panelWindowTopLeftKey
        XCTAssertNotEqual(key, AppDelegate.settingsWindowTopLeftKey)
        XCTAssertNil(AppDelegate.savedWindowTopLeft(key, in: defaults), "Never torn off")

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 842),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: 728, y: 90))
        AppDelegate.saveWindowTopLeft(of: window, as: key, in: defaults)
        XCTAssertEqual(AppDelegate.savedWindowTopLeft(key, in: defaults),
                       NSPoint(x: 728, y: 90 + window.frame.height))
        XCTAssertNil(AppDelegate.savedWindowTopLeft(AppDelegate.settingsWindowTopLeftKey, in: defaults))

        // Fewer rows: the corner is what stays, so the window goes back
        // under it at its new height.
        let visible = NSRect(x: 0, y: 90, width: 1920, height: 960)
        let topLeft = try XCTUnwrap(AppDelegate.savedWindowTopLeft(key, in: defaults))
        let shorter = NSSize(width: 580, height: window.frame.height - 94)
        XCTAssertEqual(AppDelegate.windowOrigin(topLeft: topLeft, size: shorter, on: visible),
                       NSPoint(x: 728, y: 90 + 94))
    }

    /// The menu bar is the app's once macOS names this process as its
    /// owner; anything else, the app has still to take it (takeMenuBar).
    func testTheMenuBarIsTheAppsWhenThisProcessOwnsIt() {
        XCTAssertTrue(AppDelegate.ownsMenuBar(.current))
        XCTAssertFalse(AppDelegate.ownsMenuBar(nil))
        let other = NSWorkspace.shared.runningApplications.first {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        if let other { XCTAssertFalse(AppDelegate.ownsMenuBar(other)) }
    }
    // MARK: - Clicks outside the app

    /// The attached panel closes at a click outside the app, which a
    /// monitor for clicks in other apps reports. macOS reports the app's
    /// own clicks there too once the app has had the Dock put in front (the
    /// way the menu bar is taken when the panel becomes a window), and the
    /// monitor then closed the panel at every click inside it (2026-11-15).
    /// So where the click landed is asked of the window server: on a window
    /// of this app, or not.
    func testAClickOnOneOfTheAppsOwnWindowsIsNotAClickOutsideTheApp() throws {
        _ = NSApplication.shared
        // Nowhere near a screen there is no window to land on, this app's
        // or anyone's: a click outside the app. (Not asked of a spot on
        // screen: whatever shows there is the Mac's, not the test's.)
        XCTAssertFalse(AppDelegate.clickLandsOnOwnWindow(at: NSPoint(x: -100_000, y: -100_000)))

        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            throw XCTSkip("No display to put a window on")
        }
        // A small opaque window in front of everything, for a moment.
        let frame = NSRect(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.minY + 40, width: 8, height: 8)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = .popUpMenu
        window.backgroundColor = .black
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        // Drawn and known to the window server before it is asked: a
        // window that has not shown anything yet takes no mouse-down. Asked
        // again for up to two seconds, since nothing says when that is.
        window.display()
        let point = NSPoint(x: frame.midX, y: frame.midY)
        let deadline = Date(timeIntervalSinceNow: 2)
        var landed = false
        while !landed, Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            landed = AppDelegate.clickLandsOnOwnWindow(at: point)
        }
        XCTAssertTrue(landed)
    }

    // MARK: - A window no taller than its screen

    /// With every row showing, the panel and its title bar are taller than
    /// a 13 inch MacBook's screen has between its menu bar and its Dock, and
    /// an ordinary window is not drawn over the Dock as the attached panel
    /// is: the last row ended up under it. The window's view is told how
    /// much room the screen has, and scrolls past that.
    func testThePanelsViewGetsWhatTheTitleBarLeavesOfTheScreen() {
        XCTAssertEqual(AppDelegate.panelWindowRoom(visibleHeight: 960, titleBarHeight: 32), 928)
        // A 13 inch MacBook Air with a Dock: about 849 points to show in.
        XCTAssertEqual(AppDelegate.panelWindowRoom(visibleHeight: 849, titleBarHeight: 32), 817)
        // A sliver of a screen still leaves something to scroll in.
        XCTAssertEqual(AppDelegate.panelWindowRoom(visibleHeight: 180, titleBarHeight: 32),
                       AppDelegate.panelWindowLeastRoom)
        XCTAssertEqual(AppDelegate.panelWindowRoom(visibleHeight: 0, titleBarHeight: 32),
                       AppDelegate.panelWindowLeastRoom)
    }

    // MARK: - Whether the window was in the Dock

    func testWhetherTheWindowWasMinimizedHasAKeyOfItsOwn() {
        let keys = [AppDelegate.panelWindowOpenKey, AppDelegate.panelWindowTopLeftKey,
                    AppDelegate.panelWindowMinimizedKey, AppDelegate.settingsWindowTopLeftKey]
        XCTAssertEqual(Set(keys).count, keys.count)
    }

    // MARK: - Who has the keyboard when the app comes back

    /// The registration window, and a sheet over the panel, take the
    /// keyboard back when the app becomes active again, which an accessory
    /// app's windows do not always get by themselves. Not from another
    /// window of the app, though: with the panel kept open beside the
    /// registration window (Manage… no longer closes it), a click on the
    /// panel that brought the app back lost the keyboard 50 ms later.
    func testAWindowTakesTheKeyboardBackOnlyWhenNoOtherWindowOfTheAppHasIt() {
        func window() -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled],
                                  backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            return window
        }
        let registration = window(), panel = window()
        XCTAssertTrue(SheetKeyActivator.takesKeyboardBack(for: registration, from: nil), "Nobody has it")
        XCTAssertTrue(SheetKeyActivator.takesKeyboardBack(for: registration, from: registration), "It has it already")
        XCTAssertFalse(SheetKeyActivator.takesKeyboardBack(for: registration, from: panel),
                       "The panel was clicked to bring the app back")
    }

    /// The monitor's events have no window and carry the place on screen;
    /// an event in a window carries a place in that window.
    func testWhereAMouseEventHappenedOnScreen() throws {
        _ = NSApplication.shared
        func mouseDown(at location: NSPoint, in window: NSWindow?) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [],
                                             timestamp: 0, windowNumber: window?.windowNumber ?? 0, context: nil,
                                             eventNumber: 0, clickCount: 1, pressure: 1))
        }
        XCTAssertEqual(AppDelegate.screenLocation(of: try mouseDown(at: NSPoint(x: 300, y: 400), in: nil)),
                       NSPoint(x: 300, y: 400))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 200, width: 50, height: 50), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        XCTAssertEqual(AppDelegate.screenLocation(of: try mouseDown(at: NSPoint(x: 10, y: 20), in: window)),
                       NSPoint(x: 110, y: 220))
    }
}
