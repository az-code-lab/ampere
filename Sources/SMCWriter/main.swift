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
    // Bounds check (same guard as the app-side smcReadKey) — a malformed
    // dataSize > 32 would overrun the bytes tuple in the write loop below.
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

// (No smcReadKey here: the helper only writes. Reads live in the app,
// which doesn't need root for them.)

// MARK: - Sleep control

/// Run pmset with the given arguments, discarding output. Returns success.
func runPmset(_ arguments: [String]) -> Bool {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    task.arguments = arguments
    task.standardInput = FileHandle.nullDevice
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    do {
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            fputs("WARNING: pmset \(arguments.joined(separator: " ")) exited with status \(task.terminationStatus)\n", stderr)
            return false
        }
        return true
    } catch {
        fputs("WARNING: Failed to run pmset: \(error.localizedDescription)\n", stderr)
        return false
    }
}

/// Read `pmset -g custom` (the stored per-profile settings — Battery Power
/// and AC Power sections). This is the save-side source: `pmset -g` only
/// shows the *active* profile, and saving that single value then restoring
/// it with `-a` would blanket the AC value over the user's Battery-profile
/// settings.
func readPmsetCustomOutput() -> String? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    task.arguments = ["-g", "custom"]
    let pipe = Pipe()
    task.standardInput = FileHandle.nullDevice
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    do {
        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8)
    } catch {
        return nil
    }
}

/// Marker files storing the pre-override pmset values, checked in order.
/// The primary location is the persistent state dir (survives reboot); the
/// legacy /tmp path is still honored so an upgrade that happens while a
/// marker from an older build is outstanding can restore correctly.
let savedSleepPaths = [AppConstants.savedSleepPath, AppConstants.legacySavedSleepPath]
let savedDisplaySleepPaths = [AppConstants.savedDisplaySleepPath, AppConstants.legacySavedDisplaySleepPath]
/// No legacy path: older builds never saved the SleepDisabled flag (their
/// restore forced 0). A restore that finds no marker keeps that behavior.
let savedSleepDisabledPaths = [AppConstants.savedSleepDisabledPath]

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
/// but root-only writable. Returns success — a marker that failed to land
/// must abort the discharge (see setDischargeSleepPrevention).
func writeMarker(_ value: String, to paths: [String]) -> Bool {
    let primary = paths[0]
    let dir = (primary as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(
        atPath: dir, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o755])
    do {
        try value.write(toFile: primary, atomically: true, encoding: .utf8)
        return true
    } catch {
        fputs("WARNING: failed to write marker \(primary): \(error.localizedDescription)\n", stderr)
        return false
    }
}

/// Capture the pre-override per-profile values for `key` into its marker.
/// Returns false when the values can't be parsed out of the `pmset -g
/// custom` output or the marker can't be written.
func savePmsetMarker(key: String, paths: [String], customOutput: String?) -> Bool {
    guard let output = customOutput,
          let values = PmsetState.profileValues(forKey: key, inCustomOutput: output)
    else { return false }
    return writeMarker(PmsetState.markerString(values), to: paths)
}

/// Read a marker back as per-profile values, falling back to 10/10 (≈ the
/// macOS factory default, rather than 1 min) when it's missing, unparseable,
/// or out of pmset's accepted range — a wiped save file must not strand the
/// user with a Mac that sleeps after 60 seconds.
func restoredPmsetValues(_ paths: [String]) -> PmsetProfileValues {
    if let raw = readMarker(paths), let values = PmsetState.parseMarker(raw),
       PmsetState.validMinutes(values.battery), PmsetState.validMinutes(values.ac) {
        return values
    }
    return PmsetProfileValues(battery: 10, ac: 10)
}

