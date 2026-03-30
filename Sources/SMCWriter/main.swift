// Minimal SMC writer — no SwiftUI/AppKit to avoid WindowServer side effects.
// This binary is invoked as root via sudo to set SMC charging keys.

import Foundation
import IOKit
import Shared

// MARK: - SMC Data Types (duplicated to avoid cross-target dependency on AppKit)

struct SMCKeyData {
    struct Vers {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    struct PLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var vers: Vers = Vers()
    var pLimitData: PLimitData = PLimitData()
    var keyInfo: KeyInfo = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}

private let smcCmdWriteBytes: UInt8 = 6
private let smcCmdReadKeyInfo: UInt8 = 9

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

func fourCharCode(_ str: String) -> UInt32 {
    var result: UInt32 = 0
    for char in str.utf8.prefix(4) {
        result = (result << 8) | UInt32(char)
    }
    return result
}

func smcWriteKey(_ conn: io_connect_t, _ key: String, _ bytes: [UInt8]) -> Bool {
    let smcKey = fourCharCode(key)
    var inputStruct = SMCKeyData()
    var outputStruct = SMCKeyData()
    inputStruct.key = smcKey
    inputStruct.data8 = smcCmdReadKeyInfo
    let inputSize = MemoryLayout<SMCKeyData>.size
    var outputSize = MemoryLayout<SMCKeyData>.size

    var result = IOConnectCallStructMethod(conn, 2,
        &inputStruct, inputSize, &outputStruct, &outputSize)
    guard result == kIOReturnSuccess else { return false }

    let dataType = outputStruct.keyInfo.dataType
    let dataSize = outputStruct.keyInfo.dataSize

    inputStruct = SMCKeyData()
    outputStruct = SMCKeyData()
    inputStruct.key = smcKey
    inputStruct.keyInfo.dataSize = dataSize
    inputStruct.keyInfo.dataType = dataType
    inputStruct.data8 = smcCmdWriteBytes

    withUnsafeMutablePointer(to: &inputStruct.bytes) { ptr in
        let raw = UnsafeMutableRawPointer(ptr)
        for (i, byte) in bytes.prefix(Int(dataSize)).enumerated() {
            raw.storeBytes(of: byte, toByteOffset: i, as: UInt8.self)
        }
    }

    outputSize = MemoryLayout<SMCKeyData>.size
    result = IOConnectCallStructMethod(conn, 2,
        &inputStruct, inputSize, &outputStruct, &outputSize)
    return result == kIOReturnSuccess
}

private let smcCmdReadKey: UInt8 = 5

func smcReadKey(_ conn: io_connect_t, _ key: String) -> [UInt8]? {
    let smcKey = fourCharCode(key)
    let inputSize = MemoryLayout<SMCKeyData>.size
    var outputSize = MemoryLayout<SMCKeyData>.size

    // Get key info
    var input = SMCKeyData()
    var output = SMCKeyData()
    input.key = smcKey
    input.data8 = smcCmdReadKeyInfo
    guard IOConnectCallStructMethod(conn, 2, &input, inputSize, &output, &outputSize) == kIOReturnSuccess else { return nil }

    let dataSize = output.keyInfo.dataSize
    guard dataSize > 0, dataSize <= 32 else { return nil }

    // Read value
    input = SMCKeyData()
    input.key = smcKey
    input.keyInfo.dataSize = dataSize
    input.data8 = smcCmdReadKey
    output = SMCKeyData()
    outputSize = MemoryLayout<SMCKeyData>.size
    guard IOConnectCallStructMethod(conn, 2, &input, inputSize, &output, &outputSize) == kIOReturnSuccess else { return nil }

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
            let trimmed = line.trimmingCharacters(in: .whitespaces)
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

/// Path to store the original sleep value for restoration.
let savedSleepPath = AppConstants.savedSleepPath

/// Prevent or restore system/clamshell sleep using pmset. Requires root.
@discardableResult
func setDischargeSleepPrevention(enabled: Bool) -> Bool {
    if enabled {
        // Save original values before overriding, but only if not already saved
        // (avoids overwriting with already-overridden values on re-entry)
        let fm = FileManager.default
        if !fm.fileExists(atPath: savedSleepPath), let original = readPmsetSleep() {
            try? "\(original)".write(toFile: savedSleepPath, atomically: true, encoding: .utf8)
        }
        if !fm.fileExists(atPath: savedSleepPath + "-display"), let original = readPmsetValue("displaysleep") {
            try? "\(original)".write(toFile: savedSleepPath + "-display", atomically: true, encoding: .utf8)
        }
    }

    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    if enabled {
        // Disable both system sleep and display sleep to prevent clamshell issues
        task.arguments = ["-a", "sleep", "0", "disablesleep", "1", "displaysleep", "0"]
    } else {
        // Restore original values
        let originalSleep: String
        if let saved = try? String(contentsOfFile: savedSleepPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !saved.isEmpty {
            originalSleep = saved
            try? FileManager.default.removeItem(atPath: savedSleepPath)
        } else {
            originalSleep = "1"
        }
        let originalDisplaySleep: String
        if let saved = try? String(contentsOfFile: savedSleepPath + "-display", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !saved.isEmpty {
            originalDisplaySleep = saved
            try? FileManager.default.removeItem(atPath: savedSleepPath + "-display")
        } else {
            originalDisplaySleep = "10"
        }
        task.arguments = ["-a", "sleep", originalSleep, "disablesleep", "0", "displaysleep", originalDisplaySleep]
    }
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    do {
        try task.run()
        task.waitUntilExit()
        return task.terminationStatus == 0
    } catch {
        fputs("WARNING: Failed to run pmset: \(error.localizedDescription)\n", stderr)
        return false
    }
}

// MARK: - Main

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: smc-writer inhibit|allow|discharge:pid|nodischarge|watchdog:pid\n", stderr)
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
    _ = spawnWatchdog(appPID: appPID)
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

    _ = setDischargeSleepPrevention(enabled: true)

    let chieValue: [UInt8] = [0x08]
    guard smcWriteKey(conn, "CHIE", chieValue) else {
        _ = setDischargeSleepPrevention(enabled: false)
        IOServiceClose(conn)
        fputs("ERROR: SMC write failed for CHIE\n", stderr)
        exit(2)
    }
    IOServiceClose(conn)

    _ = spawnWatchdog(appPID: appPID)

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
                _ = smcWriteKey(conn, "CHIE", [0x00])
                _ = smcWriteKey(conn, "CHTE", [0x00, 0x00, 0x00, 0x00])
                IOServiceClose(conn)
            }
            // Wait for PD renegotiation to settle before restoring sleep
            sleep(3)
            _ = setDischargeSleepPrevention(enabled: false)
            _exit(0)
        }
    }
}

