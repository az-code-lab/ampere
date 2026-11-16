import XCTest
import AppKit
@testable import Ampere

/// Where the settings window opens. It comes back where it was last left,
/// by its top-left corner (its height follows its rows), in the same run and
/// after a relaunch; it is centered instead when it was never placed or when
/// no connected display shows enough of its title bar to move it by. The
/// panel's own window is placed by the same rules when a launch reopens it
/// (PanelWindowTests). Also the layer the settings and registration windows
/// are on, which follows the attached panel. Pure rules, so they are tested
/// without a window or a second display.
final class SettingsWindowPlacementTests: XCTestCase {
    /// A 1920 by 1080 display with a menu bar and a Dock, as its visible
    /// frame, and a second display above it.
    private let main = NSRect(x: 0, y: 90, width: 1920, height: 960)
    private let above = NSRect(x: -959, y: 1080, width: 3840, height: 2160)
    private let width: CGFloat = 480
    private let bar: CGFloat = 32

    private func screen(_ topLeft: NSPoint, _ screens: [NSRect]) -> NSRect? {
        AppDelegate.windowScreen(topLeft: topLeft, width: width, titleBarHeight: bar, screens: screens)
    }

    func testAWindowLeftOnAConnectedDisplayGoesBackToIt() {
        XCTAssertEqual(screen(NSPoint(x: 140, y: 820), [main]), main)
        XCTAssertEqual(screen(NSPoint(x: 140, y: 820), [main, above]), main)
        XCTAssertEqual(screen(NSPoint(x: 700, y: 2800), [main, above]), above)
    }

    func testAWindowLeftOnADisplayThatIsGoneIsCentered() {
        // Left on the display above, which is no longer connected.
        XCTAssertNil(screen(NSPoint(x: 700, y: 2800), [main]))
        // Garbage in the preferences reads as the origin: under the Dock here.
        XCTAssertNil(screen(.zero, [main]))
        XCTAssertNil(screen(NSPoint(x: 140, y: 820), []), "No display at all")
    }

    func testEnoughOfTheTitleBarHasToShowToMoveTheWindowBy() {
        let grab = AppDelegate.windowGrabWidth
        // Dragged off the right edge: what is left of the bar decides.
        XCTAssertEqual(screen(NSPoint(x: main.maxX - grab, y: 820), [main]), main)
        XCTAssertNil(screen(NSPoint(x: main.maxX - grab + 1, y: 820), [main]))
        // Off the left edge, the same.
        XCTAssertEqual(screen(NSPoint(x: main.minX - width + grab, y: 820), [main]), main)
        XCTAssertNil(screen(NSPoint(x: main.minX - width + grab - 1, y: 820), [main]))
        // A bar that sits above the visible frame (a menu bar grew, or the
        // displays were rearranged) shows too little of its height.
        XCTAssertEqual(screen(NSPoint(x: 140, y: main.maxY + bar / 2), [main]), main)
        XCTAssertNil(screen(NSPoint(x: 140, y: main.maxY + bar / 2 + 1), [main]))
    }

    func testTheDisplayThatShowsMoreOfTheBarIsTheOneItIsOn() {
        let left = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let right = NSRect(x: 1000, y: 0, width: 1000, height: 800)
        // 180 points of the bar on the left display, 300 on the right.
        XCTAssertEqual(screen(NSPoint(x: 820, y: 600), [left, right]), right)
        XCTAssertEqual(screen(NSPoint(x: 820, y: 600), [right, left]), right)
        // 300 on the left, 180 on the right.
        XCTAssertEqual(screen(NSPoint(x: 700, y: 600), [left, right]), left)
    }

