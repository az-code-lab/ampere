import XCTest
import Shared

/// Pins the pmset save/restore plumbing behind discharge's sleep override.
/// The values parsed here are what the SMCWriter helper writes back to the
/// user's power profiles after a discharge — a wrong parse either strands
/// the user with sleep disabled (missing capture aborts the discharge, the
/// safe direction) or restores the wrong minutes (the harmful one).
final class PmsetStateTests: XCTestCase {

    /// Mirrors real `pmset -g custom` output (captured on an M-series
    /// MacBook), including keys that share the "sleep" suffix/stem —
    /// "disksleep", "displaysleep", "Sleep On Power Button" — which the
    /// parser must not confuse with "sleep" itself.
    private let realOutput = """
        Battery Power:
         Sleep On Power Button 1
         powermode            0
         standby              1
         hibernatefile        /var/vm/sleepimage
         displaysleep         5
         womp                 0
         sleep                10
         lessbright           1
         disksleep            10
        AC Power:
         Sleep On Power Button 1
         standby              1
         hibernatefile        /var/vm/sleepimage
         displaysleep         15
         womp                 1
         sleep                0
         disksleep            10
        """

    // MARK: - profileValues

    func testParsesBothProfiles_Sleep() {
        XCTAssertEqual(
            PmsetState.profileValues(forKey: "sleep", inCustomOutput: realOutput),
            PmsetProfileValues(battery: 10, ac: 0)
        )
    }

    func testParsesBothProfiles_DisplaySleep() {
        XCTAssertEqual(
            PmsetState.profileValues(forKey: "displaysleep", inCustomOutput: realOutput),
            PmsetProfileValues(battery: 5, ac: 15)
        )
    }

    func testKeyMustMatchExactly_NotPrefixOfLongerKey() {
        // A section containing only displaysleep/disksleep must not satisfy
        // a "sleep" lookup.
        let output = """
            Battery Power:
             displaysleep         5
             disksleep            10
            AC Power:
             displaysleep         5
             disksleep            10
            """
        XCTAssertNil(PmsetState.profileValues(forKey: "sleep", inCustomOutput: output))
    }

    func testMissingProfileSection_ReturnsNil() {
        // Partial capture must fail closed — the caller then refuses to
        // override sleep at all rather than fabricate one profile's value.
        let output = """
            AC Power:
             sleep                0
             displaysleep         15
            """
        XCTAssertNil(PmsetState.profileValues(forKey: "sleep", inCustomOutput: output))
    }

    func testMissingKeyInOneSection_ReturnsNil() {
        let output = """
            Battery Power:
             sleep                10
            AC Power:
             displaysleep         15
            """
        XCTAssertNil(PmsetState.profileValues(forKey: "sleep", inCustomOutput: output))
    }

    func testValueBeforeAnySectionHeader_Ignored() {
        let output = """
             sleep                7
            Battery Power:
             sleep                10
            AC Power:
             sleep                0
            """
        XCTAssertEqual(
            PmsetState.profileValues(forKey: "sleep", inCustomOutput: output),
            PmsetProfileValues(battery: 10, ac: 0)
        )
    }

    func testTrailingAnnotation_Tolerated() {
        // Live `pmset -g` annotates values ("sleep prevented by powerd");
        // -g custom shouldn't, but the parse must stay tolerant.
        let output = """
            Battery Power:
             sleep                1 (sleep prevented by powerd)
             displaysleep         5
            AC Power:
             sleep                0
             displaysleep         5
            """
        XCTAssertEqual(
            PmsetState.profileValues(forKey: "sleep", inCustomOutput: output),
            PmsetProfileValues(battery: 1, ac: 0)
        )
    }

    // MARK: - Marker round trip

    func testMarkerRoundTrip() {
        let values = PmsetProfileValues(battery: 10, ac: 0)
        XCTAssertEqual(PmsetState.markerString(values), "10 0")
        XCTAssertEqual(PmsetState.parseMarker("10 0"), values)
    }

    func testParseMarker_LegacySingleValue_AppliesToBothProfiles() {
        // Older builds saved one value (the active — always AC — profile)
        // and restored it with `pmset -a`, i.e. to both profiles. An
        // outstanding legacy marker must keep restoring exactly that way.
        XCTAssertEqual(
            PmsetState.parseMarker("15"),
            PmsetProfileValues(battery: 15, ac: 15)
        )
    }

    func testParseMarker_Garbage_ReturnsNil() {
        XCTAssertNil(PmsetState.parseMarker(""))
        XCTAssertNil(PmsetState.parseMarker("abc"))
        XCTAssertNil(PmsetState.parseMarker("10 abc"))
        XCTAssertNil(PmsetState.parseMarker("1 2 3"))
    }

    // MARK: - validMinutes

    func testValidMinutes_Bounds() {
        XCTAssertTrue(PmsetState.validMinutes(0), "0 = never sleep, a legitimate user setting")
        XCTAssertTrue(PmsetState.validMinutes(10))
        XCTAssertTrue(PmsetState.validMinutes(1440))
        XCTAssertFalse(PmsetState.validMinutes(-1))
        XCTAssertFalse(PmsetState.validMinutes(1441))
    }
}
