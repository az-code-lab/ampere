// Minimal SMC writer — no SwiftUI/AppKit to avoid WindowServer side effects.
// This binary is invoked as root via sudo to set SMC charging keys.

import Foundation
import IOKit
import Shared

// SMCKeyData, SMCCmd command codes, and smcFourCharCode live in the Shared
// module so they can't drift between this binary and the main Ampere app's
// SMC read path.

// MARK: - Minimal SMC access

func smcOpen() -> io_connect_t? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault,
        IOServiceMatching("AppleSMCKeysEndpoint"))
    let svc = service != MACH_PORT_NULL ? service :
        IOServiceGetMatchingService(kIOMainPortDefault,
            IOServiceMatching("AppleSMC"))
    guard svc != MACH_PORT_NULL else { return nil }
    defer { IOObjectRelease(svc) }

    var conn: io_connect_t = 0
    let result = IOServiceOpen(svc, mach_task_self_, 0, &conn)
    guard result == kIOReturnSuccess else { return nil }
    return conn
}

func smcWriteKey(_ conn: io_connect_t, _ key: String, _ bytes: [UInt8]) -> Bool {
    let smcKey = smcFourCharCode(key)
    var inputStruct = SMCKeyData()
    var outputStruct = SMCKeyData()
    inputStruct.key = smcKey
    inputStruct.data8 = SMCCmd.readKeyInfo
    let inputSize = MemoryLayout<SMCKeyData>.size
    var outputSize = MemoryLayout<SMCKeyData>.size

    var result = IOConnectCallStructMethod(conn, SMCCmd.userClientSelector,
        &inputStruct, inputSize, &outputStruct, &outputSize)
    guard result == kIOReturnSuccess else { return false }

    let dataType = outputStruct.keyInfo.dataType
    let dataSize = outputStruct.keyInfo.dataSize
    // Symmetric bounds check with smcReadKey — a malformed dataSize > 32
    // would overrun the bytes tuple in the write loop below.
    guard dataSize > 0, dataSize <= SMCKeyData.bytesCapacity else { return false }

    inputStruct = SMCKeyData()
    outputStruct = SMCKeyData()
    inputStruct.key = smcKey
    inputStruct.keyInfo.dataSize = dataSize
    inputStruct.keyInfo.dataType = dataType
    inputStruct.data8 = SMCCmd.writeBytes

    withUnsafeMutablePointer(to: &inputStruct.bytes) { ptr in
        let raw = UnsafeMutableRawPointer(ptr)
        for (i, byte) in bytes.prefix(Int(dataSize)).enumerated() {
            raw.storeBytes(of: byte, toByteOffset: i, as: UInt8.self)
        }
    }

    outputSize = MemoryLayout<SMCKeyData>.size
    result = IOConnectCallStructMethod(conn, SMCCmd.userClientSelector,
        &inputStruct, inputSize, &outputStruct, &outputSize)
    return result == kIOReturnSuccess
}

func smcReadKey(_ conn: io_connect_t, _ key: String) -> [UInt8]? {
    let smcKey = smcFourCharCode(key)
    let inputSize = MemoryLayout<SMCKeyData>.size
    var outputSize = MemoryLayout<SMCKeyData>.size

    // Get key info
    var input = SMCKeyData()
    var output = SMCKeyData()
    input.key = smcKey
    input.data8 = SMCCmd.readKeyInfo
    guard IOConnectCallStructMethod(conn, SMCCmd.userClientSelector, &input, inputSize, &output, &outputSize) == kIOReturnSuccess else { return nil }

    let dataSize = output.keyInfo.dataSize
    guard dataSize > 0, dataSize <= SMCKeyData.bytesCapacity else { return nil }

    // Read value
    input = SMCKeyData()
    input.key = smcKey
    input.keyInfo.dataSize = dataSize
    input.data8 = SMCCmd.readKey
    output = SMCKeyData()
    outputSize = MemoryLayout<SMCKeyData>.size
    guard IOConnectCallStructMethod(conn, SMCCmd.userClientSelector, &input, inputSize, &output, &outputSize) == kIOReturnSuccess else { return nil }

    var raw = output.bytes
    return withUnsafeBytes(of: &raw) { Array($0.prefix(Int(dataSize))) }
}

// MARK: - Sleep control

