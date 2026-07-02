import XCTest
@testable import Ampere

/// Pins `BatteryMonitor.isNewerVersion`, in particular the strict-parse rule:
/// dev builds report a git hash or `git describe` string instead of a dotted
/// release version, and those must never produce an "update available" badge.
final class VersionCompareTests: XCTestCase {

    func testNewerPatchVersion() {
        XCTAssertTrue(BatteryMonitor.isNewerVersion("0.0.19", than: "0.0.18"))
        XCTAssertFalse(BatteryMonitor.isNewerVersion("0.0.18", than: "0.0.19"))
    }

    func testEqualVersions_NotNewer() {
        XCTAssertFalse(BatteryMonitor.isNewerVersion("0.0.18", than: "0.0.18"))
    }

    func testDifferentComponentCounts() {
        // Missing components compare as 0.
        XCTAssertTrue(BatteryMonitor.isNewerVersion("0.1", than: "0.0.9"))
        XCTAssertFalse(BatteryMonitor.isNewerVersion("1.0", than: "1.0.0"))
        XCTAssertTrue(BatteryMonitor.isNewerVersion("1.0.1", than: "1.0"))
    }

    func testDevBuildGitHash_NeverFlagsUpdate() {
        XCTAssertFalse(BatteryMonitor.isNewerVersion("0.0.19", than: "6d18eea"))
    }

    func testDevBuildGitDescribe_NeverFlagsUpdate() {
        // AppVersion trims a leading "v"; the "-3-g6d18eea" suffix makes the
        // last component non-numeric, so the whole string must be rejected
        // rather than partially parsed as [0, 0].
        XCTAssertFalse(BatteryMonitor.isNewerVersion("0.0.19", than: "0.0.18-3-g6d18eea"))
    }

    func testUnparseableRemote_NeverFlagsUpdate() {
        XCTAssertFalse(BatteryMonitor.isNewerVersion("garbage", than: "0.0.18"))
        XCTAssertFalse(BatteryMonitor.isNewerVersion("", than: "0.0.18"))
    }
}
