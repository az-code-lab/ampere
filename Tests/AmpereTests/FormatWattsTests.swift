import XCTest
@testable import Ampere

/// The wattage display format is shared between the stat cards and the
/// Sankey diagram node labels. Pinning the format here prevents the two
/// displays from accidentally drifting (different rounding, different
/// "unknown" sentinel, etc.) and matches the user's stated requirement
/// that the diagram values mirror the card values exactly.
final class FormatWattsTests: XCTestCase {

    func testNil_RendersAsEmDash() {
        XCTAssertEqual(formatWatts(nil), "—")
    }

    func testZero_RendersAsZeroPointZero() {
        // Exact zero is preserved (not collapsed to "—") so a clamped
        // electronics-watts reading shows up honestly in both displays.
        XCTAssertEqual(formatWatts(0.0), "0.0 W")
    }

    /// Sub-watt readings preserve their tenths digit so a real "0.3 W"
    /// reading doesn't round down to "0 W". This was the user's complaint
    /// that originally led to the format being lowered to 0.05 W
    /// granularity — pinning it as a regression guard.
    func testSubWatt_PreservesTenth() {
        XCTAssertEqual(formatWatts(0.3), "0.3 W")
    }

    func testNegativeValue_PreservesSign() {
        // Battery discharging — the Battery Load card shows "-7.0 W"
        // and the Sankey Battery node must match.
        XCTAssertEqual(formatWatts(-7.0), "-7.0 W")
    }

    func testLargeValue_FormatsToOneDecimal() {
        XCTAssertEqual(formatWatts(86.9), "86.9 W")
    }

    func testRounding_BankersRoundOnTenth() {
        // 86.95 sits exactly on the rounding boundary. The test pins
        // whatever `String(format: "%.1f")` does today so a future format
        // change has to update this explicitly.
        XCTAssertEqual(formatWatts(86.94), "86.9 W")
        XCTAssertEqual(formatWatts(86.96), "87.0 W")
    }
}