/// Save the pre-override pmset originals for BOTH keys into their markers,
/// skipping markers that already exist (re-entry must not overwrite the
/// genuine originals with already-overridden values). Returns false when a
/// needed marker can't be captured: overriding without one would strand the
/// user — the restore paths (nodischarge, watchdog, release-sleep-hold) skip
/// pmset when no marker exists, and the next save would then capture the
/// *overridden* values as "original", making sleep=0 permanent.
///
/// Both keys are always saved together, even by the sleep-hold path that
/// never touches displaysleep: the shared restore puts back BOTH keys,
/// falling back to 10/10 for a missing marker — a fabricated displaysleep=10
/// stamped over the user's real setting is the bug the extra save prevents
/// (the unchanged value just round-trips).
///
/// The SleepDisabled flag is captured alongside them, with one extra rule
/// the minute markers don't need: on re-entry with the flag reading 0, the
/// marker is corrected to "0". The flag is a global bit shared with other
/// keep-awake tools; our override raised it, so reading 0 mid-override
/// means whichever external holder justified a saved "1" (e.g. Lidless)
/// has since released — restoring that stale "1" would leave the Mac
/// unable to sleep with nobody left to clear it. (Re-entry happens every
/// time the app re-asserts a hold it observed cleared externally, and on
/// a re-arm whose markers survived — a launch whose cleanup restore
/// failed, or an upgrade from a build without this marker.)
func saveSleepMarkers() -> Bool {
    let needSleep = !markerExists(savedSleepPaths)
    let needDisplay = !markerExists(savedDisplaySleepPaths)
    let disabledNow = readSleepDisabledFlag()
    // A disabled marker is only meaningful alongside the sleep marker —
    // every restore path is keyed on the sleep marker existing, and removes
    // the pair together. One found without it is a stale orphan (crash
    // between a restore's marker removals): recapture rather than trust it.
    let existingDisabled: Bool? = needSleep
        ? nil
        : PmsetState.parseFlagMarker(readMarker(savedSleepDisabledPaths))
    let disabledToWrite: Bool?
    if needSleep {
        // Fresh arm: nothing of ours is raised yet (the sleep marker is
        // removed only after a successful restore), so the flag as read IS
        // the pre-override original — 1 means an external holder.
        disabledToWrite = disabledNow
    } else if existingDisabled == nil {
        // Re-entry with the pair intact but no/garbage disabled marker —
        // an upgrade from a build that predates this marker, mid-override.
        // The flag now reads our own 1, so capturing it would make the
        // restore strand disablesleep=1. Capture 0: exactly what those
        // builds' restore would have written.
        disabledToWrite = false
    } else if existingDisabled == true, !disabledNow {
        disabledToWrite = false                // external holder released mid-override
    } else {
        disabledToWrite = nil                  // genuine original — keep it
    }
    guard needSleep || needDisplay || disabledToWrite != nil else { return true }
    let customOutput = (needSleep || needDisplay) ? readPmsetCustomOutput() : nil
    if needSleep, !savePmsetMarker(key: "sleep", paths: savedSleepPaths,
                                   customOutput: customOutput) {
        fputs("ERROR: cannot save original sleep values — refusing to override sleep\n", stderr)
        return false
    }
    if needDisplay, !savePmsetMarker(key: "displaysleep", paths: savedDisplaySleepPaths,
                                     customOutput: customOutput) {
        // A half-saved set must not outlive this call: a leftover sleep
        // marker with no displaysleep marker would make the next restore
        // path (nodischarge, watchdog, release-sleep-hold — all keyed on
        // the sleep marker existing) fabricate displaysleep=10/10 over the
        // user's real setting. Remove only what this call just wrote — a
        // pre-existing marker belongs to an active override and still
        // holds the genuine originals.
        if needSleep { removeMarkers([savedSleepPaths[0]]) }
        fputs("ERROR: cannot save original displaysleep values — refusing to override sleep\n", stderr)
        return false
    }
    if let disabled = disabledToWrite,
       !writeMarker(PmsetState.flagMarkerString(disabled), to: savedSleepDisabledPaths) {
        // Same half-saved rule as above. A failed *correction* leaves the
        // pre-existing markers alone (they belong to the active override);
        // the restore side still can't strand disablesleep=1 from the stale
        // marker, because restoreSleepDisabled also requires the flag to
        // still read 1 at restore time.
        if needSleep { removeMarkers([savedSleepPaths[0]]) }
        if needDisplay { removeMarkers([savedDisplaySleepPaths[0]]) }
        fputs("ERROR: cannot save original SleepDisabled value — refusing to override sleep\n", stderr)
        return false
    }
    return true
}

/// Prevent or restore system/clamshell sleep using pmset. Requires root.
///
/// The override still uses `-a` (sleep must be prevented, period), but the
/// originals are captured and restored PER PROFILE (`-b` / `-c`): discharge
/// always runs on AC, so the previous single-value save captured the AC
/// profile and its `-a` restore stamped that value over the user's Battery
/// profile too.
///
/// The restore side (`enabled: false`) is generic — it undoes whichever
/// override wrote the markers, discharge or the charge sleep-hold.
@discardableResult
func setDischargeSleepPrevention(enabled: Bool) -> Bool {
    if enabled {
        guard saveSleepMarkers() else { return false }
        // Disable both system sleep and display sleep to prevent clamshell issues
        return runPmset(["-a", "sleep", "0", "disablesleep", "1", "displaysleep", "0"])
    }

    return restoreSleepSettings(readSavedSleepSettings())
}

/// The pre-override values as read from the markers. Captured up front by
/// every restore that delays before applying: the crash watchdog and a
/// relaunch's cleanup can both pass the marker check, and whichever
/// finishes first consumes the markers. Re-reading them after the delay
/// would stamp the 10/10 fallback over the real values the other restore
/// just put back, while applying the same snapshot twice is harmless.
struct SavedSleepSettings {
    let sleep: PmsetProfileValues
    let display: PmsetProfileValues
    let disabledMarker: Bool?
}

