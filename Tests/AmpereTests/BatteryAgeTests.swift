import XCTest
@testable import Ampere

/// The Battery Served card is fed by the gauge's operating-hours counter
/// (`TotalOperatingTime`), which the registry stamps with the time it was
/// sampled. These pin the label format and the age arithmetic; where the
/// counter lives in the registry differs by macOS version and is covered by
/// `BatteryMonitor.readBattery` itself.
final class BatteryAgeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_789_617_411)

    /// The counter read from a 2021 MacBook Pro in September 2026.
    func testFreshSample_YearsAndDays() {
        let age = BatteryAge.labels(operatingHours: 44_063, sampledAt: now, now: now)
        XCTAssertEqual(age.years, "5y 0m")
        XCTAssertEqual(age.days, "1835d")
    }

    /// The registry's copy is as old as its last update: time since the
    /// sample counts toward the age.
    func testStaleSample_AddsTimeSinceTheSample() {
        let sampledAt = now.addingTimeInterval(-2 * 86400)
        let age = BatteryAge.labels(operatingHours: 24 * 100, sampledAt: sampledAt, now: now)
        XCTAssertEqual(age.days, "102d")
        XCTAssertEqual(age.years, "3m")
    }

    func testUnderAMonth() {
        let age = BatteryAge.labels(operatingHours: 24 * 29, sampledAt: now, now: now)
        XCTAssertEqual(age.years, "< 1m")
        XCTAssertEqual(age.days, "29d")
    }

    /// 365-day years leave up to 364 days of remainder, which 30-day
    /// months would otherwise render as a twelfth month.
    func testMonthsNeverReachTwelve() {
        XCTAssertEqual(BatteryAge.labels(operatingHours: 24 * 364, sampledAt: now, now: now).years, "11m")
        XCTAssertEqual(BatteryAge.labels(operatingHours: 24 * (365 * 4 + 364), sampledAt: now, now: now).years, "4y 11m")
    }

    /// A sample stamped ahead of the clock (the clock was set back since)
    /// must not produce a negative age.
    func testSampleFromTheFuture_ClampsAtZero() {
        let age = BatteryAge.labels(operatingHours: 1, sampledAt: now.addingTimeInterval(7 * 86400), now: now)
        XCTAssertEqual(age.days, "0d")
        XCTAssertEqual(age.years, "< 1m")
    }
}
