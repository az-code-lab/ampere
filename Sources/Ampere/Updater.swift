import Foundation
import AppKit
import CryptoKit

/// A newer release advertised by the Homebrew cask: the version plus
/// everything needed to fetch and verify its DMG.
struct AvailableUpdate: Equatable {
    let version: String
    let dmgURL: URL
    /// Lowercased hex SHA-256 of the DMG, as published in the cask.
    let sha256: String
}

/// Lifecycle of a click-to-update install. `failed` keeps the update button
/// visible so the user can retry (or fall back to `brew upgrade`).
enum UpdateState: Equatable {
    case idle
    case downloading(Double)  // fraction 0...1
    case installing
    case failed(String)
}

private struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Self-Update

extension BatteryMonitor {

    /// Parse the Homebrew cask source for everything the self-updater needs.
    /// Returns nil unless all three fields are present and well-formed — a
    /// partially-parsed cask must never drive an install.
    /// Internal (not private) so the parsing rules can be pinned by tests.
    static func parseCask(_ content: String) -> AvailableUpdate? {
        guard let version = firstCapture(#"\bversion\s+"([^"]+)""#, in: content),
              let sha = firstCapture(#"\bsha256\s+"([0-9a-fA-F]{64})""#, in: content),
              let urlTemplate = firstCapture(#"\burl\s+"([^"]+)""#, in: content)
        else { return nil }
        let urlString = urlTemplate.replacingOccurrences(of: "#{version}", with: version)
        guard let url = URL(string: urlString), url.scheme == "https" else { return nil }
        return AvailableUpdate(version: version, dmgURL: url, sha256: sha.lowercased())
    }

    /// Download the advertised DMG, verify it (SHA-256 from the cask, code
    /// signature, Team ID matching the running app), swap the app bundle in
    /// place, and relaunch. The relaunch goes through `NSApp.terminate`, i.e.
    /// the same quit path as a normal exit: SMC overrides are restored on the
    /// way down, and the relaunched copy restores persisted state.
    func installUpdate() {
        switch updateState {
        case .downloading, .installing: return  // already running
        case .idle, .failed: break
        }
        guard let update = updateAvailable else { return }
        let appBundleURL = Bundle.main.bundleURL
        // Dev builds (`swift build` bare executable) have no bundle to swap.
        // Unreachable in practice: their version string is a git hash, which
        // isNewerVersion rejects, so updateAvailable is never set.
        guard appBundleURL.pathExtension == "app" else {
            updateState = .failed("Not running from an app bundle")
            return
        }

        updateState = .downloading(0)
        NSLog("Ampere: Update %@ — downloading %@", update.version, update.dmgURL.absoluteString)
        let task = URLSession.shared.downloadTask(with: update.dmgURL) { [weak self] tempURL, response, error in
            guard let self else { return }
            // URLSession deletes tempURL when this handler returns — claim
            // the file synchronously, then do the slow verify/install work
            // off the session's queue.
            do {
                if let error { throw error }
                if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
                    throw UpdateError("Download failed (HTTP \(http.statusCode))")
                }
                guard let tempURL else { throw UpdateError("Download produced no file") }
                let fm = FileManager.default
                let workDir = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("ampere-update-\(ProcessInfo.processInfo.processIdentifier)")
                try? fm.removeItem(at: workDir)
                try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
                let dmgURL = workDir.appendingPathComponent("Ampere.dmg")
                try fm.moveItem(at: tempURL, to: dmgURL)
                DispatchQueue.main.async { self.updateState = .installing }
                DispatchQueue.global(qos: .userInitiated).async {
                    self.verifyAndInstall(update: update, dmgURL: dmgURL, workDir: workDir,
                                          appBundleURL: appBundleURL)
                }
            } catch {
                self.failUpdate(error)
            }
        }
        updateProgressObservation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            DispatchQueue.main.async {
                // The `case .downloading` guard also keeps a late KVO event
                // from clobbering .installing/.failed. Quantize to whole
                // percents: raw KVO fires per received chunk, and every
                // updateState write fans out through objectWillChange to the
                // menu bar icon and a SwiftUI diff.
                guard let self, case .downloading(let previous) = self.updateState,
                      Int(fraction * 100) != Int(previous * 100) else { return }
                self.updateState = .downloading(fraction)
            }
        }
        updateDownloadTask = task
        task.resume()
    }

    private func failUpdate(_ error: Error) {
        let message = (error as? UpdateError)?.message ?? error.localizedDescription
        NSLog("Ampere: Update failed: %@", message)
        DispatchQueue.main.async { self.updateState = .failed(message) }
    }

    /// Blocking verify + install, run on a background queue.
    private func verifyAndInstall(update: AvailableUpdate, dmgURL: URL, workDir: URL, appBundleURL: URL) {
        let fm = FileManager.default
        // Declared before the mount so LIFO defer order detaches the DMG
        // before deleting the directory that contains it.
        defer { try? fm.removeItem(at: workDir) }
        do {
            // 1. The DMG must be byte-identical to what release.sh published
            //    to the cask.
            let digest = try Self.sha256OfFile(at: dmgURL)
            guard digest == update.sha256 else {
                throw UpdateError("Checksum mismatch — download doesn't match the published release")
            }

            // 2. Mount and locate the new bundle.
            let mountPoint = try Self.attachDMG(at: dmgURL)
            defer { Self.detachDMG(mountPoint) }
            let newApp = try Self.locateApp(named: appBundleURL.lastPathComponent, in: mountPoint)

            // 3. The new bundle must carry an intact signature from the same
            //    team as the running app.
            try Self.verifyCodeSignature(newApp: newApp, currentApp: appBundleURL)

            // 4. Stage a copy next to the destination (same volume, so the
            //    swap below is two atomic renames), then swap. The running
            //    executable's inode stays alive unlinked-but-open, so
            //    removing the old bundle is safe.
            let appName = appBundleURL.lastPathComponent
            let destDir = appBundleURL.deletingLastPathComponent()
            let staged = destDir.appendingPathComponent(".\(appName).update-staged")
            let old = destDir.appendingPathComponent(".\(appName).update-old")
            try? fm.removeItem(at: staged)
            try? fm.removeItem(at: old)
            // ditto preserves signatures, xattrs, and permissions exactly.
            try Self.runChecked("/usr/bin/ditto", [newApp.path, staged.path],
                                failure: "Couldn't stage the new version in \(destDir.path)")
            try fm.moveItem(at: appBundleURL, to: old)
            do {
                try fm.moveItem(at: staged, to: appBundleURL)
            } catch {
                try? fm.moveItem(at: old, to: appBundleURL)  // roll back
                throw error
            }
            try? fm.removeItem(at: old)
            // The bundle is verified; strip any quarantine flag so the
            // relaunch doesn't stall on a Gatekeeper first-open dialog.
            _ = Self.runProcess("/usr/bin/xattr", ["-dr", "com.apple.quarantine", appBundleURL.path])

            // 5. Hand off to a detached shell that waits for this process to
            //    exit, then opens the new copy.
            try Self.spawnRelauncher(appPath: appBundleURL.path)
            NSLog("Ampere: Update %@ installed — relaunching", update.version)
            DispatchQueue.main.async { NSApp.terminate(nil) }
        } catch {
            failUpdate(error)
        }
    }

    // MARK: Helpers

    /// Stream-hash a file (the DMG is small today, but don't assume).
    private static func sha256OfFile(at url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw UpdateError("Couldn't read the downloaded file")
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = autoreleasepool { handle.readData(ofLength: 1 << 20) }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func attachDMG(at dmgURL: URL) throws -> URL {
        let result = runProcess("/usr/bin/hdiutil", ["attach", dmgURL.path, "-nobrowse", "-readonly", "-plist"])
        guard result.status == 0 else {
            throw UpdateError("Couldn't mount the update image")
        }
        guard let plist = try? PropertyListSerialization.propertyList(from: result.stdout, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let mountPoint = entities.compactMap({ $0["mount-point"] as? String }).first
        else {
            throw UpdateError("Couldn't locate the mounted update volume")
        }
        return URL(fileURLWithPath: mountPoint)
    }

    private static func detachDMG(_ mountPoint: URL) {
        // A just-finished copy can leave the volume transiently busy.
        let result = runProcess("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet"])
        if result.status != 0 {
            _ = runProcess("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force", "-quiet"])
        }
    }

    private static func locateApp(named name: String, in mountPoint: URL) throws -> URL {
        let exact = mountPoint.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: exact.path) { return exact }
        // Fall back to any .app in the image, in case the bundle is renamed.
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: mountPoint.path)) ?? []
        if let anyApp = contents.first(where: { $0.hasSuffix(".app") }) {
            return mountPoint.appendingPathComponent(anyApp)
        }
        throw UpdateError("No app found in the update image")
    }

    private static func verifyCodeSignature(newApp: URL, currentApp: URL) throws {
        try runChecked("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path],
                       failure: "New version failed code-signature verification")
        let newTeam = try teamIdentifier(of: newApp)
        let currentTeam = try teamIdentifier(of: currentApp)
        guard newTeam == currentTeam else {
            throw UpdateError("New version is signed by a different team (\(newTeam), expected \(currentTeam))")
        }
    }

    /// Team ID from `codesign -dvv` (written to stderr). Ad-hoc and unsigned
    /// binaries report `TeamIdentifier=not set`, which the uppercase-only
    /// capture below deliberately fails to match.
    private static func teamIdentifier(of bundle: URL) throws -> String {
        let result = runProcess("/usr/bin/codesign", ["-dvv", bundle.path])
        guard result.status == 0 else {
            throw UpdateError("\(bundle.lastPathComponent) has no readable code signature")
        }
        let text = String(decoding: result.stderr, as: UTF8.self)
        guard let team = firstCapture(#"TeamIdentifier=([A-Z0-9]{10})"#, in: text) else {
            throw UpdateError("\(bundle.lastPathComponent) has no Team ID (unsigned or ad-hoc)")
        }
        return team
    }

    /// Wait for our PID to exit (including the ≤6s SMC restore in the
    /// willTerminate observer), give the process table a beat to settle so
    /// the single-instance check in main.swift can't see a ghost of the old
    /// copy, then open the new one. The shell survives our exit — children
    /// are reparented to launchd, not killed.
    private static func spawnRelauncher(appPath: String) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let quoted = appPath.replacingOccurrences(of: "'", with: "'\\''")
        let script = "while kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /bin/sleep 0.3; /usr/bin/open '\(quoted)'"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script]
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run()
    }

    /// Run a tool to completion, capturing output. Reads both pipes to EOF
    /// before waiting so a full pipe buffer can't deadlock the child.
    @discardableResult
    private static func runProcess(_ launchPath: String, _ arguments: [String]) -> (status: Int32, stdout: Data, stderr: Data) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = arguments
        task.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        do {
            try task.run()
        } catch {
            return (-1, Data(), Data())
        }
        let stdout = outPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = errPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus, stdout, stderr)
    }

    private static func runChecked(_ launchPath: String, _ arguments: [String], failure: String) throws {
        let result = runProcess(launchPath, arguments)
        guard result.status == 0 else {
            let detail = String(decoding: result.stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpdateError(detail.isEmpty ? failure : "\(failure): \(detail)")
        }
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }
}