func readSavedSleepSettings() -> SavedSleepSettings {
    SavedSleepSettings(
        sleep: restoredPmsetValues(savedSleepPaths),
        display: restoredPmsetValues(savedDisplaySleepPaths),
        disabledMarker: PmsetState.parseFlagMarker(readMarker(savedSleepDisabledPaths)))
}

/// Restore the original values per profile, then put SleepDisabled back
/// to its captured pre-override value instead of forcing 0 — forcing 0
/// cancels any OTHER keep-awake tool (e.g. Lidless) whose hold predates
/// ours, putting a lid-closed Mac to sleep out from under it. The saved
/// "1" is honored only while the flag still reads 1 (see
/// restoreSleepDisabled); a missing marker restores 0, matching builds
/// that predate the marker.
func restoreSleepSettings(_ saved: SavedSleepSettings) -> Bool {
    let disabled = PmsetState.restoreSleepDisabled(
        marker: saved.disabledMarker, current: readSleepDisabledFlag())
    let okBattery = runPmset(["-b", "sleep", "\(saved.sleep.battery)", "displaysleep", "\(saved.display.battery)"])
    let okAC = runPmset(["-c", "sleep", "\(saved.sleep.ac)", "displaysleep", "\(saved.display.ac)"])
    let okDisable = runPmset(["-a", "disablesleep", disabled ? "1" : "0"])
    guard okBattery && okAC && okDisable else { return false }
    // Markers are consumed only after every pmset call succeeds — a failed
    // restore keeps the originals in place so the watchdog or a later
    // nodischarge can retry with the real values instead of falling back
    // to the 10/10 defaults.
    removeMarkers(savedSleepPaths)
    removeMarkers(savedDisplaySleepPaths)
    removeMarkers(savedSleepDisabledPaths)
    return true
}

// MARK: - Main

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: smc-writer check|restore|remove-legacy|inhibit|allow|discharge:pid|nodischarge|hold-sleep|release-sleep-hold|spawn-watchdog:pid|watchdog:pid\n", stderr)
    exit(1)
}

let action = CommandLine.arguments[1]

// A harmless authorization probe: sudo -n -k must be able to run this
// command without a cached password before the app trusts its setup.
if action == "check" {
    exit(geteuid() == 0 && HelperSecurity.isProtected(path: AppConstants.helperPath) ? 0 : 1)
}

if action == "remove-legacy" {
    if !HelperSecurity.removeFileWithoutFollowingDirectories(at: AppConstants.legacyHelperPath) {
        // Its sudoers rule is already retired. Leaving an unused legacy
        // file is preferable to following an unsafe path during migration.
        fputs("WARNING: legacy helper could not be safely removed\n", stderr)
    }
    exit(0)
}

/// Restore only settings we actually overrode. Delay after a CHIE write
/// before re-enabling clamshell sleep so USB-C PD has time to settle. The
/// values are read before the delay (see SavedSleepSettings).
func restoreSavedSleep() -> Bool {
    guard markerExists(savedSleepPaths) else { return true }
    let saved = readSavedSleepSettings()
    sleep(3)
    return restoreSleepSettings(saved)
}

/// Retire both generations during migration. Called only after cleanup
/// succeeds; on failure the existing watchdog remains a recovery path.
func stopWatchdogs() -> Bool {
    let paths = [AppConstants.helperPath, AppConstants.legacyHelperPath]
        .map { NSRegularExpression.escapedPattern(for: $0) }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    task.arguments = ["-f", "^(" + paths.joined(separator: "|") + ") watchdog:[0-9]+$"]
    task.standardInput = FileHandle.nullDevice
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    do {
        try task.run()
        task.waitUntilExit()
        return task.terminationStatus == 0 || task.terminationStatus == 1
    } catch {
        fputs("WARNING: could not retire watchdogs: \(error.localizedDescription)\n", stderr)
        return false
    }
}

