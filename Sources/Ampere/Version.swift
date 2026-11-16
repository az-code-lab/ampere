import Foundation

enum AppVersion {
    /// Version string injected by release.sh, or read from git tag at dev time.
    static let current: String = {
        // Release builds: version.txt is in the app bundle's Resources
        let mainBinary = Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments[0]
        let contentsDir = ((mainBinary as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        let versionFile = (contentsDir as NSString).appendingPathComponent("Resources/version.txt")
        if let version = try? String(contentsOfFile: versionFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !version.isEmpty {
            return version
        }
        // Dev builds: try git describe
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.arguments = ["describe", "--tags", "--always"]
        let pipe = Pipe()
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            // git's answer is read to its end, which is when git is done.
            // Not waitUntilExit(): that runs the main run loop while it
            // waits, and the first use of this value is usually a view's
            // body (the panel's title). SwiftUI, run from that loop,
            // evaluated the body again, which came back here and waited for
            // this same initializer to finish, for good: a dev build could
            // hang as its panel first opened (caught under test, 2026-11-15).
            // Release builds never get here; they read version.txt above.
            if let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty {
                // return "0.0.1" // test upgrade
                return output
            }
        } catch {
            // git unavailable or failed to launch — fall through to "dev"
        }
        return "dev"
    }()
}

enum SystemVersion {
    /// The macOS version this Mac runs, written the way `sw_vers
    /// -productVersion` prints it.
    static let current = string(ProcessInfo.processInfo.operatingSystemVersion)

    /// "27.0" or "26.7.1": major and minor always, the patch only when it is
    /// not zero. Internal (not private) so the format can be pinned by tests.
    static func string(_ version: OperatingSystemVersion) -> String {
        let base = "\(version.majorVersion).\(version.minorVersion)"
        return version.patchVersion == 0 ? base : "\(base).\(version.patchVersion)"
    }
}
