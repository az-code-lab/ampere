import XCTest
import Shared

/// The unified-log wrapper keeps NSLog's printf-style formats, since every
/// call site was converted mechanically.
final class AmpereLogTests: XCTestCase {
    func testRenderKeepsNSLogSemantics() {
        XCTAssertEqual(AmpereLog.render("Ampere: Auto-discharge started at %d%%, target %d%%", [61, 60]),
                       "Ampere: Auto-discharge started at 61%, target 60%")
        XCTAssertEqual(AmpereLog.render("Ampere: %@ chargeToUpperBound at %d%%", ["Set", 40]),
                       "Ampere: Set chargeToUpperBound at 40%")
        XCTAssertEqual(AmpereLog.render("Ampere: Keep-awake assertion create failed (0x%08x)", [UInt32(0xe00002c1)]),
                       "Ampere: Keep-awake assertion create failed (0xe00002c1)")
        XCTAssertEqual(AmpereLog.render("Ampere: Launch cleanup done (inhibit=%d)", [true]),
                       "Ampere: Launch cleanup done (inhibit=1)")
        XCTAssertEqual(AmpereLog.render("Ampere: sudo failed (arg=%@ status=%d): %@", ["inhibit", Int32(2), "ERROR: x"]),
                       "Ampere: sudo failed (arg=inhibit status=2): ERROR: x")
        XCTAssertEqual(AmpereLog.render("plain message, 100%%", []), "plain message, 100%")
    }

    /// Emits one line per category through the real wrapper, so a test run
    /// leaves something to check by hand:
    ///     log show --last 5m --predicate 'subsystem == "com.az-code-lab.ampere"'
    func testEmitsThroughTheUnifiedLog() {
        AmpereLog.app("Ampere: log wrapper self-test %d", 1)
        AmpereLog.helper("Ampere: helper log wrapper self-test %d", 2)
    }
}
