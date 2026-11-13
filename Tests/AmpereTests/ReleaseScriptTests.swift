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
    /// against a fabricated keychain. Match the closing `)"` at a line end
    /// so quoted pipeline arguments aren't mistaken for the boundary.
    private func identityLookup() throws -> String? {
        let text = try scriptText()
        guard let open = text.range(of: "SIGN_IDENTITY=\"$("),
              let close = text.range(of: ")\"\n", range: open.upperBound..<text.endIndex)
        else { return nil }
        return String(text[open.upperBound..<close.lowerBound])
    }

    /// Runs a bash snippet with `stdin` on its input, returning what it wrote
    /// and how it exited.
    private func bash(_ script: String, stdin: String = "", arguments: [String] = [],
                      directory: URL? = nil) -> (output: String, status: Int32) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", script, "release-test"] + arguments
        task.currentDirectoryURL = directory
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

    func testExistingVersionGuardUsesTheReleaseRepositoryFromAnyWorkingDirectory() throws {
        let fixture = FileManager.default.temporaryDirectory.appending(path: "ampere-release-\(UUID().uuidString)")
        let repo = fixture.appending(path: "repo")
        let elsewhere = fixture.appending(path: "elsewhere")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }

        // Execute only the real preflight. Stop before any signing, build,
        // tag mutation, or publishing; .project.env is an empty fixture.
        let text = try scriptText()
        let boundary = try XCTUnwrap(text.range(of: "# Select the G2 release certificate"))
        let probe = repo.appending(path: "release.sh")
        try (String(text[..<boundary.lowerBound]) + "printf 'guard passed\\n'\n")
            .write(to: probe, atomically: true, encoding: .utf8)
        try Data().write(to: repo.appending(path: ".project.env"))
        let setup = bash("""
            set -eu
            git init -q
            object=$(printf 'fixture' | git hash-object -w --stdin)
            git update-ref refs/tags/v1.2.3 "$object"
            """, directory: repo)
        XCTAssertEqual(setup.status, 0, setup.output)

        let refused = bash("exec /bin/bash \"$@\"", arguments: [probe.path, "1.2.3"], directory: elsewhere)
        XCTAssertNotEqual(refused.status, 0)
        XCTAssertTrue(refused.output.contains("tag v1.2.3 already exists"), refused.output)
        XCTAssertFalse(refused.output.contains("guard passed"))
        let forced = bash("exec /bin/bash \"$@\"", arguments: [probe.path, "1.2.3", "--force"], directory: elsewhere)
        XCTAssertEqual(forced.status, 0, forced.output)
        XCTAssertTrue(forced.output.contains("guard passed"))
    }

    // MARK: - A version origin already holds

    /// The real preflight, everything above the certificate lookup, as a
    /// script of its own: nothing is signed, built, tagged, or published.
    private func preflight() throws -> String {
        let text = try scriptText()
        let boundary = try XCTUnwrap(text.range(of: "# Select the G2 release certificate"))
        return String(text[..<boundary.lowerBound]) + "printf 'guard passed\\n'\n"
    }

    /// The script's own lines from the one that starts with `from` up to
    /// the one that starts with `to`, lifted verbatim so a test can run
    /// them against a fabricated repository.
    private func section(from: String, to: String) throws -> String {
        let text = try scriptText()
        let start = try XCTUnwrap(text.range(of: "\n" + from), "release.sh has no line starting with \(from)")
        let end = try XCTUnwrap(text.range(of: "\n" + to, range: start.upperBound..<text.endIndex),
                                "release.sh has no line starting with \(to) after \(from)")
        return String(text[start.lowerBound..<end.lowerBound])
    }

    /// Git without the developer's own configuration, so a signing setup,
    /// a URL rewrite, or a hook on this Mac cannot change what the fixture
    /// does.
    private static let hermeticGit = """
        export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
        export GIT_AUTHOR_NAME=Release GIT_AUTHOR_EMAIL=release@example.invalid
        export GIT_COMMITTER_NAME=Release GIT_COMMITTER_EMAIL=release@example.invalid

        """

    /// A published version and a release Mac that never fetched its tag: a
    /// bare `remote.git` holding v1.2.3, and `clone`, cloned from it
    /// without tags, one commit ahead, with the preflight as its
    /// release.sh and an empty .project.env. The directory is removed when
    /// the test ends.
    private func publishedVersionFixture() throws -> URL {
        let fixture = FileManager.default.temporaryDirectory.appending(path: "ampere-release-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }
        let setup = bash(Self.hermeticGit + """
            set -eu
            git init -q --bare remote.git
            git init -q source
            git -C source commit -q --allow-empty -m published
            git -C source tag v1.2.3
            git -C source push -q ../remote.git HEAD:refs/heads/master refs/tags/v1.2.3
            git clone -q --no-tags remote.git clone
            git -C clone commit -q --allow-empty -m next
            """, directory: fixture)
        XCTAssertEqual(setup.status, 0, setup.output)
        let clone = fixture.appending(path: "clone")
        try preflight().write(to: clone.appending(path: "release.sh"), atomically: true, encoding: .utf8)
        try Data().write(to: clone.appending(path: ".project.env"))
        let local = bash(Self.hermeticGit + "git rev-parse -q --verify refs/tags/v1.2.3", directory: clone)
        XCTAssertNotEqual(local.status, 0, "The fixture's premise: the clone has no local tag for the published version")
        return fixture
    }

    func testAVersionPublishedOnOriginIsRefusedEvenWithoutALocalTag() throws {
        // The local tag is only this Mac's memory of a release. A clone that
        // never fetched it (git clone --no-tags, a second release Mac, a tag
        // deleted here) has none, and a guard that looks only there waves
        // the published version through to the steps that replace it.
        let fixture = try publishedVersionFixture()
        let clone = fixture.appending(path: "clone")
        let run = { (arguments: [String]) in
            self.bash(Self.hermeticGit + "exec /bin/bash release.sh \"$@\"", arguments: arguments, directory: clone)
        }

        let refused = run(["1.2.3"])
        XCTAssertNotEqual(refused.status, 0, refused.output)
        XCTAssertTrue(refused.output.contains("v1.2.3 is already published on origin"), refused.output)
        XCTAssertFalse(refused.output.contains("guard passed"), refused.output)

        let forced = run(["1.2.3", "--force"])
        XCTAssertEqual(forced.status, 0, forced.output)
        XCTAssertTrue(forced.output.contains("guard passed"), forced.output)

        let unpublished = run(["1.2.4"])
        XCTAssertEqual(unpublished.status, 0, unpublished.output)
        XCTAssertTrue(unpublished.output.contains("guard passed"), unpublished.output)
    }

    func testAnOriginThatCannotBeAskedIsNotTakenForAnUnpublishedVersion() throws {
        // No answer is not "no such tag": offline, or with origin gone, the
        // version may well be published, so the preflight refuses rather
        // than guess. --force is the explicit choice and asks nothing.
        let fixture = try publishedVersionFixture()
        let clone = fixture.appending(path: "clone")
        let moved = bash("mv remote.git elsewhere.git", directory: fixture)
        XCTAssertEqual(moved.status, 0, moved.output)
        let run = { (arguments: [String]) in
            self.bash(Self.hermeticGit + "exec /bin/bash release.sh \"$@\"", arguments: arguments, directory: clone)
        }

        let refused = run(["1.2.4"])
        XCTAssertNotEqual(refused.status, 0, refused.output)
        XCTAssertTrue(refused.output.contains("could not ask origin"), refused.output)
        XCTAssertFalse(refused.output.contains("guard passed"), refused.output)

        let forced = run(["1.2.4", "--force"])
        XCTAssertEqual(forced.status, 0, forced.output)
        XCTAssertTrue(forced.output.contains("guard passed"), forced.output)
    }

    /// Runs lifted lines of release.sh in the fixture's clone with the
    /// variables the script would have set by then and a `gh` that only
    /// records what it was asked. Returns the snippet's result and gh's log.
    private func runLifted(_ lines: String, version: String, force: Bool,
                           in fixture: URL) throws -> (output: String, status: Int32, gh: [String]) {
        let bin = fixture.appending(path: "bin")
        let log = fixture.appending(path: "gh-\(UUID().uuidString).log")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        // One line per invocation: the release notes span several.
        try "#!/bin/bash\nasked=\"$*\"\nprintf '%s\\n' \"${asked//$'\\n'/ }\" >> \"$GH_LOG\"\n"
            .write(to: bin.appending(path: "gh"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appending(path: "gh").path)
        let clone = fixture.appending(path: "clone")
        let result = bash(Self.hermeticGit + """
            set -euo pipefail
            export PATH="$1:$PATH" GH_LOG="$2"
            VERSION="$3"
            FORCE="$4"
            REPO_DIR="$PWD"
            GITHUB_REPO=example/ampere
            SCHEME=Ampere
            DMG_PATH=/tmp/Ampere.dmg
            SHA256=0000
            \(lines)
            """, arguments: [bin.path, log.path, version, force ? "--force" : ""], directory: clone)
        let recorded = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        return (result.output, result.status, recorded.split(separator: "\n").map(String.init))
    }

    private func tagCommit(_ tag: String, in repository: URL) -> String {
        bash(Self.hermeticGit + "git rev-parse -q --verify \"refs/tags/$1^{commit}\"", arguments: [tag],
             directory: repository).output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testOnlyForceReplacesATagOrAReleaseOriginAlreadyHolds() throws {
        // The preflight is the early refusal; these are the steps that do
        // the replacing, and a version can be published between the two (the
        // build and three notarization rounds sit in the gap). Without
        // --force they must be the plain commands, which origin and GitHub
        // refuse for a version they already hold, not the forced ones.
        let fixture = try publishedVersionFixture()
        let clone = fixture.appending(path: "clone")
        let remote = fixture.appending(path: "remote.git")
        let tagging = try section(from: "echo \"==> Tagging v$VERSION...\"", to: "echo \"==> Building Release...\"")
        let publishing = try section(from: "echo \"==> Pushing tag...\"", to: "echo \"==> Updating Homebrew cask...\"")
        let published = tagCommit("v1.2.3", in: remote)
        let head = bash(Self.hermeticGit + "git rev-parse HEAD", directory: clone).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(published.count, 40)
        XCTAssertNotEqual(published, head)

        // The clone has no local tag, so tagging succeeds and names HEAD.
        let tagged = try runLifted(tagging, version: "1.2.3", force: false, in: fixture)
        XCTAssertEqual(tagged.status, 0, tagged.output)
        XCTAssertEqual(tagCommit("v1.2.3", in: clone), head)

        let plain = try runLifted(publishing, version: "1.2.3", force: false, in: fixture)
        XCTAssertNotEqual(plain.status, 0, "A plain push of a tag origin holds for another commit is rejected: \(plain.output)")
        XCTAssertEqual(tagCommit("v1.2.3", in: remote), published, "The published tag must not move without --force")
        XCTAssertEqual(plain.gh, [], "Nothing is deleted or created once the push is refused")

        // A local tag that exists is not moved without --force either.
        let fetched = bash(Self.hermeticGit + "git tag -f v1.2.3 \"$1\"", arguments: [published], directory: clone)
        XCTAssertEqual(fetched.status, 0, fetched.output)
        let retagged = try runLifted(tagging, version: "1.2.3", force: false, in: fixture)
        XCTAssertNotEqual(retagged.status, 0, retagged.output)
        XCTAssertEqual(tagCommit("v1.2.3", in: clone), published)

        // --force is the deliberate re-release: the tag moves here and on
        // origin, and the old GitHub release goes before the new one.
        let forcedTag = try runLifted(tagging, version: "1.2.3", force: true, in: fixture)
        XCTAssertEqual(forcedTag.status, 0, forcedTag.output)
        XCTAssertEqual(tagCommit("v1.2.3", in: clone), head)
        let forced = try runLifted(publishing, version: "1.2.3", force: true, in: fixture)
        XCTAssertEqual(forced.status, 0, forced.output)
        XCTAssertEqual(tagCommit("v1.2.3", in: remote), head)
        XCTAssertEqual(forced.gh.count, 2, "\(forced.gh)")
        XCTAssertTrue(forced.gh.first?.hasPrefix("release delete v1.2.3 ") == true, "\(forced.gh)")
        XCTAssertTrue(forced.gh.last?.hasPrefix("release create v1.2.3 ") == true, "\(forced.gh)")

        // A version origin has never seen needs no force and deletes nothing.
        let fresh = try runLifted(tagging + "\n" + publishing, version: "1.2.4", force: false, in: fixture)
        XCTAssertEqual(fresh.status, 0, fresh.output)
        XCTAssertEqual(tagCommit("v1.2.4", in: remote), head)
        XCTAssertEqual(fresh.gh.count, 1, "\(fresh.gh)")
        XCTAssertTrue(fresh.gh.first?.hasPrefix("release create v1.2.4 ") == true, "\(fresh.gh)")
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
        let configuration = try String(contentsOf: Self.repoRoot.appending(path: ".project.env"), encoding: .utf8)
        let configured = bash("set -eu\n\(configuration)\nprintf '%s' \"$SIGNING_CERT_FINGERPRINT\"")
        XCTAssertEqual(configured.status, 0)
        let fingerprint = configured.output
        XCTAssertEqual(fingerprint.count, 40)
        XCTAssertTrue(lookup.contains("security find-identity -v -p codesigning"),
                      "the identity comes from somewhere else now: \(lookup)")

        let pipeline = lookup.replacingOccurrences(of: "security find-identity -v -p codesigning",
                                                   with: "cat")
        let lookUp = { (keychain: [String]) in
            self.bash("""
                set -euo pipefail
                \(configuration)
                SIGN_IDENTITY="$(\(pipeline))"
                printf '%s' "$SIGN_IDENTITY"
                """,
                      stdin: (keychain + [""]).joined(separator: "\n"))
        }

        let development = "  1) \(fingerprint) \"Apple Development: Qian Chen (H7TH8723VJ)\""
        let oldDeveloperID = #"  2) E68E6EE9BF85B8F33EB4DCFCC04A6ADDE706302C "Developer ID Application: Qian Chen (H7TH8723VJ)""#
        let developerID = "  3) \(fingerprint) \"Developer ID Application: Qian Chen (H7TH8723VJ)\""
        let otherTeam = "  4) \(fingerprint) \"Developer ID Application: Qian Chen (ZZZZZZZZZZ)\""

        // Old and new certificates share a name. Always return the new
        // fingerprint, regardless of ordering or duplicate keychain entries.
        for keychain in [[development, oldDeveloperID, developerID],
                         [developerID, oldDeveloperID], [developerID, developerID]] {
            let found = lookUp(keychain)
            XCTAssertEqual(found.status, 0)
            XCTAssertEqual(found.output, fingerprint,
                           "the lookup must select only the pinned G2 certificate: \(found.output)")
        }

        for keychain in [[oldDeveloperID], [development], [development, otherTeam], []] {
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

    func testTheBundleDeclaresTheSameOldestMacOSTheBinaryIsBuiltFor() throws {
        // The oldest macOS the app can open on is stated three times: the
        // deployment target in Package.swift (what the binary itself
        // enforces), and LSMinimumSystemVersion and the asset catalog target
        // here. The self-updater reads only LSMinimumSystemVersion before it
        // swaps a new bundle in, so a plist that says less than the binary
        // demands would let it install an app that cannot launch.
        let manifest = try String(contentsOf: Self.repoRoot.appending(path: "Package.swift"), encoding: .utf8)
        let script = try scriptText()
        func capture(_ pattern: String, in text: String) throws -> String {
            let regex = try NSRegularExpression(pattern: pattern)
            let match = try XCTUnwrap(regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                                      "nothing matches \(pattern)")
            return String(text[try XCTUnwrap(Range(match.range(at: 1), in: text))])
        }
        // `.macOS(.v14)` or `.macOS("15.0")`.
        let target = try capture(#"\.macOS\(\s*(?:\.v|")([0-9.]+)"?\s*\)"#, in: manifest)
        let major = try XCTUnwrap(target.split(separator: ".").first.map(String.init))
        let plist = try capture(#"<key>LSMinimumSystemVersion</key>\s*<string>([0-9.]+)</string>"#, in: script)
        let assets = try capture(#"--minimum-deployment-target\s+([0-9.]+)"#, in: script)
        let expected = target.contains(".") ? target : "\(major).0"
        XCTAssertEqual(plist, expected, "LSMinimumSystemVersion and the Package.swift deployment target disagree")
        XCTAssertEqual(assets, expected, "the asset catalog target and the Package.swift deployment target disagree")
    }
}
