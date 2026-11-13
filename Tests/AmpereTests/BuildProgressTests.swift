import XCTest

/// `build-progress.sh` decides what a build leaves on screen in `run.sh` and
/// `release.sh`. The Swift Build engine's progress lines ("[108 / 109]
/// Ampere-product") are a snapshot: the engine sends at most one every
/// 100 ms and never sends the final state again, so the last one printed
/// can stop short of its own total with "Build complete!" under it. The
/// filter shows them while the build runs and leaves none behind.
final class BuildProgressTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // AmpereTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo

    private static let filter = repoRoot.appending(path: "build-progress.sh").path

    /// The engine pads the slash of its fractions with thin spaces.
    private static let thin = "\u{2009}"

    /// What a build prints when its output is piped: one line per progress
    /// update, with a diagnostic (and the footnote the compiler adds, which
    /// starts with a bracket too) in between.
    private static let build = [
        "Building for debugging...",
        "[Pre-planning 1\(thin)/\(thin)95]",
        "[Planning deferred tasks]",
        "[29\(thin)/\(thin)51] Shared",
        "/x/File.swift:1:1: warning: value was never used",
        "[#NoUsage]: <https://docs.swift.org/compiler/documentation/diagnostics/no-usage>",
        "[108\(thin)/\(thin)109] Ampere-product",
        "Build complete! (9.09 sec)",
    ]

    private static let progressLines: Set<String> = [build[1], build[2], build[3], build[6]]

    /// A progress line as the filter draws it: plain spaces for the thin
    /// ones, so a cut to the terminal's width counts the same in any locale.
    private static func drawn(_ index: Int) -> String {
        build[index].replacingOccurrences(of: thin, with: " ")
    }

    /// Runs `executable`, returning everything it wrote and how it exited.
    private func run(_ executable: String, _ arguments: [String],
                     environment: [String: String]? = nil) -> (output: String, status: Int32) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        if let environment { task.environment = environment }
        let output = Pipe()
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = output
        task.standardError = output
        do { try task.run() } catch { return ("\(error)", -1) }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), task.terminationStatus)
    }

    /// The build's lines in a file the filter can read: under `script` its
    /// input is the pseudo-terminal, so a pipe is not available there.
    private func buildLog() throws -> String {
        let file = FileManager.default.temporaryDirectory.appending(path: "ampere-build-\(UUID().uuidString).log")
        try (Self.build.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        return file.path
    }

    /// Runs the filter over the build's lines on a pseudo-terminal `columns`
    /// wide and returns the bytes it sent there, from the build's first
    /// line on. `script` echoes the end of its own input ("^D" and two
    /// backspaces) wherever that lands; it is not the filter's.
    private func onATerminal(columns: Int) throws -> (output: String, status: Int32) {
        let result = run("/usr/bin/script", [
            "-q", "/dev/null", "/bin/bash", "-c",
            "set -euo pipefail; stty cols \"$3\"; source \"$1\"; build_progress < \"$2\"",
            "build-progress-test", Self.filter, try buildLog(), String(columns),
        ], environment: ["TERM": "xterm", "PATH": "/usr/bin:/bin"])
        let output = result.output.replacingOccurrences(of: "^D\u{8}\u{8}", with: "")
        return (output, result.status)
    }

    func testWithoutATerminalTheProgressLinesAreLeftOutAndTheRestIsUntouched() throws {
        let result = run("/bin/bash", ["-c", "set -euo pipefail; source \"$1\"; build_progress < \"$2\"",
                                       "build-progress-test", Self.filter, try buildLog()])
        XCTAssertEqual(result.status, 0, result.output)
        let kept = Self.build.filter { !Self.progressLines.contains($0) }
        XCTAssertEqual(result.output, kept.joined(separator: "\n") + "\n")
    }

    /// On a terminal each progress line replaces the one before it, the
    /// row is cleared before anything else is printed, and it is cleared
    /// once more at the end: the count the build stopped on ("108 / 109")
    /// is not what stays above "Build complete!".
    func testOnATerminalProgressIsDrawnInPlaceAndNoneOfItRemains() throws {
        let result = try onATerminal(columns: 80)
        XCTAssertEqual(result.status, 0, result.output)
        let clear = "\r\u{1B}[2K"
        let expected = Self.build[0] + "\r\n"
            + clear + Self.drawn(1) + clear + Self.drawn(2) + clear + Self.drawn(3)
            + clear + Self.build[4] + "\r\n"
            + Self.build[5] + "\r\n"
            + clear + Self.drawn(6)
            + clear + Self.build[7] + "\r\n"
        XCTAssertEqual(result.output, expected)
    }

    /// A progress line wider than the terminal would wrap, and only its
    /// last row could be cleared: it is cut to fit on one.
    func testOnANarrowTerminalAProgressLineStaysOnOneRow() throws {
        let result = try onATerminal(columns: 20)
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("\r\u{1B}[2K" + String(Self.drawn(6).prefix(19)) + "\r\u{1B}[2K"),
                      result.output)
        XCTAssertFalse(result.output.contains(Self.drawn(6)), "The whole line would have wrapped")
        XCTAssertTrue(result.output.contains(Self.build[4] + "\r\n"), "Only progress lines are cut")
    }

    /// The scripts run `swift build ... | build_progress && <next step>`:
    /// a build that fails must still fail the pipeline, with its errors
    /// shown and nothing after it run.
    func testAFailedBuildStillFailsThePipeline() {
        let result = run("/bin/bash", ["-c", """
            set -euo pipefail
            source "$1"
            (echo "[1 / 2] Ampere"; echo "error: no such module"; exit 3) 2>&1 | build_progress && echo launched
            """, "build-progress-test", Self.filter])
        XCTAssertEqual(result.status, 3)
        XCTAssertEqual(result.output, "error: no such module\n")
    }

    /// Every build the two scripts run goes through the filter, and a
    /// test run never builds on its own (its build output would be shown
    /// as it comes, and its test output must not go through the filter).
    func testTheScriptsRouteEveryBuildThroughTheFilter() throws {
        for name in ["run.sh", "release.sh"] {
            let text = try String(contentsOf: Self.repoRoot.appending(path: name), encoding: .utf8)
            let commands = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("#") }
            XCTAssertTrue(commands.contains("set -euo pipefail"), "\(name): a failed build must stop the script")
            XCTAssertTrue(commands.contains { $0.hasPrefix("source ") && $0.contains("build-progress.sh") },
                          "\(name) no longer loads build-progress.sh")
            let builds = commands.filter { $0.hasPrefix("swift build") }
            XCTAssertFalse(builds.isEmpty, "\(name) has no swift build line: it is not being read")
            for build in builds {
                XCTAssertTrue(build.contains("2>&1 | build_progress"), "\(name): unfiltered build: \(build)")
            }
            for test in commands.filter({ $0.hasPrefix("swift test") }) {
                XCTAssertTrue(test.contains("--skip-build"), "\(name): this test run builds on its own: \(test)")
            }
        }
    }
}
