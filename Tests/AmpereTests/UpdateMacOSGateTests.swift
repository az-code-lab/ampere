import XCTest
@testable import Ampere

/// Pins the two places the self-updater asks "can this Mac run the new
/// release?": before offering it (the cask's minimum macOS) and before
/// swapping it in (the downloaded bundle's own minimum). The second is the
/// one that matters most: a swapped-in app that macOS refuses to open would
/// leave the Mac with no Ampere at all.
final class UpdateMacOSGateTests: XCTestCase {

    private let goodSHA = String(repeating: "ab", count: 32)

    // MARK: Offer decision

    private func update(_ version: String, minimumMacOS: String?) -> AvailableUpdate {
        AvailableUpdate(version: version, dmgURL: URL(string: "https://example.com/Ampere.dmg")!,
                        sha256: goodSHA, minimumMacOS: minimumMacOS)
    }

    func testOffer_NewerReleaseOnASupportedMac_Available() {
        XCTAssertEqual(BatteryMonitor.updateOffer(update("0.0.66", minimumMacOS: "26"), installed: "0.0.65", running: "26.0"), .available)
        XCTAssertEqual(BatteryMonitor.updateOffer(update("0.0.66", minimumMacOS: "26"), installed: "0.0.65", running: "27.1.2"), .available)
        XCTAssertEqual(BatteryMonitor.updateOffer(update("0.0.66", minimumMacOS: nil), installed: "0.0.65", running: "15.7.4"), .available)
    }

    func testOffer_NewerReleaseOnAnOlderMacOS_NeedsNewerMacOS() {
        XCTAssertEqual(BatteryMonitor.updateOffer(update("0.0.66", minimumMacOS: "26"), installed: "0.0.65", running: "15.7.4"),
                       .needsNewerMacOS("26"))
        XCTAssertEqual(BatteryMonitor.updateOffer(update("0.0.66", minimumMacOS: "27"), installed: "0.0.65", running: "26.7.1"),
                       .needsNewerMacOS("27"))
    }

    func testOffer_NotNewer_UpToDateEvenWhenMacOSIsTooOld() {
        // Nothing to install means nothing to refuse: the macOS question is
        // only asked about a release that would otherwise be offered.
        XCTAssertEqual(BatteryMonitor.updateOffer(update("0.0.65", minimumMacOS: "26"), installed: "0.0.65", running: "15.7.4"), .upToDate)
        XCTAssertEqual(BatteryMonitor.updateOffer(update("0.0.64", minimumMacOS: "26"), installed: "0.0.65", running: "15.7.4"), .upToDate)
    }

    func testOffer_DevBuild_UpToDate() {
        // A git-describe version never compares as older (see VersionCompareTests).
        XCTAssertEqual(BatteryMonitor.updateOffer(update("0.0.66", minimumMacOS: "26"), installed: "v0.0.65-3-g6d18eea", running: "15.7.4"), .upToDate)
    }

    // MARK: Launch check on the downloaded bundle

    func testLaunchBlocker_NoDeclaredMinimum_Nil() {
        XCTAssertNil(BatteryMonitor.launchBlocker(minimumSystemVersion: nil, running: "15.7.4"))
    }

    func testLaunchBlocker_MinimumMet_Nil() {
        XCTAssertNil(BatteryMonitor.launchBlocker(minimumSystemVersion: "14.0", running: "15.7.4"))
        XCTAssertNil(BatteryMonitor.launchBlocker(minimumSystemVersion: "26.0", running: "26.0"))
        XCTAssertNil(BatteryMonitor.launchBlocker(minimumSystemVersion: "26.0", running: "27.0"))
        XCTAssertNil(BatteryMonitor.launchBlocker(minimumSystemVersion: "26.4", running: "26.4.1"))
    }

    func testLaunchBlocker_MacOSTooOld_Blocks() {
        let blocker = BatteryMonitor.launchBlocker(minimumSystemVersion: "26.0", running: "15.7.4")
        XCTAssertEqual(blocker, "The new version needs macOS 26.0 or later, and this Mac runs macOS 15.7.4")
        XCTAssertNotNil(BatteryMonitor.launchBlocker(minimumSystemVersion: "26.4", running: "26.3.2"))
        XCTAssertNotNil(BatteryMonitor.launchBlocker(minimumSystemVersion: "26.0.1", running: "26.0"))
    }

    func testLaunchBlocker_UnreadableMinimum_Blocks() {
        // An answer that cannot be read counts as "no": a swapped-in app
        // that macOS refuses to open leaves the Mac without Ampere.
        XCTAssertNotNil(BatteryMonitor.launchBlocker(minimumSystemVersion: "", running: "27.0"))
        XCTAssertNotNil(BatteryMonitor.launchBlocker(minimumSystemVersion: "tahoe", running: "27.0"))
        XCTAssertNotNil(BatteryMonitor.launchBlocker(minimumSystemVersion: "26.x", running: "27.0"))
    }

    // MARK: Reported macOS version

    func testSystemVersionString_DropsAZeroPatchOnly() {
        XCTAssertEqual(SystemVersion.string(OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)), "27.0")
        XCTAssertEqual(SystemVersion.string(OperatingSystemVersion(majorVersion: 26, minorVersion: 7, patchVersion: 1)), "26.7.1")
        XCTAssertEqual(SystemVersion.string(OperatingSystemVersion(majorVersion: 15, minorVersion: 7, patchVersion: 4)), "15.7.4")
    }

    func testSystemVersionCurrent_IsADottedVersionTheGateCanCompare() {
        XCTAssertNotNil(BatteryMonitor.parseDottedVersion(SystemVersion.current), SystemVersion.current)
    }
}
