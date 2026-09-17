import XCTest
@testable import Ampere

/// Pins `BatteryMonitor.parseCask`. The self-updater downloads and installs
/// whatever this returns, so a partial or ambiguous parse must fail closed
/// (nil) rather than guess. The one field read leniently is the minimum
/// macOS: a line that cannot be read means "no known minimum", because the
/// downloaded bundle's own minimum still decides before anything is installed
/// (see UpdateMacOSGateTests).
final class CaskParseTests: XCTestCase {

    private let goodSHA = String(repeating: "ab", count: 32)

    /// Mirrors the real Casks/ampere.rb shape.
    private func cask(version: String = "0.0.47",
                      sha: String? = nil,
                      url: String? = "https://github.com/az-code-lab/ampere/releases/download/v#{version}/Ampere.dmg",
                      macos: String? = "depends_on macos: :tahoe") -> String {
        """
        cask "ampere" do
          version "\(version)"
          sha256 "\(sha ?? goodSHA)"

          \(url.map { "url \"\($0)\"" } ?? "")
          name "Ampere"
          desc "Menu bar app for monitoring battery status and controlling charging"
          homepage "https://amperebattery.app/"

          depends_on arch: :arm64
          \(macos ?? "")

          app "Ampere.app"
        end
        """
    }

    func testParsesRealCaskShape() {
        let update = BatteryMonitor.parseCask(cask())
        XCTAssertEqual(update?.version, "0.0.47")
        XCTAssertEqual(update?.sha256, goodSHA)
        XCTAssertEqual(update?.dmgURL.absoluteString,
                       "https://github.com/az-code-lab/ampere/releases/download/v0.0.47/Ampere.dmg")
        XCTAssertEqual(update?.minimumMacOS, "26")
    }

    // MARK: Minimum macOS

    func testMinimumMacOS_BareReleaseNameMeansThisOrLater() {
        XCTAssertEqual(BatteryMonitor.parseCask(cask(macos: "depends_on macos: :sonoma"))?.minimumMacOS, "14")
        XCTAssertEqual(BatteryMonitor.parseCask(cask(macos: "depends_on macos: :sequoia"))?.minimumMacOS, "15")
        XCTAssertEqual(BatteryMonitor.parseCask(cask(macos: "depends_on macos: :golden_gate"))?.minimumMacOS, "27")
    }

    func testMinimumMacOS_OlderComparisonSpelling() {
        XCTAssertEqual(BatteryMonitor.parseCask(cask(macos: #"depends_on macos: ">= :tahoe""#))?.minimumMacOS, "26")
    }

    func testMinimumMacOS_TrailingCommentIgnored() {
        XCTAssertEqual(BatteryMonitor.parseCask(cask(macos: "depends_on macos: :tahoe # CHTE or Charge Limit"))?.minimumMacOS, "26")
    }

    func testMinimumMacOS_AbsentLine_Nil() {
        // The arch line alone must not be read as a macOS requirement.
        let update = BatteryMonitor.parseCask(cask(macos: nil))
        XCTAssertNotNil(update)
        XCTAssertNil(update?.minimumMacOS)
    }

    func testMinimumMacOS_NotAMinimum_Nil() {
        // A ceiling or a list says nothing about the oldest macOS allowed.
        XCTAssertNil(BatteryMonitor.parseCask(cask(macos: #"depends_on macos: "<= :tahoe""#))?.minimumMacOS)
        XCTAssertNil(BatteryMonitor.parseCask(cask(macos: "depends_on macos: [:sonoma, :sequoia]"))?.minimumMacOS)
        XCTAssertNil(BatteryMonitor.parseCask(cask(macos: "depends_on maximum_macos: :tahoe"))?.minimumMacOS)
    }

    func testMinimumMacOS_UnknownReleaseName_NilButStillAnUpdate() {
        // A name newer than this build knows may be the very macOS it runs
        // on; refusing would strand that Mac, so the offer stands and the
        // bundle's own minimum decides at install time.
        let update = BatteryMonitor.parseCask(cask(macos: "depends_on macos: :some_future_release"))
        XCTAssertEqual(update?.version, "0.0.47")
        XCTAssertNil(update?.minimumMacOS)
    }

    func testUppercaseShaNormalizedToLowercase() {
        let update = BatteryMonitor.parseCask(cask(sha: String(repeating: "AB", count: 32)))
        XCTAssertEqual(update?.sha256, goodSHA)
    }

    func testLiteralURLWithoutVersionTemplate() {
        let update = BatteryMonitor.parseCask(cask(url: "https://example.com/Ampere.dmg"))
        XCTAssertEqual(update?.dmgURL.absoluteString, "https://example.com/Ampere.dmg")
    }

    func testMissingVersion_Nil() {
        let text = cask().replacingOccurrences(of: #"version "0.0.47""#, with: "")
        XCTAssertNil(BatteryMonitor.parseCask(text))
    }

    func testMissingSha_Nil() {
        let text = cask().replacingOccurrences(of: "sha256 \"\(goodSHA)\"", with: "")
        XCTAssertNil(BatteryMonitor.parseCask(text))
    }

    func testShortSha_Nil() {
        XCTAssertNil(BatteryMonitor.parseCask(cask(sha: String(repeating: "ab", count: 31))))
    }

    func testNonHexSha_Nil() {
        XCTAssertNil(BatteryMonitor.parseCask(cask(sha: String(repeating: "zz", count: 32))))
    }

    func testNoCheckSha_Nil() {
        // Casks can declare `sha256 :no_check`; without a pinned digest the
        // download can't be verified, so no update must be offered.
        let text = cask().replacingOccurrences(of: "sha256 \"\(goodSHA)\"", with: "sha256 :no_check")
        XCTAssertNil(BatteryMonitor.parseCask(text))
    }

    func testMissingURL_Nil() {
        // homepage "https://…" is still present — proves the \burl\b match
        // can't latch onto the homepage field.
        XCTAssertNil(BatteryMonitor.parseCask(cask(url: nil)))
    }

    func testHTTPURL_Nil() {
        XCTAssertNil(BatteryMonitor.parseCask(cask(url: "http://github.com/az-code-lab/ampere/releases/download/v#{version}/Ampere.dmg")))
    }
}