// One-shot commands
let validActions: Set<String> = ["inhibit", "allow", "nodischarge"]
guard validActions.contains(action) else {
    fputs("Usage: smc-writer inhibit|allow|discharge:pid|nodischarge|watchdog:pid\n", stderr)
    exit(1)
}

guard let conn = smcOpen() else {
    fputs("ERROR: Could not open SMC connection\n", stderr)
    exit(1)
}
defer { IOServiceClose(conn) }

switch action {
case "inhibit":
    let chteValue: [UInt8] = [0x01, 0x00, 0x00, 0x00]
    if smcWriteKey(conn, "CHTE", chteValue) {
        print("OK: charging inhibited")
        exit(0)
    } else {
        fputs("ERROR: SMC write failed for CHTE\n", stderr)
        exit(2)
    }

case "allow":
    let chteValue: [UInt8] = [0x00, 0x00, 0x00, 0x00]
    if smcWriteKey(conn, "CHTE", chteValue) {
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
    try? killTask.run()
    killTask.waitUntilExit()

    // Clears CHIE and restores sleep if discharge was active.
    let wasDischarging = smcReadKey(conn, "CHIE").map { $0.contains(where: { $0 != 0 }) } ?? false
    let chieValue: [UInt8] = [0x00]
    if smcWriteKey(conn, "CHIE", chieValue) {
        if wasDischarging {
            // Wait for USB-C PD renegotiation to complete before re-enabling
            // clamshell sleep, otherwise the brief display disruption triggers sleep.
            sleep(3)
            _ = setDischargeSleepPrevention(enabled: false)
        } else {
            // Clean up stale sleep files without changing pmset settings
            try? FileManager.default.removeItem(atPath: savedSleepPath)
            try? FileManager.default.removeItem(atPath: savedSleepPath + "-display")
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