/// Read a pmset value by key name (e.g. "sleep", "displaysleep").
func readPmsetValue(_ key: String) -> Int? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    task.arguments = ["-g"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    do {
        try task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        for line in output.components(separatedBy: "\n") {
            // .whitespacesAndNewlines so a stray \r from CRLF-style output
            // doesn't end up attached to the value, making Int() fail.
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix(key) {
                let parts = trimmed.split(separator: " ")
                if parts.count >= 2, parts[0] == Substring(key), let val = Int(parts[1]) {
                    return val
                }
            }
        }
    } catch {}
    return nil
}

/// Convenience: read the current `sleep` value.
func readPmsetSleep() -> Int? { readPmsetValue("sleep") }

/// Marker files storing the pre-override pmset values, checked in order.
/// The primary location is the persistent state dir (survives reboot); the
/// legacy /tmp path is still honored so an upgrade that happens while a
/// marker from an older build is outstanding can restore correctly.
let savedSleepPaths = [AppConstants.savedSleepPath, AppConstants.legacySavedSleepPath]
let savedDisplaySleepPaths = [AppConstants.savedDisplaySleepPath, AppConstants.legacySavedDisplaySleepPath]

func markerExists(_ paths: [String]) -> Bool {
    paths.contains { FileManager.default.fileExists(atPath: $0) }
}

func readMarker(_ paths: [String]) -> String? {
    for path in paths {
        if let value = try? String(contentsOfFile: path, encoding: .utf8) {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    return nil
}

func removeMarkers(_ paths: [String]) {
    for path in paths { try? FileManager.default.removeItem(atPath: path) }
}

/// Write a marker to the primary (persistent) path, creating the root-owned
/// state dir on first use. We run as root, so created files/dirs are
/// root-owned; 0755 keeps them world-readable (the values are just minutes)
/// but root-only writable.
func writeMarker(_ value: Int, to paths: [String]) {
    let primary = paths[0]
    let dir = (primary as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(
        atPath: dir, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o755])
    try? "\(value)".write(toFile: primary, atomically: true, encoding: .utf8)
}

/// Prevent or restore system/clamshell sleep using pmset. Requires root.
@discardableResult
func setDischargeSleepPrevention(enabled: Bool) -> Bool {
    if enabled {
        // Save original values before overriding, but only if not already saved
        // (avoids overwriting with already-overridden values on re-entry)
        if !markerExists(savedSleepPaths), let original = readPmsetSleep() {
            writeMarker(original, to: savedSleepPaths)
        }
        if !markerExists(savedDisplaySleepPaths), let original = readPmsetValue("displaysleep") {
            writeMarker(original, to: savedDisplaySleepPaths)
        }
    }

    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    if enabled {
        // Disable both system sleep and display sleep to prevent clamshell issues
        task.arguments = ["-a", "sleep", "0", "disablesleep", "1", "displaysleep", "0"]
    } else {
        // Restore original values
        // Fallbacks if the saved-original files are missing/unreadable: pick
        // values close to the macOS factory defaults (sleep=10min, displaysleep=10min)
        // rather than 1min, so a wiped save file doesn't strand the user with
        // a Mac that sleeps after 60 seconds.
        // Validate: pmset rejects the *entire* command atomically if any arg
        // is invalid, which would leave disablesleep=1 stuck. Accept only
        // 0–1440 (= up to 24h, well past any sensible user setting).
        func validPmsetMinutes(_ s: String) -> Bool {
            guard let n = Int(s) else { return false }
            return n >= 0 && n <= 1440
        }
        let originalSleep: String
        if let saved = readMarker(savedSleepPaths), !saved.isEmpty, validPmsetMinutes(saved) {
            originalSleep = saved
        } else {
            originalSleep = "10"
        }
        let originalDisplaySleep: String
        if let saved = readMarker(savedDisplaySleepPaths), !saved.isEmpty, validPmsetMinutes(saved) {
            originalDisplaySleep = saved
        } else {
            originalDisplaySleep = "10"
        }
        task.arguments = ["-a", "sleep", originalSleep, "disablesleep", "0", "displaysleep", originalDisplaySleep]
    }
    task.standardInput = FileHandle.nullDevice
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    do {
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            fputs("WARNING: pmset exited with status \(task.terminationStatus)\n", stderr)
            return false
        }
        if !enabled {
            // Markers are consumed only after pmset succeeds — a failed
            // restore keeps the originals in place so the watchdog or a
            // later nodischarge can retry with the real values instead of
            // falling back to the 10/10 defaults. (The previous code also
            // left an *invalid* marker in place forever; now any marker is
            // cleared once a restore has actually landed.)
            removeMarkers(savedSleepPaths)
            removeMarkers(savedDisplaySleepPaths)
        }
        return true
    } catch {
        fputs("WARNING: Failed to run pmset: \(error.localizedDescription)\n", stderr)
        return false
    }
}

// MARK: - Main

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: smc-writer inhibit|allow|discharge:pid|nodischarge|spawn-watchdog:pid|watchdog:pid\n", stderr)
    exit(1)
}

