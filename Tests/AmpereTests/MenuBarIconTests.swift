import XCTest
import AppKit
@testable import Ampere

/// The menu bar icon while a Keep Awake session runs: the session's group
/// (its symbol, and its remaining time when it has one to show) goes to the
/// left of the battery, the battery itself is untouched, and only the
/// display badge brings color into an otherwise template icon. Also the
/// two rules that keep the attached panel still while the icon changes
/// under it: the icon never narrows (`minWidth`), and the panel hangs from
/// the right-hand part of the button (`panelAnchorRect`).
final class MenuBarIconTests: XCTestCase {
    private typealias Indicator = BatteryMonitor.KeepAwakeIndicator

    private let battery = AppDelegate.menuBarBatteryWidth
    private let cup = Indicator(display: false, time: "1h 45m")
    private let display = Indicator(display: true, time: "1h 45m")
    /// A color no part of the icon uses otherwise.
    private let accent = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)

    /// The icon drawn at one pixel per point, the size rounded up to whole
    /// pixels (the battery is 27.8 points wide).
    private func pixels(_ keepAwake: Indicator? = nil, warning: Bool = false, update: Bool = false,
                        dark: Bool = false, minWidth: CGFloat = 0) -> NSBitmapImageRep {
        let size = AppDelegate.menuBarIconSize(keepAwake: keepAwake, minWidth: minWidth)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width.rounded(.up)),
                                   pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        AppDelegate.drawMenuBarIcon(size: size, percentage: 85, hasWarning: warning, hasUpdate: update,
                                    darkMenuBar: dark, keepAwake: keepAwake, accent: accent)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private func rgba(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> [Int] {
        guard let c = rep.colorAt(x: x, y: y) else { return [] }
        return [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent].map { Int(($0 * 255).rounded()) }
    }

    /// How many pixels in the columns `xs` pass `test` (red, green, blue, alpha in 0...255).
    private func count(_ rep: NSBitmapImageRep, _ xs: Range<Int>, where test: ([Int]) -> Bool) -> Int {
        var n = 0
        for x in xs {
            for y in 0..<rep.pixelsHigh where test(rgba(rep, x, y)) { n += 1 }
        }
        return n
    }

    private let isInk: ([Int]) -> Bool = { $0[3] > 128 }
    private let isAccent: ([Int]) -> Bool = { $0[3] > 128 && $0[0] > 200 && $0[1] < 60 && $0[2] > 200 }
    private let isOrange: ([Int]) -> Bool = { $0[3] > 128 && $0[0] > 200 && $0[1] > 90 && $0[1] < 200 && $0[2] < 90 }
    private let isBlack: ([Int]) -> Bool = { $0[3] > 128 && $0[0] < 40 && $0[1] < 40 && $0[2] < 40 }
    private let isWhite: ([Int]) -> Bool = { $0[3] > 128 && $0[0] > 215 && $0[1] > 215 && $0[2] > 215 }
    private let isPureWhite: ([Int]) -> Bool = { $0.allSatisfy { $0 >= 250 } }
    /// The columns a session's symbol takes, at the left of its group: the
    /// display badge fills them, the cup sits against their right.
    private let slot = 0..<Int(AppDelegate.keepAwakeSymbolSlot)

    /// The battery's columns of `rep`, pixel by pixel.
    private func batteryColumns(_ rep: NSBitmapImageRep) -> [[Int]] {
        let width = Int(battery.rounded(.up))
        var out: [[Int]] = []
        for x in (rep.pixelsWide - width)..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh { out.append(rgba(rep, x, y)) }
        }
        return out
    }

    // MARK: - Size

    func testWithoutASession_TheIconIsTheBatteryAlone() {
        let image = AppDelegate.renderMenuBarIcon(percentage: 85, hasWarning: false, hasUpdate: false, darkMenuBar: false)
        XCTAssertEqual(image.size.width, battery)
        XCTAssertEqual(image.size.height, AppDelegate.menuBarIconHeight)
        XCTAssertTrue(image.isTemplate)
    }

    /// The group adds a whole number of points, so the battery keeps its
    /// place on the pixel grid.
    func testASessionWidensTheIconByItsGroup() {
        for indicator in [cup, display, Indicator(display: false, time: nil), Indicator(display: false, time: "9m")] {
            let group = AppDelegate.keepAwakeGroupWidth(indicator)
            XCTAssertEqual(group, group.rounded(), "\(indicator)")
            XCTAssertEqual(AppDelegate.menuBarIconSize(keepAwake: indicator).width, group + battery, "\(indicator)")
        }
        XCTAssertGreaterThan(AppDelegate.keepAwakeGroupWidth(cup),
                             AppDelegate.keepAwakeGroupWidth(Indicator(display: false, time: nil)),
                             "The time takes room the symbol alone does not")
    }

    /// Both symbols take the same room (the badge fills it, the cup sits
    /// against its right), so switching the display option on or off
    /// changes the symbol and nothing else: the item must not resize
    /// under the panel, or under the sheet that confirms the option.
    func testBothSymbolsTakeTheSameWidth() {
        XCTAssertEqual(AppDelegate.keepAwakeGroupWidth(cup), AppDelegate.keepAwakeGroupWidth(display))
        XCTAssertEqual(AppDelegate.keepAwakeGroupWidth(Indicator(display: false, time: nil)),
                       AppDelegate.keepAwakeGroupWidth(Indicator(display: true, time: nil)))
        XCTAssertEqual(AppDelegate.keepAwakeBadgeSize.width, AppDelegate.keepAwakeSymbolSlot)
        XCTAssertEqual(AppDelegate.keepAwakeBadgeSize.width, 24, "The battery's own width")
    }


    /// Past the hour the countdown holds its width from minute to minute.
    func testCountdownsOfOneShapeTakeTheSameWidth() {
        let widths = ["1h 45m", "1h 09m", "1h 00m", "7h 59m"].map {
            AppDelegate.keepAwakeGroupWidth(Indicator(display: false, time: $0))
        }
        XCTAssertEqual(Set(widths).count, 1)
    }

    // MARK: - Drawing

    /// The battery is drawn exactly as without a session, against the
    /// right edge: the group goes to its left and moves nothing.
    func testTheGroupLeavesTheBatteryUntouched() {
        let plain = batteryColumns(pixels())
        XCTAssertEqual(batteryColumns(pixels(cup)), plain)
        XCTAssertEqual(batteryColumns(pixels(Indicator(display: false, time: nil))), plain)
        XCTAssertEqual(batteryColumns(pixels(Indicator(display: false, time: "9m"))), plain)
    }

    func testTheGroupIsDrawnToTheLeftOfTheBattery() {
        let rep = pixels(cup)
        let group = Int(AppDelegate.keepAwakeGroupWidth(cup))
        XCTAssertGreaterThan(count(rep, slot, where: isInk), 40, "The symbol, in its slot")
        XCTAssertEqual(count(rep, 0..<(slot.upperBound - 18), where: isInk), 0, "The cup sits against the right of the slot")
        XCTAssertGreaterThan(count(rep, (slot.upperBound + 3)..<(group - 7), where: isInk), 60, "The time, after the symbol")
        XCTAssertEqual(count(rep, (group - 7)..<group, where: isInk), 0, "The gap before the battery stays clear")
    }

    /// A template icon is recolored by the system from its alpha alone, so
    /// every pixel of the cup variant is plain black.
    func testTheCupVariantStaysATemplate() {
        XCTAssertTrue(AppDelegate.renderMenuBarIcon(percentage: 85, hasWarning: false, hasUpdate: false,
                                                    darkMenuBar: false, keepAwake: cup).isTemplate)
        for dark in [false, true] {
            let rep = pixels(cup, dark: dark)
            XCTAssertEqual(count(rep, 0..<rep.pixelsWide, where: isInk),
                           count(rep, 0..<rep.pixelsWide, where: isBlack), "dark: \(dark)")
        }
    }

    /// While the display is kept on the symbol is a badge: a white display
    /// on a rounded rectangle in the accent color, the look of the panel's
    /// Keep Display On button when it is on. It is the one colored part,
    /// and what takes the icon off template rendering.
    func testTheDisplayBadgeIsAccentWithAWhiteDisplay() {
        XCTAssertFalse(AppDelegate.renderMenuBarIcon(percentage: 85, hasWarning: false, hasUpdate: false,
                                                     darkMenuBar: false, keepAwake: display).isTemplate)
        for dark in [false, true] {
            let rep = pixels(display, dark: dark)
            XCTAssertGreaterThan(count(rep, slot, where: isAccent), 220, "The badge is filled, dark: \(dark)")
            XCTAssertGreaterThan(count(rep, slot, where: isWhite), 30, "With a display in white on it, dark: \(dark)")
            XCTAssertEqual(count(rep, slot, where: isBlack), 0, "dark: \(dark)")
            XCTAssertEqual(count(rep, slot.upperBound..<rep.pixelsWide, where: isAccent), 0,
                           "The time and the battery stay neutral, dark: \(dark)")
        }
        XCTAssertEqual(count(pixels(cup), slot, where: isAccent), 0, "The cup takes no color")
    }

    /// The badge sits on the battery's center line: two clear rows above
    /// and below it in the 18-point icon.
    func testTheDisplayBadgeIsCenteredOnTheBattery() {
        let rep = pixels(display)
        let height = Int(AppDelegate.keepAwakeBadgeSize.height)
        let margin = (rep.pixelsHigh - height) / 2
        XCTAssertEqual(margin * 2 + height, rep.pixelsHigh, "An even height, so the margins are whole points")
        for x in slot {
            for y in Array(0..<margin) + Array((rep.pixelsHigh - margin)..<rep.pixelsHigh) {
                XCTAssertEqual(rgba(rep, x, y)[3], 0, "(\(x), \(y)) is outside the badge")
            }
        }
        let middle = slot.lowerBound + slot.count / 2
        XCTAssertTrue(isAccent(rgba(rep, middle, margin)), "The badge's top row")
        XCTAssertTrue(isAccent(rgba(rep, middle, rep.pixelsHigh - margin - 1)), "And its bottom row")
    }

    /// The display in the badge is drawn on the pixel grid: at one pixel
    /// per point its outline is a clean white line, not a pale smear of
    /// white into the accent color.
    func testTheBadgesDisplayIsDrawnOnThePixelGrid() {
        XCTAssertGreaterThanOrEqual(count(pixels(display), slot, where: isPureWhite), 30)
    }

    /// Off template rendering the neutral parts are colored by hand, to
    /// match the menu bar: black on a light one, white on a dark one.
    func testWithTheDisplayBadgeTheRestFollowsTheMenuBar() {
        let light = pixels(display), dark = pixels(display, dark: true)
        let rest = slot.upperBound..<light.pixelsWide
        XCTAssertGreaterThan(count(light, rest, where: isBlack), 100)
        XCTAssertEqual(count(light, rest, where: isWhite), 0)
        XCTAssertGreaterThan(count(dark, rest, where: isWhite), 100)
        XCTAssertEqual(count(dark, rest, where: isBlack), 0)
        XCTAssertGreaterThan(count(dark, slot, where: isAccent), 220)
    }

    /// Off template rendering the neutral parts take the strength the
    /// system gives the title beside them (90% white on a dark menu bar,
    /// 85% black on a light one), not full strength: the time must not
    /// come out brighter than the percent, nor the battery brighter than
    /// it is without the display badge. The badge itself is at full
    /// strength; it is there to be noticed.
    func testOffTemplateTheNeutralPartsTakeTheSystemsTint() {
        func strongestAlpha(_ rep: NSBitmapImageRep, _ xs: Range<Int>) -> Int {
            var best = 0
            for x in xs {
                for y in 0..<rep.pixelsHigh { best = max(best, rgba(rep, x, y)[3]) }
            }
            return best
        }
        let group = Int(AppDelegate.keepAwakeGroupWidth(display))
        for (dark, expected) in [(false, 217), (true, 230)] {
            let rep = pixels(display, dark: dark)
            XCTAssertEqual(strongestAlpha(rep, (slot.upperBound + 3)..<(group - 7)), expected, accuracy: 2,
                           "The time, dark: \(dark)")
            XCTAssertEqual(strongestAlpha(rep, group..<rep.pixelsWide), expected, accuracy: 2, "The battery, dark: \(dark)")
            XCTAssertEqual(strongestAlpha(rep, slot), 255, "The display badge, dark: \(dark)")
        }
        XCTAssertEqual(strongestAlpha(pixels(cup), 0..<pixels(cup).pixelsWide), 255,
                       "A template is drawn at full strength; the system applies the tint")
        // A warning's orange is as strong as the orange title beside it.
        let warned = pixels(cup, warning: true)
        XCTAssertEqual(strongestAlpha(warned, group..<warned.pixelsWide), 255)
    }

    /// A health warning is about charge control: it tints the battery, not
    /// the Keep Awake group beside it.
    func testAWarningTintsTheBatteryNotTheGroup() {
        let rep = pixels(cup, warning: true)
        let group = Int(AppDelegate.keepAwakeGroupWidth(cup))
        XCTAssertEqual(count(rep, 0..<group, where: isOrange), 0)
        XCTAssertGreaterThan(count(rep, 0..<group, where: isBlack), 100)
        XCTAssertGreaterThan(count(rep, group..<rep.pixelsWide, where: isOrange), 40)
        XCTAssertEqual(count(rep, group..<rep.pixelsWide, where: isBlack), 0)
    }

    // MARK: - Never narrower while the panel is attached

    /// With a session's width reserved, an icon without one keeps that
    /// width: the battery stays against the right edge and the room the
    /// group had is clear.
    func testMinWidthKeepsTheIconWideAndTheBatteryInPlace() {
        let wide = AppDelegate.menuBarIconSize(keepAwake: cup).width
        XCTAssertEqual(AppDelegate.menuBarIconSize(minWidth: wide).width, wide)
        let rep = pixels(minWidth: wide)
        XCTAssertEqual(batteryColumns(rep), batteryColumns(pixels()))
        XCTAssertEqual(count(rep, 0..<Int(AppDelegate.keepAwakeGroupWidth(cup)), where: { $0[3] > 0 }), 0)
    }

    /// A narrower group is drawn against the battery, not where the wider
    /// one started.
    func testMinWidthRightAlignsANarrowerGroup() {
        let wide = AppDelegate.menuBarIconSize(keepAwake: cup).width
        let short = Indicator(display: false, time: "9m")
        let rep = pixels(short, minWidth: wide)
        let spare = Int(AppDelegate.keepAwakeGroupWidth(cup) - AppDelegate.keepAwakeGroupWidth(short))
        XCTAssertGreaterThan(spare, 0)
        XCTAssertEqual(count(rep, 0..<spare, where: { $0[3] > 0 }), 0)
        XCTAssertGreaterThan(count(rep, spare..<(spare + slot.count), where: isInk), 40)
        XCTAssertEqual(batteryColumns(rep), batteryColumns(pixels()))
    }

    /// The reserved width is a previous icon's width, and comes back out
    /// as exactly that: no drift from the battery's 27.8 points.
    func testMinWidthRoundTripsThroughEveryGroupWidth() {
        for group in stride(from: CGFloat(0), through: 120, by: 1) {
            let width = group + battery
            XCTAssertEqual(AppDelegate.menuBarIconSize(minWidth: width).width, width, "group \(group)")
        }
    }

    func testANarrowerMinWidthChangesNothing() {
        let natural = AppDelegate.menuBarIconSize(keepAwake: cup)
        XCTAssertEqual(AppDelegate.menuBarIconSize(keepAwake: cup, minWidth: battery), natural)
        XCTAssertEqual(AppDelegate.menuBarIconSize(keepAwake: cup, minWidth: 0), natural)
    }

    // MARK: - The time's baseline

    /// Measured on macOS 27 (22-point button, one pixel per point): the
    /// title's line starts 3 points down, the image 2 points down.
    func testTimeY_FromTheMeasuredLayout() {
        XCTAssertEqual(AppDelegate.menuBarTimeY(titleTop: 3, imageTop: 2), 2)
        XCTAssertEqual(AppDelegate.menuBarTimeDefaultY, 2)
    }

    func testTimeY_FollowsATitleAlignedToHalfPoints() {
        XCTAssertEqual(AppDelegate.menuBarTimeY(titleTop: 3.5, imageTop: 2), 1.5)
    }

    /// A layout the code does not know (a cell that reports no usable
    /// rects) falls back to the measured position.
    func testTimeY_ImplausibleLayoutFallsBack() {
        XCTAssertEqual(AppDelegate.menuBarTimeY(titleTop: 0, imageTop: 2), AppDelegate.menuBarTimeDefaultY)
        XCTAssertEqual(AppDelegate.menuBarTimeY(titleTop: 11, imageTop: 0), AppDelegate.menuBarTimeDefaultY)
    }

    // MARK: - The accent color

    /// A fixed color, not a dynamic one: the icon is drawn into an image.
    func testAccent_IsAFixedColorForEitherMenuBar() {
        for dark in [false, true] {
            XCTAssertEqual(AppDelegate.menuBarAccent(dark: dark).colorSpace, .sRGB, "dark: \(dark)")
        }
    }

    // MARK: - Where the panel hangs

    /// The panel hangs from the right-hand part of the button, the edge a
    /// menu bar item keeps when it widens.
    func testPanelAnchor_IsTheRightHandPartOfTheButton() {
        let wide = NSRect(x: 0, y: 0, width: 152, height: 22)
        XCTAssertEqual(AppDelegate.panelAnchorRect(buttonBounds: wide, anchorWidth: 80),
                       NSRect(x: 72, y: 0, width: 80, height: 22))
        XCTAssertEqual(AppDelegate.panelAnchorRect(buttonBounds: NSRect(x: 0, y: 0, width: 80, height: 22), anchorWidth: 80),
                       NSRect(x: 0, y: 0, width: 80, height: 22), "No group: the whole button, as before")
    }

    /// The same screen spot before and after the button widens to the left.
    func testPanelAnchor_HoldsItsDistanceFromTheRightEdge() {
        for width in [CGFloat(80), 105, 152, 170] {
            let rect = AppDelegate.panelAnchorRect(buttonBounds: NSRect(x: 0, y: 0, width: width, height: 22), anchorWidth: 80)
            XCTAssertEqual(rect.maxX, width)
            XCTAssertEqual(rect.width, 80)
        }
    }

    func testPanelAnchor_NeverLeavesTheButton() {
        let narrow = NSRect(x: 0, y: 0, width: 44, height: 22)
        XCTAssertEqual(AppDelegate.panelAnchorRect(buttonBounds: narrow, anchorWidth: 80), narrow)
        XCTAssertEqual(AppDelegate.panelAnchorRect(buttonBounds: narrow, anchorWidth: -5).width, 0)
    }
}
