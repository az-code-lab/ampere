import XCTest
@testable import Ampere

/// `BatteryMonitor.keepAwakeAssertionDesired` is the pure gate behind the
/// Keep Mac Awake toggle's powerd assertion: refresh() reconciles the held
/// assertion against this function every tick. These tests pin the AC-only
/// rule (never hold on battery) and the deadline semantics (a session ends
/// at its wall-clock deadline, inclusive).
final class KeepAwakeTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testDisabled_NeverDesired() {
        XCTAssertFalse(BatteryMonitor.keepAwakeAssertionDesired(
            enabled: false, adapterConnected: true, deadline: nil, now: now))
        XCTAssertFalse(BatteryMonitor.keepAwakeAssertionDesired(
            enabled: false, adapterConnected: true,
            deadline: now.addingTimeInterval(3600), now: now))
    }

    func testEnabledOnBattery_NotDesired() {
        XCTAssertFalse(BatteryMonitor.keepAwakeAssertionDesired(
            enabled: true, adapterConnected: false, deadline: nil, now: now))
    }

    func testEnabledOnAC_NoDeadline_Desired() {
        XCTAssertTrue(BatteryMonitor.keepAwakeAssertionDesired(
            enabled: true, adapterConnected: true, deadline: nil, now: now))
    }

    func testEnabledOnAC_FutureDeadline_Desired() {
        XCTAssertTrue(BatteryMonitor.keepAwakeAssertionDesired(
            enabled: true, adapterConnected: true,
            deadline: now.addingTimeInterval(1), now: now))
    }

    func testEnabledOnAC_PastDeadline_NotDesired() {
        XCTAssertFalse(BatteryMonitor.keepAwakeAssertionDesired(
            enabled: true, adapterConnected: true,
            deadline: now.addingTimeInterval(-1), now: now))
    }

    /// Deadline is exclusive of the instant itself: `deadline <= now` ends
    /// the session, so the expiry timer firing exactly on time releases.
    func testEnabledOnAC_DeadlineExactlyNow_NotDesired() {
        XCTAssertFalse(BatteryMonitor.keepAwakeAssertionDesired(
            enabled: true, adapterConnected: true, deadline: now, now: now))
    }

    func testDeadlineHelper_ZeroMinutes_MeansForever() {
        XCTAssertNil(BatteryMonitor.keepAwakeDeadline(minutes: 0, from: now))
    }

    func testDeadlineHelper_PositiveMinutes() {
        XCTAssertEqual(BatteryMonitor.keepAwakeDeadline(minutes: 90, from: now),
                       now.addingTimeInterval(90 * 60))
    }

    /// Every preset must produce a distinct, non-empty label — the picker
    /// derives its items from this pair, so a collision or blank would be
    /// a UI bug.
    func testDurationLabels_DistinctAndNonEmpty() {
        let labels = BatteryMonitor.keepAwakeDurations.map(BatteryMonitor.keepAwakeDurationLabel)
        XCTAssertEqual(Set(labels).count, labels.count)
        XCTAssertFalse(labels.contains(""))
    }

    func testDurationLabels_Spelling() {
        XCTAssertEqual(BatteryMonitor.keepAwakeDurationLabel(0), "Forever")
        XCTAssertEqual(BatteryMonitor.keepAwakeDurationLabel(15), "15 min")
        XCTAssertEqual(BatteryMonitor.keepAwakeDurationLabel(60), "1 hour")
        XCTAssertEqual(BatteryMonitor.keepAwakeDurationLabel(480), "8 hours")
    }
}