let action = CommandLine.arguments[1]

/// Spawn a detached watchdog daemon that monitors the given app PID.
/// When the app dies, the watchdog clears CHTE, CHIE, and restores sleep.
func spawnWatchdog(appPID: Int32) -> Bool {
    let execPath = CommandLine.arguments[0]
    var spawnPid: pid_t = 0
    var fileActions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&fileActions)
    posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&fileActions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&fileActions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)

    let arg0 = strdup(execPath)!
    let arg1 = strdup("watchdog:\(appPID)")!
    var args: [UnsafeMutablePointer<CChar>?] = [arg0, arg1, nil]
    let result = posix_spawn(&spawnPid, execPath, &fileActions, nil, &args, nil)
    posix_spawn_file_actions_destroy(&fileActions)
    free(arg0)
    free(arg1)

    if result != 0 {
        fputs("WARNING: Failed to spawn watchdog (errno \(result))\n", stderr)
        return false
    }
    return true
}

// "spawn-watchdog:PID" — spawn a watchdog daemon and exit immediately.
if action.hasPrefix("spawn-watchdog:") {
    guard let appPID = Int32(action.dropFirst("spawn-watchdog:".count)) else {
        fputs("ERROR: invalid PID\n", stderr)
        exit(1)
    }
    if !spawnWatchdog(appPID: appPID) {
        // Stderr already logged inside spawnWatchdog.
        exit(2)
    }
    print("OK: watchdog spawned")
    exit(0)
}

// "discharge:PID" — set sleep prevention, write CHIE, spawn watchdog daemon, exit.
if action.hasPrefix("discharge:") {
    guard let appPID = Int32(action.dropFirst("discharge:".count)) else {
        fputs("ERROR: invalid PID in discharge command\n", stderr)
        exit(1)
    }

    guard let conn = smcOpen() else {
        fputs("ERROR: Could not open SMC connection\n", stderr)
        exit(1)
    }

    // Disable sleep BEFORE the CHIE write, since the CHIE write triggers
    // USB-C PD renegotiation that can cause clamshell sleep on lid-closed
    // setups (see "Clamshell Mode and the Black Screen Problem" in README).
    // If pmset fails, refuse to proceed — writing CHIE without the sleep
    // override is the exact failure mode the override exists to prevent.
    guard setDischargeSleepPrevention(enabled: true) else {
        IOServiceClose(conn)
        fputs("ERROR: failed to disable sleep — refusing to write CHIE=0x08 without clamshell-sleep protection\n", stderr)
        exit(4)
    }

    guard smcWriteKey(conn, SMC.keyChargeInhibit, SMC.chieDischarge) else {
        _ = setDischargeSleepPrevention(enabled: false)
        IOServiceClose(conn)
        fputs("ERROR: SMC write failed for CHIE\n", stderr)
        exit(2)
    }
    IOServiceClose(conn)

    // Spawn the watchdog AFTER the SMC write, but roll the discharge back if
    // it fails — running discharge without a crash safety net would leave
    // sleep disabled and CHIE=0x08 stuck on if the app dies.
    if !spawnWatchdog(appPID: appPID) {
        var chieCleared = false
        if let conn = smcOpen() {
            chieCleared = smcWriteKey(conn, SMC.keyChargeInhibit, SMC.chieNormal)
            IOServiceClose(conn)
        }
        if chieCleared {
            // Wait for USB-C PD renegotiation to complete before re-enabling
            // clamshell sleep — same reason as the nodischarge path. Without
            // this, the rollback can itself black out external displays.
            sleep(3)
            _ = setDischargeSleepPrevention(enabled: false)
            fputs("ERROR: watchdog spawn failed — rolled back discharge\n", stderr)
        } else {
            // Could not clear CHIE; leave the sleep override in place. Sleep
            // restored while CHIE=0x08 is active would black out external
            // displays in clamshell mode — that's the failure mode we'd
            // rather avoid even at the cost of leaving the override stuck
            // until the watchdog or a subsequent nodischarge fixes it.
            fputs("ERROR: watchdog spawn failed AND rollback CHIE write failed — discharge state may be stuck\n", stderr)
        }
        exit(3)
    }

    print("OK: active discharge enabled")
    exit(0)
}

