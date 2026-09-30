import XCTest
@testable import Ampere

/// Pins the updater's subprocess reader against a child that fills one
/// pipe before touching the other. Draining the pipes one after the other
/// deadlocks there: the child blocks on a full stderr while the parent
/// waits for stdout to close, and the install stays at "Installing…".
final class RunProcessTests: XCTestCase {

    func testAChildThatFillsStderrBeforeWritingStdoutStillCompletes() {
        // Well past the 64 KB pipe buffer, all on stderr, before stdout sees a byte.
        let script = "/usr/bin/yes | /usr/bin/head -c 200000 1>&2; /bin/echo done"
        var result: (status: Int32, stdout: Data, stderr: Data)?
        let returned = expectation(description: "runProcess returned")
        DispatchQueue.global().async {
            result = BatteryMonitor.runProcess("/bin/sh", ["-c", script])
            returned.fulfill()
        }
        wait(for: [returned], timeout: 5)
        XCTAssertEqual(result?.status, 0)
        XCTAssertEqual(result.map { String(decoding: $0.stdout, as: UTF8.self) }, "done\n")
        XCTAssertEqual(result?.stderr.count, 200_000)
    }

    func testStderrArrivesWithTheExitStatus() {
        let result = BatteryMonitor.runProcess("/bin/sh", ["-c", "/bin/echo oops 1>&2; exit 3"])
        XCTAssertEqual(result.status, 3)
        XCTAssertEqual(String(decoding: result.stderr, as: UTF8.self), "oops\n")
        XCTAssertTrue(result.stdout.isEmpty)
    }

    func testAMissingToolReportsFailureWithoutOutput() {
        let result = BatteryMonitor.runProcess("/nonexistent/tool", [])
        XCTAssertEqual(result.status, -1)
        XCTAssertTrue(result.stdout.isEmpty)
        XCTAssertTrue(result.stderr.isEmpty)
    }
}
