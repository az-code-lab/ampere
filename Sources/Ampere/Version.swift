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
            task.waitUntilExit()
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