/// Spawn a detached watchdog daemon that monitors the given app PID.
/// When the app dies, the watchdog clears CHTE, CHIE, and restores sleep.
func spawnWatchdog(appPID: Int32) -> Bool {
    // Never re-execute argv[0] from a potentially user-writable location.
    // Every ancestor of the installed path must prevent replacement.
    let execPath = AppConstants.helperPath
    guard HelperSecurity.isProtected(path: execPath) else {
        fputs("ERROR: watchdog executable is not protected\n", stderr)
        return false
    }
    var spawnPid: pid_t = 0
    var fileActions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&fileActions)
    posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&fileActions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&fileActions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)

    // Detach into its own session (setsid): otherwise the watchdog inherits
    // the app's process group, and a terminal Ctrl+C (dev runs via run.sh)
    // delivers SIGINT to the whole foreground group — killing the watchdog
    // at the same instant as the app it exists to clean up after.
    var spawnAttrs: posix_spawnattr_t?
    posix_spawnattr_init(&spawnAttrs)
    posix_spawnattr_setflags(&spawnAttrs, Int16(POSIX_SPAWN_SETSID))

    let arg0 = strdup(execPath)!
    let arg1 = strdup("watchdog:\(appPID)")!
    var args: [UnsafeMutablePointer<CChar>?] = [arg0, arg1, nil]
    let result = posix_spawn(&spawnPid, execPath, &fileActions, &spawnAttrs, &args, nil)
    posix_spawnattr_destroy(&spawnAttrs)
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
    guard let appPID = Int32(action.dropFirst("spawn-watchdog:".count)), appPID > 0 else {
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

// "hold-sleep" — disable system sleep while a below-lower charge runs, so a
// closed lid can't suspend the app mid-charge (the SMC would then charge
// straight past the upper bound with nobody awake to stop it). Unlike the
// discharge override, displaysleep is left alone: there is no CHIE write and
// no PD renegotiation in this path, so the screen may sleep normally while
// the machine stays awake charging. Uses the same markers as discharge, so
// every existing restore path (release-sleep-hold, nodischarge, watchdog)
// can undo it — including after a crash. The app also re-issues this command
// when it observes an engaged hold's SleepDisabled flag cleared externally
// (another keep-awake tool released the shared bit); saveSleepMarkers then
// corrects the saved flag value, see its doc comment.
if action == "hold-sleep" {
    guard saveSleepMarkers() else {
        exit(4)
    }
    guard runPmset(["-a", "sleep", "0", "disablesleep", "1"]) else {
        fputs("ERROR: pmset failed — sleep hold not applied\n", stderr)
        exit(2)
    }
    print("OK: sleep hold enabled")
    exit(0)
}

// "release-sleep-hold" — restore the saved sleep settings after a charge
// sleep-hold. No PD settling delay (this path never touched CHIE), and a
// missing marker means there is nothing to release (already restored by
// nodischarge or the watchdog) — succeed silently.
if action == "release-sleep-hold" {
    if markerExists(savedSleepPaths) {
        guard setDischargeSleepPrevention(enabled: false) else {
            fputs("ERROR: failed to restore sleep settings\n", stderr)
            exit(2)
        }
    }
    print("OK: sleep hold released")
    exit(0)
}

// "discharge:PID" — set sleep prevention, write CHIE, spawn watchdog daemon, exit.
if action.hasPrefix("discharge:") {
    guard let appPID = Int32(action.dropFirst("discharge:".count)), appPID > 0 else {
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
    guard let appPID = Int32(action.dropFirst("watchdog:".count)), appPID > 0 else {
        _exit(1)
    }

    // Poll every 2s
    while true {
        sleep(2)
        if kill(appPID, 0) != 0 {
            // Retry on the next tick until both SMC keys and pmset are
            // restored. Exiting after a failed attempt abandons the only
            // remaining recovery path when the app has already died.
            if let conn = smcOpen() {
                let restored = HelperRecovery.restore(
                    clearDischarge: { smcWriteKey(conn, SMC.keyChargeInhibit, SMC.chieNormal) },
                    allowCharging: { smcWriteKey(conn, SMC.keyChargeTerminate, SMC.chteAllow) },
                    restoreSleep: restoreSavedSleep)
                IOServiceClose(conn)
                if restored { _exit(0) }
            }
        }
    }
}

// One-shot commands
let validActions: Set<String> = ["inhibit", "allow", "nodischarge", "restore"]
guard validActions.contains(action) else {
    fputs("Usage: smc-writer check|restore|remove-legacy|inhibit|allow|discharge:pid|nodischarge|hold-sleep|release-sleep-hold|spawn-watchdog:pid|watchdog:pid\n", stderr)
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

case "nodischarge", "restore":
    let restored = HelperRecovery.restore(
        clearDischarge: { smcWriteKey(conn, SMC.keyChargeInhibit, SMC.chieNormal) },
        allowCharging: {
            action != "restore" || smcWriteKey(conn, SMC.keyChargeTerminate, SMC.chteAllow)
        },
        restoreSleep: restoreSavedSleep,
        stopWatchdogs: stopWatchdogs)
    guard restored else {
        fputs("ERROR: cleanup incomplete — retaining recovery state and watchdogs\n", stderr)
        exit(2)
    }
    print(action == "restore" ? "OK: system defaults restored" : "OK: active discharge disabled")
    exit(0)

default:
    fatalError("unexpected action: \(action)")
}
