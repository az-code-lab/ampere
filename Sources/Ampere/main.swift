import Foundation
import SwiftUI

// Refuse to run a second instance — two instances fight over SMC state, and
// each launch's `nodischarge` cleanup pkills the *other* instance's watchdog.
// Matched by executable name rather than bundle ID so a debug build (`swift
// build` produces a bare executable with no bundle ID) and the installed app
// also exclude each other.
let myPID = ProcessInfo.processInfo.processIdentifier
if NSWorkspace.shared.runningApplications.contains(where: {
    $0.processIdentifier != myPID && $0.executableURL?.lastPathComponent == "Ampere"
}) {
    NSLog("Ampere: another instance is already running — exiting")
    exit(0)
}

// Set accessory policy before SwiftUI creates any windows,
// so WindowServer never transitions from .regular → .accessory
// (that transition can black-out external monitors).
NSApplication.shared.setActivationPolicy(.accessory)

// Normal GUI launch
AmpereApp.main()
