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
        typealias Location = InstanceGuard.ExecutableLocation
        let moved = "/Users/me/Applications/Ampere.app/Contents/MacOS/Ampere"
        let trashed = "/Users/me/.Trash/Ampere.app/Contents/MacOS/Ampere"
        let onDisk: Set<String> = [moved, trashed]
        func verdict(parent: Bool = true, _ running: [Location]) -> CleanupDaemon.Verdict {
            CleanupDaemon.verdict(parentExists: parent, runningFrom: running, exists: { onDisk.contains($0) })
        }
        XCTAssertEqual(verdict([]), .uninstall)
        XCTAssertEqual(verdict(parent: false, []), .keep("its volume is not mounted"))
        XCTAssertEqual(verdict([.exited]), .uninstall, "a copy that exited since it was listed does not count")
        // Moved while running: it re-registers the job on relaunch.
        XCTAssertEqual(verdict([.at(moved)]), .keep("a copy of Ampere is running from \(moved)"))
        XCTAssertEqual(verdict([.deleted, .at(moved)]), .keep("a copy of Ampere is running from \(moved)"))
        // Deleted from under itself, trashed, or at a path that is gone: on
        // its way out, so the job waits for it to quit.
        XCTAssertEqual(verdict([.deleted]), .awaitQuit)
        XCTAssertEqual(verdict([.at(trashed)]), .awaitQuit)
        XCTAssertEqual(verdict([.at("/Applications/Ampere.app/Contents/MacOS/Ampere")]), .awaitQuit)
        XCTAssertEqual(verdict([.exited, .deleted]), .awaitQuit)
        // A copy the kernel cannot place: nothing is removed.
        XCTAssertEqual(verdict([.unknown]), .keep("a copy of Ampere is running"))
        XCTAssertEqual(verdict([.deleted, .unknown]), .keep("a copy of Ampere is running"))
    }

    func testTrashFoldersAreRecognized() {
        XCTAssertTrue(CleanupDaemon.isInTrash("/Users/me/.Trash/Ampere.app/Contents/MacOS/Ampere"))
        XCTAssertTrue(CleanupDaemon.isInTrash("/Volumes/Data/.Trashes/501/Ampere.app/Contents/MacOS/Ampere"))
        XCTAssertFalse(CleanupDaemon.isInTrash("/Applications/Ampere.app/Contents/MacOS/Ampere"))
        XCTAssertFalse(CleanupDaemon.isInTrash("/Users/me/Trash/Ampere.app/Contents/MacOS/Ampere"),
                       "a folder merely named Trash")
        XCTAssertFalse(CleanupDaemon.isInTrash("/Users/me/.Trashed/Ampere.app/Contents/MacOS/Ampere"))
    }

    func testTheGracePeriodStartsWhenTheBundleIsFirstSeenMissingAndAnySightingEndsIt() {
        var waits: [UInt32] = []
        // In place when the job starts (boot, or a change to the path that
        // is not a removal): no wait at all, so the end of a wait can never
        // coincide with the gap an upgrade leaves.
        XCTAssertFalse(CleanupDaemon.stayedMissing(exists: { true }, wait: { waits.append($0) }))
        XCTAssertEqual(waits, [])
        // Missing throughout: looked for after every poll and once more at
        // the end of the period.
        var looks = 0
        XCTAssertTrue(CleanupDaemon.stayedMissing(gracePeriod: 120, poll: 5,
                                                  exists: { looks += 1; return false },
                                                  wait: { waits.append($0) }))
        XCTAssertEqual(waits.reduce(0, +), 120)
        XCTAssertEqual(looks, 25)
        // Back within the period (an undo, an upgrade placing the new
        // bundle): the run ends at that sighting.
        waits = []
        var sightings = [false, false, true]
        XCTAssertFalse(CleanupDaemon.stayedMissing(gracePeriod: 120, poll: 5,
                                                   exists: { sightings.removeFirst() },
                                                   wait: { waits.append($0) }))
        XCTAssertEqual(waits, [5, 5])
        // The last poll is cut to what remains of the period.
        waits = []
        XCTAssertTrue(CleanupDaemon.stayedMissing(gracePeriod: 7, poll: 5, exists: { false },
                                                  wait: { waits.append($0) }))
        XCTAssertEqual(waits, [5, 2])
    }
}
