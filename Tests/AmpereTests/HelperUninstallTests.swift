import XCTest
import Shared

final class HelperUninstallTests: XCTestCase {
    /// A real directory tree: the temporary directory sits behind the
    /// `/var` symlink, which the no-follow removal rightly refuses, and
    /// Foundation's resolver keeps that form, so resolve it with realpath.
    private func temporaryRoot() throws -> URL {
        let resolved = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(resolved) }
        let root = URL(fileURLWithPath: String(cString: resolved))
            .appending(path: "ampere-uninstall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testAFailedRestoreRemovesNothingAndKeepsTheJob() {
        var calls: [String] = []
        let status = HelperUninstall.run(restore: { calls.append("restore"); return false },
                                         removeArtifacts: { calls.append("remove"); return true },
                                         unloadDaemon: { calls.append("bootout") })
        XCTAssertEqual(status, 2)
        XCTAssertEqual(calls, ["restore"])
    }

    func testRemovalFollowsTheRestoreAndTheJobUnloadsLast() {
        var calls: [String] = []
        let status = HelperUninstall.run(restore: { calls.append("restore"); return true },
                                         removeArtifacts: { calls.append("remove"); return true },
                                         unloadDaemon: { calls.append("bootout") })
        XCTAssertEqual(status, 0)
        XCTAssertEqual(calls, ["restore", "remove", "bootout"])
    }

    func testAPartialRemovalIsReportedAfterUnloadingTheJob() {
        var calls: [String] = []
        let status = HelperUninstall.run(restore: { true },
                                         removeArtifacts: { calls.append("remove"); return false },
                                         unloadDaemon: { calls.append("bootout") })
        XCTAssertEqual(status, 3)
        XCTAssertEqual(calls, ["remove", "bootout"])
    }

    func testRemovesFilesAndTheStateDirectoryAndToleratesMissingOnes() throws {
        let root = try temporaryRoot()
        let state = root.appending(path: "state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try Data("1 2".utf8).write(to: state.appending(path: "saved-sleep"))
        let sudoers = root.appending(path: "sudoers").path
        let helper = root.appending(path: "helper").path
        let legacy = root.appending(path: "legacy").path
        for path in [sudoers, helper, legacy] { try Data("x".utf8).write(to: URL(fileURLWithPath: path)) }
        let link = root.appending(path: "link").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: helper)

        let artifacts = HelperUninstall.Artifacts(
            files: [sudoers, link, root.appending(path: "missing").path],
            legacyFiles: [legacy, root.appending(path: "missing-legacy").path],
            directories: [state.path, root.appending(path: "missing-dir").path])
        XCTAssertTrue(HelperUninstall.removeArtifacts(artifacts))
        for path in [sudoers, link, legacy, state.path] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path), path)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: helper), "the link was removed, not its target")
    }

    func testALegacyFileBehindADirectorySymlinkIsLeftAlone() throws {
        let root = try temporaryRoot()
        let real = root.appending(path: "real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let target = real.appending(path: "az-ampere-smc")
        try Data("x".utf8).write(to: target)
        let bin = root.appending(path: "bin")
        try FileManager.default.createSymbolicLink(at: bin, withDestinationURL: real)

        let artifacts = HelperUninstall.Artifacts(
            files: [], legacyFiles: [bin.appending(path: "az-ampere-smc").path], directories: [])
        XCTAssertFalse(HelperUninstall.removeArtifacts(artifacts))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func testUserDataCoversPreferencesCachesHTTPStorageAndSavedState() {
        XCTAssertEqual(HelperUninstall.userDataPaths, [
            "Library/Preferences/com.az-code-lab.ampere.plist",
            "Library/Caches/com.az-code-lab.ampere",
            "Library/HTTPStorages/com.az-code-lab.ampere",
            "Library/Saved Application State/com.az-code-lab.ampere.savedState",
        ])
    }

    func testRemovesUserDataFromEveryHomeAndToleratesMissingItems() throws {
        let root = try temporaryRoot()
        let prefs = "Library/Preferences/com.az-code-lab.ampere.plist"
        let cache = "Library/Caches/com.az-code-lab.ampere"
        let alice = root.appending(path: "alice")
        try FileManager.default.createDirectory(at: alice.appending(path: cache), withIntermediateDirectories: true)
        try Data("c".utf8).write(to: alice.appending(path: cache + "/Cache.db"))
        try FileManager.default.createDirectory(at: alice.appending(path: "Library/Preferences"),
                                                withIntermediateDirectories: true)
        try Data("p".utf8).write(to: alice.appending(path: prefs))
        // Bob's cache directory is a symlink: the link goes, its target stays.
        let elsewhere = root.appending(path: "elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: elsewhere.appending(path: "keep"))
        let bob = root.appending(path: "bob")
        try FileManager.default.createDirectory(at: bob.appending(path: "Library/Caches"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: bob.appending(path: cache), withDestinationURL: elsewhere)
        let carol = root.appending(path: "carol")

        XCTAssertTrue(HelperUninstall.removeUserData(homes: [alice.path, bob.path, carol.path],
                                                     paths: [prefs, cache]))
        func present(_ url: URL) -> Bool {
            var info = stat()
            return lstat(url.path, &info) == 0
        }
        XCTAssertFalse(present(alice.appending(path: prefs)))
        XCTAssertFalse(present(alice.appending(path: cache)))
        XCTAssertFalse(present(bob.appending(path: cache)), "the link itself is removed")
        XCTAssertTrue(present(elsewhere.appending(path: "keep")), "never followed")
        XCTAssertFalse(present(carol), "a home with nothing of ours is not created")
    }

    func testLocalAccountsListTheMacsOwnAccounts() {
        let accounts = HelperUninstall.localAccounts()
        let me = accounts.first { $0.uid == getuid() }
        XCTAssertNotNil(me, "\(accounts)")
        XCTAssertEqual(me?.home, NSHomeDirectory())
        XCTAssertEqual(me?.name, NSUserName())
        XCTAssertFalse(accounts.contains { $0.uid == 0 }, "root and system accounts are skipped")
        XCTAssertFalse(accounts.contains { $0.home == "/var/empty" })
    }

    func testClearPreferencesCommandGoesThroughTheUsersCfprefsd() {
        let command = HelperUninstall.clearPreferencesCommand(uid: 501, username: "alice")
        XCTAssertEqual(command.launchPath, "/bin/launchctl")
        XCTAssertEqual(command.arguments,
                       ["asuser", "501", "/usr/bin/sudo", "-n", "-u", "alice",
                        "/usr/bin/defaults", "delete", "com.az-code-lab.ampere"],
                       "asuser enters the user's bootstrap; sudo -n -u reaches their cfprefsd without a prompt")
    }

    func testInstalledArtifactsCoverEveryPrivilegedFile() {
        let installed = HelperUninstall.Artifacts.installed
        XCTAssertEqual(installed.files, ["/etc/sudoers.d/az-ampere",
                                         "/Library/PrivilegedHelperTools/az-ampere-smc",
                                         "/Library/LaunchDaemons/com.az-code-lab.ampere.cleanup.plist"])
        XCTAssertEqual(installed.legacyFiles, ["/usr/local/bin/az-ampere-smc"])
        XCTAssertEqual(installed.directories, ["/Library/Application Support/az-ampere"])
    }
}
