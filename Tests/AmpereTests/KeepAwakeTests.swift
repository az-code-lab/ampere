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

    // MARK: - When a session ends on its own

    private func end(enabled: Bool = true, ac: Bool? = true, deadline: Date? = nil,
                     locked: Bool = false) -> BatteryMonitor.KeepAwakeSessionEnd? {
        BatteryMonitor.keepAwakeSessionEnd(enabled: enabled, adapterConnected: ac, deadline: deadline, now: now,
                                           locked: locked)
    }

    func testSessionEnd_RunningSessionOnACKeepsRunning() {
        XCTAssertNil(end())
        XCTAssertNil(end(deadline: now.addingTimeInterval(1)))
    }

    func testSessionEnd_NoSessionNeverEnds() {
        XCTAssertNil(end(enabled: false, ac: false))
        XCTAssertNil(end(enabled: false, deadline: now))
    }

    func testSessionEnd_DeadlineExpires() {
        XCTAssertEqual(end(deadline: now), .expired)
        XCTAssertEqual(end(ac: false, deadline: now), .expired, "Expiry is reported ahead of the adapter")
    }

    func testSessionEnd_UnpluggingEnds() {
        XCTAssertEqual(end(ac: false), .unplugged)
        XCTAssertEqual(end(ac: false, deadline: now.addingTimeInterval(1)), .unplugged)
    }

    /// A failed battery read is unknown, not unplugged: the assertion is
    /// released (keepAwakeAssertionDesired on false) but the session
    /// survives the tick.
    func testSessionEnd_UnknownAdapterKeepsTheSession() {
        XCTAssertNil(end(ac: nil))
        XCTAssertNil(end(ac: nil, deadline: now.addingTimeInterval(1)))
        XCTAssertEqual(end(ac: nil, deadline: now), .expired)
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

    // MARK: - Which assertion (the display option)

    private func assertion(enabled: Bool = true, display: Bool, ac: Bool = true,
                           deadline: Date? = nil, locked: Bool = false) -> BatteryMonitor.KeepAwakeAssertion? {
        BatteryMonitor.keepAwakeAssertion(enabled: enabled, display: display, adapterConnected: ac,
                                          deadline: deadline, now: now, locked: locked)
    }

    func testAssertion_DisplayOptionPicksTheDisplayKind() {
        XCTAssertEqual(assertion(display: true), .display)
        XCTAssertEqual(assertion(display: false), .system)
    }

    func testAssertion_DisplayOptionObeysTheSameGatesAsTheToggle() {
        XCTAssertNil(assertion(enabled: false, display: true), "The display option alone holds nothing")
        XCTAssertNil(assertion(display: true, ac: false), "Never on battery")
        XCTAssertNil(assertion(display: true, deadline: now), "An ended session holds nothing")
        XCTAssertEqual(assertion(display: true, deadline: now.addingTimeInterval(1)), .display)
    }

    func testAssertion_KindsMapToTheirPowerdTypes() {
        XCTAssertEqual(BatteryMonitor.KeepAwakeAssertion.system.type as String, "PreventUserIdleSystemSleep")
        XCTAssertEqual(BatteryMonitor.KeepAwakeAssertion.display.type as String, "PreventUserIdleDisplaySleep")
        XCTAssertNotEqual(BatteryMonitor.KeepAwakeAssertion.system.name, BatteryMonitor.KeepAwakeAssertion.display.name,
                          "pmset -g assertions must tell the two apart")
    }

    // MARK: - The paid license (keepAwakeLocked)

    /// Keep Awake is a paid feature: without the paid license nothing is
    /// held, whatever the switch, the adapter and the deadline say; with it
    /// (the default, so every rule above is a paid copy's) all is as before.
    func testLocked_NeverDesired() {
        XCTAssertFalse(BatteryMonitor.keepAwakeAssertionDesired(
            enabled: true, adapterConnected: true, deadline: nil, now: now, locked: true))
        XCTAssertFalse(BatteryMonitor.keepAwakeAssertionDesired(
            enabled: true, adapterConnected: true, deadline: now.addingTimeInterval(3600), now: now, locked: true))
        XCTAssertNil(assertion(display: true, locked: true))
        XCTAssertNil(assertion(display: false, locked: true))
        XCTAssertEqual(assertion(display: false, locked: false), .system)
    }

    /// Losing the paid license mid-session ends the session, ahead of the
    /// deadline and the adapter, and even while the adapter state is
    /// unknown; a copy with no session has nothing to end.
    func testSessionEnd_LosingThePaidLicenseEndsTheSession() {
        XCTAssertEqual(end(locked: true), .locked)
        XCTAssertEqual(end(ac: false, deadline: now, locked: true), .locked)
        XCTAssertEqual(end(ac: nil, locked: true), .locked)
        XCTAssertNil(end(enabled: false, locked: true))
        XCTAssertNil(end(locked: false), "a paid license changes nothing")
    }

    // MARK: - The menu bar countdown

    private func countdown(_ seconds: TimeInterval) -> BatteryMonitor.KeepAwakeCountdown {
        BatteryMonitor.keepAwakeCountdown(deadline: now.addingTimeInterval(seconds), now: now)
    }

    /// Whole minutes, rounded up: a fresh session reads its full length and
    /// the last minute reads "1m" to its end.
    func testCountdown_RoundsUpToWholeMinutes() {
        XCTAssertEqual(countdown(15 * 60).label, "15m")
        XCTAssertEqual(countdown(15 * 60 - 1).label, "15m")
        XCTAssertEqual(countdown(14 * 60).label, "14m")
        XCTAssertEqual(countdown(60).label, "1m")
        XCTAssertEqual(countdown(1).label, "1m")
    }

    /// The expiry timer ends the session half a second after the deadline;
    /// until it does the text stays "1m", it never turns to "0m".
    func testCountdown_NeverReadsZero() {
        XCTAssertEqual(countdown(0).label, "1m")
        XCTAssertEqual(countdown(-0.5).label, "1m")
        XCTAssertNil(countdown(0).nextChange)
        XCTAssertNil(countdown(-0.5).nextChange)
    }

    /// Two-digit minutes past the hour, so the text keeps its width from
    /// one minute to the next and the menu bar item does not twitch.
    func testCountdown_PastTheHourTheMinutesKeepTwoDigits() {
        XCTAssertEqual(countdown(105 * 60).label, "1h 45m")
        XCTAssertEqual(countdown(69 * 60).label, "1h 09m")
        XCTAssertEqual(countdown(60 * 60).label, "1h 00m")
        XCTAssertEqual(countdown(60 * 60 - 1).label, "1h 00m")
        XCTAssertEqual(countdown(59 * 60).label, "59m")
        XCTAssertEqual(countdown(8 * 3600).label, "8h 00m")
    }

    /// Every preset's fresh session reads its own length.
    func testCountdown_EveryPresetStartsAtItsLength() {
        let labels = BatteryMonitor.keepAwakeDurations.filter { $0 > 0 }.map { countdown(TimeInterval($0) * 60).label }
        XCTAssertEqual(labels, ["15m", "30m", "1h 00m", "2h 00m", "4h 00m", "8h 00m"])
    }

    /// The text is due a redraw the moment the remaining time drops to the
    /// next whole minute, and a redraw a touch after that reads one less.
    func testCountdown_NextChangeIsTheNextWholeMinute() throws {
        XCTAssertEqual(try XCTUnwrap(countdown(15 * 60).nextChange), 60, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(countdown(14 * 60 + 20).nextChange), 20, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(countdown(60.5).nextChange), 0.5, accuracy: 1e-6)
        let deadline = now.addingTimeInterval(14 * 60 + 20)
        let later = now.addingTimeInterval(try XCTUnwrap(countdown(14 * 60 + 20).nextChange) + 0.05)
        XCTAssertEqual(BatteryMonitor.keepAwakeCountdown(deadline: deadline, now: later).label, "14m")
    }

    /// The last minute has no next text: the session ends instead.
    func testCountdown_LastMinuteHasNoNextChange() {
        XCTAssertNil(countdown(60).nextChange)
        XCTAssertNil(countdown(30).nextChange)
    }

    /// A deadline read back from damaged preferences must not crash the
    /// conversion to minutes, whatever it holds.
    func testCountdown_DamagedDeadlinesDoNotTrap() {
        let far = BatteryMonitor.keepAwakeCountdown(deadline: .distantFuture, now: now)
        XCTAssertEqual(far.label, "99h 59m")
        XCTAssertEqual(far.nextChange, 60)
        XCTAssertEqual(BatteryMonitor.keepAwakeCountdown(deadline: .distantPast, now: now).label, "1m")
        for broken in [Double.nan, .infinity, -.infinity] {
            let c = BatteryMonitor.keepAwakeCountdown(deadline: Date(timeIntervalSince1970: broken), now: now)
            XCTAssertEqual(c.label, "1m")
            XCTAssertNil(c.nextChange)
        }
    }

    // MARK: - The menu bar indicator

    private func indicator(enabled: Bool = true, display: Bool = false, minutes: Double? = 105,
                           showTime: Bool = true) -> BatteryMonitor.KeepAwakeIndicator? {
        BatteryMonitor.keepAwakeIndicator(
            enabled: enabled, display: display, deadline: minutes.map { now.addingTimeInterval($0 * 60) },
            showTime: showTime, now: now)
    }

    func testIndicator_NoneWithoutASession() {
        XCTAssertNil(indicator(enabled: false))
        XCTAssertNil(indicator(enabled: false, display: true, minutes: nil))
    }

    func testIndicator_SymbolFollowsTheDisplayOption() {
        XCTAssertEqual(indicator(), .init(display: false, time: "1h 45m"))
        XCTAssertEqual(indicator(display: true), .init(display: true, time: "1h 45m"))
    }

    /// The symbol shows for every session; the time only for a timed one,
    /// and only while the Settings switch is on.
    func testIndicator_TimeOnlyForATimedSessionWithTheSwitchOn() {
        XCTAssertEqual(indicator(minutes: nil), .init(display: false, time: nil), "Forever has no time to show")
        XCTAssertEqual(indicator(showTime: false), .init(display: false, time: nil))
        XCTAssertEqual(indicator(display: true, showTime: false), .init(display: true, time: nil),
                       "The display badge stays with the time switched off")
    }

    // MARK: - The menu bar hover text

    func testToolTip_NamesTheEndAndWhatTheDisplayDoes() {
        let deadline = now.addingTimeInterval(3600)
        let until = "until " + deadline.formatted(date: .omitted, time: .shortened)
        XCTAssertEqual(BatteryMonitor.keepAwakeToolTip(enabled: true, display: false, deadline: deadline),
                       "Keep Awake \(until). The display still sleeps on its own schedule.")
        XCTAssertEqual(BatteryMonitor.keepAwakeToolTip(enabled: true, display: true, deadline: deadline),
                       "Keep Awake \(until). The display is kept on, so the Mac does not lock on its own.")
        XCTAssertEqual(BatteryMonitor.keepAwakeToolTip(enabled: true, display: false, deadline: nil),
                       "Keep Awake until turned off. The display still sleeps on its own schedule.")
    }

    func testToolTip_NoneWithoutASession() {
        XCTAssertNil(BatteryMonitor.keepAwakeToolTip(enabled: false, display: false, deadline: nil))
        XCTAssertNil(BatteryMonitor.keepAwakeToolTip(enabled: false, display: true, deadline: now.addingTimeInterval(60)))
    }
}
