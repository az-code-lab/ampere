import XCTest
@testable import Ampere

/// Pins the in-app updater's bundle swap. The postconditions must hold on
/// BOTH implementations behind `swapIntoPlace` — the atomic
/// renamex_np(RENAME_SWAP) exchange and the two-rename fallback — so the
/// happy-path test is deliberately implementation-blind: same asserts
/// whichever path the volume takes. The failure test deterministically
/// exercises the fallback's rollback (a missing source makes the atomic
/// swap fail, and the fallback's second rename fail after its first
/// succeeded), the one path where the live bundle is transiently absent.
final class SwapIntoPlaceTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ampere-swap-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A stand-in "bundle": a directory holding one marker file whose
    /// content identifies which bundle ended up where.
    private func makeBundle(_ name: String, marker: String) throws -> URL {
        let dir = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try marker.write(to: dir.appendingPathComponent("marker.txt"),
                         atomically: true, encoding: .utf8)
        return dir
    }

    private func marker(of bundle: URL) throws -> String {
        try String(contentsOf: bundle.appendingPathComponent("marker.txt"), encoding: .utf8)
    }

    func testSwap_LivePathHoldsNewBundle_OutgoingAndScratchRemoved() throws {
        let staged = try makeBundle(".App.app.update-staged", marker: "new")
        let live = try makeBundle("App.app", marker: "old")
        let old = root.appendingPathComponent(".App.app.update-old")

        try BatteryMonitor.swapIntoPlace(staged: staged, live: live, old: old)

        XCTAssertEqual(try marker(of: live), "new",
                       "The live path must hold the staged bundle after the swap")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path),
                       "The outgoing bundle must not survive as a hidden copy")
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path),
                       "The scratch path must not survive either")
    }

    func testSwap_MissingStaged_ThrowsAndRollsBackLiveIntact() throws {
        let live = try makeBundle("App.app", marker: "old")
        let staged = root.appendingPathComponent(".App.app.update-staged")  // never created
        let old = root.appendingPathComponent(".App.app.update-old")

        XCTAssertThrowsError(try BatteryMonitor.swapIntoPlace(staged: staged, live: live, old: old))

        XCTAssertEqual(try marker(of: live), "old",
                       "Rollback must leave the live bundle exactly where and what it was")
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path),
                       "Rollback must consume the .update-old rename, not leak it")
    }
}