    func testTheTopLeftCornerIsKeptWhateverTheHeight() {
        let topLeft = NSPoint(x: 140, y: 820)
        XCTAssertEqual(AppDelegate.windowOrigin(topLeft: topLeft, size: NSSize(width: 480, height: 629), on: main),
                       NSPoint(x: 140, y: 191))
        // Fewer rows than when it was left: the same corner.
        XCTAssertEqual(AppDelegate.windowOrigin(topLeft: topLeft, size: NSSize(width: 480, height: 522), on: main),
                       NSPoint(x: 140, y: 298))
    }

    func testAWindowThatWouldRunOffTheBottomIsMovedUpToShowWhole() {
        // Left low with few rows; with more rows its bottom would be under the Dock.
        let origin = AppDelegate.windowOrigin(topLeft: NSPoint(x: 140, y: 600),
                                                      size: NSSize(width: 480, height: 629), on: main)
        XCTAssertEqual(origin, NSPoint(x: 140, y: main.minY))
    }

    func testAWindowWhoseTopIsAboveTheVisibleFrameIsMovedDownUnderIt() {
        let origin = AppDelegate.windowOrigin(topLeft: NSPoint(x: 140, y: main.maxY + 10),
                                                      size: NSSize(width: 480, height: 629), on: main)
        XCTAssertEqual(origin, NSPoint(x: 140, y: main.maxY - 629))
        // Taller than the display has room for (it should not be: the form
        // scrolls first): the top is what stays in reach.
        let tall = AppDelegate.windowOrigin(topLeft: NSPoint(x: 140, y: 820),
                                                    size: NSSize(width: 480, height: 1200), on: main)
        XCTAssertEqual(tall, NSPoint(x: 140, y: main.maxY - 1200))
    }

    func testThePlaceIsReadBackFromThePreferences() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ampere-settings-place-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: folder.appendingPathComponent("place").path))
        let key = AppDelegate.settingsWindowTopLeftKey
        XCTAssertNil(AppDelegate.savedWindowTopLeft(key, in: defaults), "Never placed: centered")
        defaults.set(NSStringFromPoint(NSPoint(x: 140, y: 820)), forKey: key)
        XCTAssertEqual(AppDelegate.savedWindowTopLeft(key, in: defaults), NSPoint(x: 140, y: 820))
        // A negative corner (a display to the left of or below the main one) survives the round trip.
        defaults.set(NSStringFromPoint(NSPoint(x: -700.5, y: -120)), forKey: key)
        XCTAssertEqual(AppDelegate.savedWindowTopLeft(key, in: defaults), NSPoint(x: -700.5, y: -120))
    }

    // MARK: - The layer the settings and registration windows are on

    /// macOS draws the attached panel on the menu bar's layer, above ordinary
    /// windows, so an ordinary settings window opened behind a pinned panel
    /// and could not be clicked in front of it (2026-11-15). While that panel
    /// stays on screen the app's own windows take its layer. (Torn off, the
    /// panel is an ordinary window and none of this applies.)
    private let panelLayer = NSWindow.Level(rawValue: 25)

    func testOwnWindowsTakeThePanelsLayerWhileThePanelStays() {
        // Pinned, or held open by a sheet: both set this behavior.
        XCTAssertEqual(AppDelegate.ownWindowLevel(panelShown: true, panelBehavior: .applicationDefined,
                                                  panelLevel: panelLayer), panelLayer)
    }

    func testOwnWindowsAreOrdinaryWithoutAPanelThatStays() {
        // A panel that the next click elsewhere closes.
        XCTAssertEqual(AppDelegate.ownWindowLevel(panelShown: true, panelBehavior: .transient,
                                                  panelLevel: panelLayer), .normal)
        // No panel on screen, whatever its behavior was left at.
        XCTAssertEqual(AppDelegate.ownWindowLevel(panelShown: false, panelBehavior: .applicationDefined,
                                                  panelLevel: panelLayer), .normal)
        // A panel with no window to read the layer from.
        XCTAssertEqual(AppDelegate.ownWindowLevel(panelShown: true, panelBehavior: .applicationDefined,
                                                  panelLevel: nil), .normal)
    }
}
