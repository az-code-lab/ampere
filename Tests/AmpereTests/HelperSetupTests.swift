import XCTest
import CryptoKit
@testable import Ampere

/// Executes the real transaction in a disposable directory. The replacement
/// is a harmless shell fixture, and chown is stubbed. visudo only checks
/// the temporary rule; no sudo, SMC, pmset, or installed files are touched.
final class HelperSetupTests: XCTestCase {
    private final class Fixture {
        let root: URL
        let paths: HelperSetup.Paths
        let writer: URL
        let events: URL
        let failRestore: URL
        let state: URL
        let marker: URL
        let digest: String

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "ampere-setup-\(UUID().uuidString)")
            paths = HelperSetup.Paths(directory: root.appending(path: "protected").path,
                helper: root.appending(path: "protected/az-ampere-smc").path,
                legacy: root.appending(path: "legacy/bin/az-ampere-smc").path,
                sudoers: root.appending(path: "sudoers.d/az-ampere").path)
            writer = root.appending(path: "bundled helper's $(not-a-command)")
            events = root.appending(path: "events")
            failRestore = root.appending(path: "fail-restore")
            state = root.appending(path: "state")
            marker = state.appending(path: "saved-sleep")
            for directory in [paths.directory, (paths.legacy as NSString).deletingLastPathComponent,
                              (paths.sudoers as NSString).deletingLastPathComponent, state.path] {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            }
            let contents = """
            #!/bin/sh
            /usr/bin/printf '%s\\n' "$1" >> \(HelperSetup.quote(events.path))
            if [ "$1" = restore ]; then
                if [ -f \(HelperSetup.quote(failRestore.path)) ]; then exit 2; fi
                /bin/rm -f \(HelperSetup.quote(marker.path))
            fi
            if [ "$1" = remove-legacy ]; then
                /bin/rm -f \(HelperSetup.quote(paths.legacy))
            fi
            """
            let data = Data(contents.utf8)
            digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            try data.write(to: writer)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: writer.path)
            try Data("old helper must never execute".utf8).write(to: URL(fileURLWithPath: paths.legacy))
            try Data("old sudoers".utf8).write(to: URL(fileURLWithPath: paths.sudoers))
            try Data("17 29".utf8).write(to: marker)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        var calls: [String] {
            ((try? String(contentsOf: events, encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }

        func install(digest override: String? = nil) -> String {
            HelperSetup.installScript(writer: writer.path, digest: override ?? digest,
                username: "test_user", appPID: 123, paths: paths)
                .replacingOccurrences(of: "/usr/sbin/chown root:wheel", with: "/usr/bin/true")
        }

        func removal() throws -> String {
            try FileManager.default.copyItem(at: writer, to: URL(fileURLWithPath: paths.helper))
            return HelperSetup.removalScript(paths: paths, stateDirectory: state.path, legacyMarkers: [])
        }
    }

    private func run(_ script: String) throws -> (status: Int32, output: String) {
        let task = Process(), output = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script]
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = output
        task.standardError = output
        try task.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func testMigrationVerifiesInstallsRestoresAndRemovesLegacyHelper() throws {
        let fixture = try Fixture()
        let result = try run(fixture.install())
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(fixture.calls, ["restore", "remove-legacy", "spawn-watchdog:123"])
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: fixture.paths.helper)),
                       try Data(contentsOf: fixture.writer))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.legacy))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.marker.path))
        XCTAssertEqual(try String(contentsOfFile: fixture.paths.sudoers),
                       "test_user ALL=(root) NOPASSWD: sha256:\(fixture.digest) \(fixture.paths.helper)\n")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.paths.directory), ["az-ampere-smc"])
    }

    func testDigestMismatchCannotExecuteOrReplaceAnything() throws {
        let fixture = try Fixture()
        let result = try run(fixture.install(digest: String(repeating: "0", count: 64)))
        XCTAssertNotEqual(result.status, 0)
        XCTAssertEqual(fixture.calls, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.helper))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.paths.legacy))
        XCTAssertEqual(try String(contentsOfFile: fixture.paths.sudoers), "old sudoers")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.marker.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.paths.directory), [])
    }

    /// The rule must land even when cleanup fails: without it every later
    /// launch would prompt, fail the same way, and quit. The saved settings
    /// stay for the launch cleanup and the new watchdog to retry.
    func testFailedRestoreStillInstallsRuleAndStartsRecoveryFromNewHelper() throws {
        let fixture = try Fixture()
        try Data().write(to: fixture.failRestore)
        let result = try run(fixture.install())
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(fixture.calls, ["restore", "remove-legacy", "spawn-watchdog:123"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.paths.helper))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.legacy))
        XCTAssertEqual(try String(contentsOfFile: fixture.paths.sudoers),
                       "test_user ALL=(root) NOPASSWD: sha256:\(fixture.digest) \(fixture.paths.helper)\n")
        XCTAssertEqual(try String(contentsOf: fixture.marker), "17 29")
    }

    func testRevokeFailurePreservesHelperRuleAndSavedSettings() throws {
        let fixture = try Fixture()
        try Data().write(to: fixture.failRestore)
        let result = try run(fixture.removal())
        XCTAssertNotEqual(result.status, 0)
        XCTAssertEqual(fixture.calls, ["restore"])
        for path in [fixture.paths.helper, fixture.paths.legacy, fixture.paths.sudoers, fixture.marker.path] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: path), path)
        }
    }

    func testRevokeSuccessRestoresBeforeRemovingPrivilegedFiles() throws {
        let fixture = try Fixture()
        let result = try run(fixture.removal())
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(fixture.calls, ["restore", "remove-legacy"])
        for path in [fixture.paths.helper, fixture.paths.legacy, fixture.paths.sudoers, fixture.state.path] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path), path)
        }
    }
}