// "watchdog:PID" — monitor app PID, clean up CHIE + sleep when app dies.
// Spawned by the discharge command as a detached daemon.
if action.hasPrefix("watchdog:") {
    guard let appPID = Int32(action.dropFirst("watchdog:".count)) else {
        _exit(1)
    }

    // Poll every 2s
    while true {
        sleep(2)
        if kill(appPID, 0) != 0 {
            // App is gone — clean up
            if let conn = smcOpen() {
                _ = smcWriteKey(conn, SMC.keyChargeInhibit, SMC.chieNormal)
                _ = smcWriteKey(conn, SMC.keyChargeTerminate, SMC.chteAllow)
                IOServiceClose(conn)
            }
            // Only restore pmset if a save marker shows we previously
            // overrode it (i.e. discharge was active). If the app died
            // without ever enabling discharge, blindly running pmset would
            // overwrite the user's actual sleep setting with our fallback.
            if markerExists(savedSleepPaths) {
                // Wait for PD renegotiation to settle before restoring sleep
                sleep(3)
                _ = setDischargeSleepPrevention(enabled: false)
            }
            _exit(0)
        }
    }
}

// One-shot commands
let validActions: Set<String> = ["inhibit", "allow", "nodischarge"]
guard validActions.contains(action) else {
    fputs("Usage: smc-writer inhibit|allow|discharge:pid|nodischarge|spawn-watchdog:pid|watchdog:pid\n", stderr)
    exit(1)
}

guard let conn = smcOpen() else {
    fputs("ERROR: Could not open SMC connection\n", stderr)
    exit(1)
}
defer { IOServiceClose(conn) }

switch action {
case "inhibit":
    if smcWriteKey(conn, SMC.keyChargeTerminate, SMC.chteInhibit) {
        print("OK: charging inhibited")
        exit(0)
    } else {
        fputs("ERROR: SMC write failed for CHTE\n", stderr)
        exit(2)
    }

case "allow":
    if smcWriteKey(conn, SMC.keyChargeTerminate, SMC.chteAllow) {
        print("OK: charging allowed")
        exit(0)
    } else {
        fputs("ERROR: SMC write failed for CHTE\n", stderr)
        exit(2)
    }

case "nodischarge":
    // Kill any watchdog processes first (we're already root).
    let killTask = Process()
    killTask.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    killTask.arguments = ["-f", "\(AppConstants.helperPath) watchdog:"]
    killTask.standardInput = FileHandle.nullDevice
    killTask.standardOutput = FileHandle.nullDevice
    killTask.standardError = FileHandle.nullDevice
    // Guard waitUntilExit behind a successful run() — calling
    // waitUntilExit on a never-launched Process blocks indefinitely,
    // which would deadlock the caller. pkill missing is extremely
    // rare on macOS, but the failure mode is unbounded so worth gating.
    do {
        try killTask.run()
        killTask.waitUntilExit()
    } catch {
        fputs("WARNING: failed to run pkill: \(error.localizedDescription)\n", stderr)
    }

    // Use the save-sleep marker for "we previously overrode pmset" instead
    // of reading CHIE — if the SMC read fails, defaulting to
    // wasDischarging=false would silently strand the user with sleep=0.
    // The marker is reliably written before the CHIE=0x08 write and
    // cleaned up by setDischargeSleepPrevention(false).
    let saveFileExists = markerExists(savedSleepPaths)
    if smcWriteKey(conn, SMC.keyChargeInhibit, SMC.chieNormal) {
        if saveFileExists {
            // Wait for USB-C PD renegotiation to complete before re-enabling
            // clamshell sleep, otherwise the brief display disruption triggers sleep.
            sleep(3)
            _ = setDischargeSleepPrevention(enabled: false)
        }
        print("OK: active discharge disabled")
        exit(0)
    } else {
        fputs("ERROR: SMC write failed for CHIE\n", stderr)
        exit(2)
    }

default:
    fatalError("unexpected action: \(action)")
}
