import XCTest

/// Pins the parts of `release.sh` that decide what a stranger downloads.
///
/// Nothing compiles this file and no other test reads it, so every way it can
/// drift is invisible from here: the release still builds, still uploads, and
/// still installs on the machine that cut it. The two things below fail only
/// on someone else's Mac — an unsigned disk image that answers "no usable
/// signature" to the assessment macOS runs on a quarantined download, and a
/// cask checksum taken before the steps that rewrite the file it names.
final class ReleaseScriptTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // AmpereTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo

    /// The script's logical lines: backslash continuations joined into one,
    /// each carrying the number of the physical line it opens on, comments
    /// dropped. A line joiner, not a shell parser — enough to ask where a
    /// command sits relative to another.
    private func statements() throws -> [(line: Int, text: String)] {
        let text = try String(contentsOf: Self.repoRoot.appending(path: "release.sh"), encoding: .utf8)
        var joined: [(line: Int, text: String)] = []
        var current = ""
        var start = 1
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if current.isEmpty { start = index + 1 }
            current += current.isEmpty ? line : " " + line
            if current.hasSuffix("\\") {
                current = String(current.dropLast())
                continue
            }
            joined.append((start, current))
            current = ""
        }
        if !current.isEmpty { joined.append((start, current)) }
        return joined.filter { !$0.text.hasPrefix("#") }
    }

    private func firstLine(_ predicate: (String) -> Bool) throws -> Int? {
        try statements().first { predicate($0.text) }?.line
    }

    private func scriptText() throws -> String {
        try String(contentsOf: Self.repoRoot.appending(path: "release.sh"), encoding: .utf8)
    }

    /// The keychain lookup the script picks its signing identity with, lifted
    /// out of its `SIGN_IDENTITY="$( … )"` so a test can run the real pipeline
    /// against a fabricated keychain. The closing `)"` is matched at a line
    /// end on purpose: the `sed` inside the substitution holds a `\)"` of its
    /// own, and the first plain `)"` in the text is that one.
    private func identityLookup() throws -> String? {
        let text = try scriptText()
        guard let open = text.range(of: "SIGN_IDENTITY=\"$("),
              let close = text.range(of: ")\"\n", range: open.upperBound..<text.endIndex)
        else { return nil }
        return String(text[open.upperBound..<close.lowerBound])
    }

    /// Runs a bash snippet with `stdin` on its input, returning what it wrote
    /// and how it exited.
    private func bash(_ script: String, stdin: String = "") -> (output: String, status: Int32) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", script]
        let input = Pipe(), output = Pipe()
        task.standardInput = input
        task.standardOutput = output
        task.standardError = output
        do { try task.run() } catch { return ("\(error)", -1) }
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try? input.fileHandleForWriting.close()
        // Read before waiting: output larger than the pipe's buffer would
        // otherwise block the snippet and deadlock the wait.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), task.terminationStatus)
    }

    func testTheScriptIsWhereTheTestThinksItIs() throws {
        // Everything below is a claim about a parse, so a parse that quietly
        // read nothing would turn the rest of this file green.
        let lines = try statements()
        XCTAssertGreaterThan(lines.count, 50, "release.sh parsed to \(lines.count) statements — it is not being read")
        XCTAssertNotNil(try firstLine { $0.hasPrefix("hdiutil create") }, "no hdiutil create found in release.sh")
    }

    func testTheDiskImageIsSignedNotarizedAndStapledItself() throws {
        // The app inside carries its own stapled ticket, and that is what
        // clears a first launch — so an unsigned image still installs, which
        // is why this went unnoticed. What it costs is the image's own answer
        // to `spctl -a -t open`, the assessment macOS runs on a quarantined
        // disk image.
        XCTAssertNotNil(try firstLine { $0.contains("codesign") && $0.contains("$DMG_PATH") },
                        "release.sh no longer signs the DMG — the published image would be unsigned")
        XCTAssertNotNil(try firstLine { $0.contains("notarytool submit") && $0.contains("$DMG_PATH") },
                        "release.sh no longer notarizes the DMG")
        XCTAssertNotNil(try firstLine { $0.contains("stapler staple") && $0.contains("$DMG_PATH") },
                        "release.sh no longer staples the DMG's ticket — the image would need the network to validate")
    }

    func testTheCaskHashIsTakenAfterEverythingThatRewritesTheImage() throws {
        // Signing and stapling both rewrite the file, so a hash taken between
        // `hdiutil create` and either one is the hash of an image nobody can
        // download. The cask would carry it, and `brew install` would refuse
        // the real DMG as a checksum mismatch — for everyone except this
        // machine, which never re-downloads what it just built.
        let created = try XCTUnwrap(firstLine { $0.hasPrefix("hdiutil create") })
        let signed = try XCTUnwrap(firstLine { $0.contains("codesign") && $0.contains("$DMG_PATH") })
        let stapled = try XCTUnwrap(firstLine { $0.contains("stapler staple") && $0.contains("$DMG_PATH") })
        let hashed = try XCTUnwrap(firstLine { $0.hasPrefix("SHA256=") })

        XCTAssertLessThan(created, signed, "the DMG is signed before it is created")
        XCTAssertLessThan(signed, hashed, "the cask's SHA256 is taken before the DMG is signed — it would not match the published file")
        XCTAssertLessThan(stapled, hashed, "the cask's SHA256 is taken before the ticket is stapled — it would not match the published file")
    }

    func testTheAppIsStapledBeforeItIsCopiedIntoTheImage() throws {
        // The ticket has to be on the bundle that goes into the DMG, not on a
        // build-directory copy left behind — a staple after the `cp` ships an
        // app that needs the network to prove it was notarized.
        let stapledApp = try XCTUnwrap(firstLine { $0.contains("stapler staple") && $0.contains("$APP_DIR") })
        let copied = try XCTUnwrap(firstLine { $0.hasPrefix("cp -R \"$APP_DIR\"") })
        XCTAssertLessThan(stapledApp, copied, "the app is copied into the DMG before its ticket is stapled")
    }

    func testTheSigningIdentityIsADeveloperIDAndNotJustTheTeam() throws {
        // An "Apple Development" certificate carries the team id too, so a
        // lookup matching only the team can pick one — and what it signs is
        // rejected by Gatekeeper on every machine that did not build it. The
        // whole release would still succeed here and fail for everyone else.
        //
        // The second half is the reporting: the lookup is a pipeline inside a
        // command substitution, and a grep that matches nothing exits 1. With
        // `set -o pipefail` that fails the substitution, and `set -e` ends the
        // script on the spot — before the message naming the missing
        // certificate can print. So an empty-handed lookup has to come back
        // ALIVE, with nothing found.
        //
        // The real pipeline is lifted out of release.sh and run against a
        // fabricated keychain, with `cat` standing in for the query.
        let lookup = try XCTUnwrap(identityLookup(),
                                   "release.sh no longer looks its signing identity up in the keychain")
        XCTAssertTrue(lookup.contains("security find-identity -v -p codesigning"),
                      "the identity comes from somewhere else now: \(lookup)")

        let pipeline = lookup.replacingOccurrences(of: "security find-identity -v -p codesigning",
                                                   with: "cat")
        let lookUp = { (keychain: [String]) in
            self.bash("""
                set -euo pipefail
                TEAM_ID="H7TH8723VJ"
                SIGN_IDENTITY="$(\(pipeline))"
                printf '%s' "$SIGN_IDENTITY"
                """,
                      stdin: (keychain + [""]).joined(separator: "\n"))
        }

        let development = #"  1) AAAA "Apple Development: Qian Chen (H7TH8723VJ)""#
        let developerID = #"  2) BBBB "Developer ID Application: Qian Chen (H7TH8723VJ)""#
        let secondOne = #"  3) CCCC "Developer ID Application: Release Bot (H7TH8723VJ)""#
        let otherTeam = #"  4) DDDD "Developer ID Application: Qian Chen (ZZZZZZZZZZ)""#

        // The development certificate is listed FIRST, which is what the old
        // `grep "$TEAM_ID" | head -1` would have taken.
        let found = lookUp([development, developerID, secondOne])
        XCTAssertEqual(found.status, 0)
        XCTAssertEqual(found.output, "Developer ID Application: Qian Chen (H7TH8723VJ)",
                       "the lookup picked \"\(found.output)\" — one identity, name only, first match")

        for keychain in [[development], [development, otherTeam], []] {
            let missing = lookUp(keychain)
            XCTAssertEqual(missing.status, 0,
                           "the lookup exited \(missing.status) instead of leaving release.sh to say which certificate is missing")
            XCTAssertTrue(missing.output.isEmpty, "it accepted \"\(missing.output)\"")
        }
    }

    func testAMissingCertificateIsReportedRatherThanSigned() throws {
        // The emptiness test is the only error path the lookup has, so it has
        // to exist and it has to name the certificate.
        let text = try scriptText()
        XCTAssertTrue(text.contains("if [ -z \"$SIGN_IDENTITY\" ]; then"),
                      "release.sh no longer checks that the identity lookup found anything")
        XCTAssertTrue(text.contains("Developer ID Application\\\" certificate for team"),
                      "the missing-certificate message no longer names what to install")
    }
}
