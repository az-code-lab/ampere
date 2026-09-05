import XCTest
@testable import Shared

final class HelperSecurityTests: XCTestCase {
    func testProtectedSystemPathsAndMissingInstallLeaf() {
        XCTAssertTrue(HelperSecurity.isProtected(path: "/bin/ls"))
        XCTAssertTrue(HelperSecurity.isProtected(path: "/Library", directory: true))
        XCTAssertTrue(HelperSecurity.canInstall(in: "/Library/ampere-test-\(UUID().uuidString)"))
        XCTAssertFalse(HelperSecurity.canInstall(in: "/Library/ampere-test-\(UUID().uuidString)/missing/leaf"))
    }

    func testWritableDirectoriesAndSymlinksAreRejected() {
        XCTAssertFalse(HelperSecurity.isProtected(path: "/private/tmp", directory: true))
        XCTAssertFalse(HelperSecurity.canInstall(in: "/private/tmp/ampere-test-\(UUID().uuidString)"))
        XCTAssertFalse(HelperSecurity.isProtected(path: "/var", directory: true), "macOS /var is a symlink")
        XCTAssertFalse(HelperSecurity.isProtected(path: "/var/db", directory: true), "Check ancestors too")
        XCTAssertFalse(HelperSecurity.isProtected(path: "/bin", directory: false))
        XCTAssertFalse(HelperSecurity.isProtected(path: "bin/ls"))
        XCTAssertTrue(HelperSecurity.hasWriteACL(path: "/Library/ampere-missing-\(UUID().uuidString)"))
    }

    func testUserOwnedExecutableAndWriteACLsAreRejected() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "ampere-acl-\(UUID().uuidString)")
        try Data("fixture".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        XCTAssertFalse(HelperSecurity.isProtected(path: file.path))
        XCTAssertFalse(HelperSecurity.hasWriteACL(path: file.path))

        func addACL(_ rule: String) throws {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/chmod")
            task.arguments = ["+a", rule, file.path]
            task.standardInput = FileHandle.nullDevice
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            try task.run()
            task.waitUntilExit()
            XCTAssertEqual(task.terminationStatus, 0)
        }
        try addACL("everyone allow read")
        XCTAssertFalse(HelperSecurity.hasWriteACL(path: file.path))
        try addACL("everyone allow write,delete,writeattr")
        XCTAssertTrue(HelperSecurity.hasWriteACL(path: file.path))
    }

    func testLegacyRemovalDoesNotFollowDirectoryOrLeafSymlinks() throws {
        // Spell out /private/tmp: Foundation canonicalizes its temporary
        // directory back to /var, which is itself a symlink on macOS.
        let root = URL(fileURLWithPath: "/private/tmp")
            .appending(path: "ampere-unlink-\(UUID().uuidString)")
        let destination = root.appending(path: "protected")
        let legacy = root.appending(path: "legacy")
        let target = destination.appending(path: "az-ampere-smc")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("keep".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: legacy, withDestinationURL: destination)
        XCTAssertFalse(HelperSecurity.removeFileWithoutFollowingDirectories(
            at: legacy.appending(path: "az-ampere-smc").path))
        XCTAssertEqual(try String(contentsOf: target), "keep")

        try FileManager.default.removeItem(at: legacy)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: false)
        let oldHelper = legacy.appending(path: "az-ampere-smc")
        try FileManager.default.createSymbolicLink(at: oldHelper, withDestinationURL: target)
        XCTAssertTrue(HelperSecurity.removeFileWithoutFollowingDirectories(at: oldHelper.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldHelper.path))

        try Data("old".utf8).write(to: oldHelper)
        XCTAssertTrue(HelperSecurity.removeFileWithoutFollowingDirectories(at: oldHelper.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldHelper.path))
        XCTAssertTrue(HelperSecurity.removeFileWithoutFollowingDirectories(at: oldHelper.path), "Already absent")
        XCTAssertFalse(HelperSecurity.removeFileWithoutFollowingDirectories(at: legacy.path), "Never remove directories")
    }
}
