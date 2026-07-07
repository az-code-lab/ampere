import XCTest
@testable import Ampere

/// Pins `BatteryMonitor.parseCask`. The self-updater downloads and installs
/// whatever this returns, so a partial or ambiguous parse must fail closed
/// (nil) rather than guess.
final class CaskParseTests: XCTestCase {

    private let goodSHA = String(repeating: "ab", count: 32)

    /// Mirrors the real Casks/ampere.rb shape.
    private func cask(version: String = "0.0.47",
                      sha: String? = nil,
                      url: String? = "https://github.com/az-code-lab/ampere/releases/download/v#{version}/Ampere.dmg") -> String {
        """
        cask "ampere" do
          version "\(version)"
          sha256 "\(sha ?? goodSHA)"

          \(url.map { "url \"\($0)\"" } ?? "")
          name "Ampere"
          desc "Menu bar app for monitoring battery status and controlling charging"
          homepage "https://github.com/az-code-lab/ampere"

          depends_on macos: :sonoma

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
