import XCTest
import Shared

/// Pins the launchd job the app registers to uninstall its helper once the
/// bundle is gone, and the rules deciding when that has happened.
final class CleanupDaemonTests: XCTestCase {
    private let bundle = "/Applications/Ampere.app"
    private let identifier = "com.az-code-lab.ampere"

    private func parse(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "ampere-cleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testJobRunsTheInstalledHelperAtBootAndWheneverTheBundleChanges() throws {
        let job = try parse(CleanupDaemon.plist(bundlePath: bundle))
        XCTAssertEqual(job["Label"] as? String, "com.az-code-lab.ampere.cleanup")
        XCTAssertEqual(job["ProgramArguments"] as? [String],
                       ["/Library/PrivilegedHelperTools/az-ampere-smc", "uninstall-if-missing:/Applications/Ampere.app"])
        XCTAssertEqual(job["WatchPaths"] as? [String], [bundle])
        XCTAssertEqual(job["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(job["AssociatedBundleIdentifiers"] as? [String], [identifier],
                       "listed under Ampere in System Settings > Login Items")
        XCTAssertEqual(job.count, 5)
    }

    func testPlistIsByteStableAndEscapesThePath() throws {
        XCTAssertEqual(CleanupDaemon.plist(bundlePath: bundle), CleanupDaemon.plist(bundlePath: bundle))
        XCTAssertNotEqual(CleanupDaemon.plist(bundlePath: bundle),
                          CleanupDaemon.plist(bundlePath: "/Users/me/Applications/Ampere.app"))
        let awkward = "/Users/me/Apps & <tools>/Ampere.app"
        XCTAssertEqual(try parse(CleanupDaemon.plist(bundlePath: awkward))["WatchPaths"] as? [String], [awkward])
    }

    func testIsRegisteredComparesTheInstalledJobWithThisCopy() throws {
        let plist = try temporaryDirectory().appending(path: "job.plist").path
        XCTAssertFalse(CleanupDaemon.isRegistered(bundlePath: bundle, plistPath: plist), "no job yet")
        try CleanupDaemon.plist(bundlePath: bundle).write(to: URL(fileURLWithPath: plist))
        XCTAssertTrue(CleanupDaemon.isRegistered(bundlePath: bundle, plistPath: plist))
        XCTAssertFalse(CleanupDaemon.isRegistered(bundlePath: "/Users/me/Ampere.app", plistPath: plist),
                       "a moved app registers again")
    }

    func testOnlyAnInstalledCopyOfTheAppIsEligible() {
        func eligible(_ path: String, _ id: String? = "com.az-code-lab.ampere") -> String? {
            CleanupDaemon.eligibleBundlePath(bundleURL: URL(fileURLWithPath: path), bundleIdentifier: id)
        }
        XCTAssertEqual(eligible(bundle), bundle)
        XCTAssertEqual(eligible("/Applications/Ampere.app/"), bundle, "trailing slash normalized")
        XCTAssertEqual(eligible("/Users/me/Applications/Ampere.app"), "/Users/me/Applications/Ampere.app")
        XCTAssertNil(eligible("/Users/me/ampere/.build/debug", nil), "bare debug executable")
        XCTAssertNil(eligible(bundle, nil))
        XCTAssertNil(eligible(bundle, "com.apple.dt.xctest.tool"), "another bundle")
        XCTAssertNil(eligible("/private/var/folders/xy/T/AppTranslocation/1F2E/d/Ampere.app"),
                     "a translocated path vanishes at every quit")
    }

    func testWatchedPathShape() {
        XCTAssertTrue(CleanupDaemon.isValidBundlePath(bundle))
        XCTAssertTrue(CleanupDaemon.isValidBundlePath("/Users/me/Apps & <tools>/Ampere.app"))
        for invalid in ["", "/", "Applications/Ampere.app", "/Applications/Ampere.app/",
                        "/Applications//Ampere.app", "/Applications/./Ampere.app", "/Applications/../Ampere.app"] {
            XCTAssertFalse(CleanupDaemon.isValidBundlePath(invalid), invalid)
        }
    }

    func testRootAcceptsOnlyARealAmpereBundle() throws {
        let app = try temporaryDirectory().appending(path: "Ampere.app")
        XCTAssertFalse(CleanupDaemon.isAppBundle(at: app.path), "missing")
        let contents = app.appending(path: "Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        func writeInfo(_ id: String) throws {
            let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id],
                                                          format: .xml, options: 0)
            try data.write(to: contents.appending(path: "Info.plist"))
        }
        try writeInfo("com.example.other")
        XCTAssertFalse(CleanupDaemon.isAppBundle(at: app.path), "another app")
        try writeInfo(identifier)
        XCTAssertTrue(CleanupDaemon.isAppBundle(at: app.path))
    }

    func testAMissingBundleCountsAsAnUninstallOnlyWhenItIsReallyGone() {
        XCTAssertTrue(CleanupDaemon.shouldUninstall(bundleExists: false, parentExists: true, appRunning: false))
        XCTAssertFalse(CleanupDaemon.shouldUninstall(bundleExists: true, parentExists: true, appRunning: false),
                       "still installed")
        XCTAssertFalse(CleanupDaemon.shouldUninstall(bundleExists: false, parentExists: false, appRunning: false),
                       "volume not mounted")
        XCTAssertFalse(CleanupDaemon.shouldUninstall(bundleExists: false, parentExists: true, appRunning: true),
                       "moved while running")
    }
}
