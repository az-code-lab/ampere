import XCTest
@testable import Ampere

/// The About panel's "Checked at" text follows the Mac's own date and time
/// settings. The locales stand in for those settings, which a test must not
/// change, and the time zone is fixed so the clock time is the same on any
/// Mac that runs this.
final class HealthCheckTimeLabelTests: XCTestCase {
    private let gmt = TimeZone(identifier: "GMT")!

    /// 4 March 2026, 15:05:07 GMT: a day and a month that read as another
    /// date when swapped, at an hour that tells the two clocks apart.
    private var afternoon: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = gmt
        return calendar.date(from: DateComponents(year: 2026, month: 3, day: 4, hour: 15, minute: 5, second: 7))!
    }

    /// macOS puts a narrow no-break space before AM and PM; the tests
    /// compare with a plain one.
    private func label(_ identifier: String) -> String {
        healthCheckTimeLabel(afternoon, locale: Locale(identifier: identifier), timeZone: gmt)
            .replacingOccurrences(of: "\u{202F}", with: " ")
    }

    /// What the fixed pattern "h:mm:ss a M/d/yyyy" gave, so a Mac set to
    /// the United States shows what it always did.
    func testUnitedStates_TimeThenMonthDayYear() {
        XCTAssertEqual(label("en_US"), "3:05:07 PM 3/4/2026")
    }

    /// The defect: these regions got the month first too, and read 4 March
    /// as 3 April.
    func testDayFirstRegions_GetTheirOwnDateOrderAndClock() {
        XCTAssertEqual(label("en_GB"), "15:05:07 04/03/2026")
        XCTAssertEqual(label("de_DE"), "15:05:07 4.3.2026")
    }

    func testYearFirstRegion() {
        XCTAssertEqual(label("ja_JP"), "15:05:07 2026/3/4")
    }

    /// The clock setting is separate from the region: the `hours` keyword
    /// is how a locale identifier spells a 24 hour clock on a 12 hour
    /// region, and a 12 hour clock on a 24 hour one.
    func testTheClockSettingWinsOverTheRegion() {
        XCTAssertEqual(label("en_US@hours=h23"), "15:05:07 3/4/2026")
        XCTAssertEqual(label("de_DE@hours=h12"), "3:05:07 PM 4.3.2026")
    }
}
