import AppKit
import Shared

// Refuse to run a second instance — two instances fight over SMC state, and
// each launch's `nodischarge` cleanup pkills the *other* instance's watchdog.
// Matched by executable name rather than bundle ID so a debug build (`swift
// build` produces a bare executable with no bundle ID) and the installed app
// also exclude each other.
let myPID = ProcessInfo.processInfo.processIdentifier
if NSWorkspace.shared.runningApplications.contains(where: {
    $0.processIdentifier != myPID && $0.executableURL?.lastPathComponent == "Ampere"
}) {
    AmpereLog.app("Ampere: another instance is already running — exiting")
    exit(0)
}

// A menu bar app from its first moment: the accessory policy is set before
// any window exists, so WindowServer never sees a regular app turn accessory
// during launch (that transition can black-out external monitors). The app
// turns regular later, while its panel is a window of its own, and accessory
// again when that window closes (AppDelegate.setRegularApp).
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// Every window is AppKit's, owned by AppDelegate, and so is the menu bar
// (MainMenu), so the app runs on AppKit's own loop: there is no SwiftUI
// scene. NSApplication holds its delegate weakly; this constant is what
// keeps it alive.
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.run()
