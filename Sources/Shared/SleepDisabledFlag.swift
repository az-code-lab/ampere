import Foundation
import IOKit

/// Read the system-wide "SleepDisabled" flag from IOPMrootDomain — the bit
/// `pmset -a disablesleep 1` sets, and the only mechanism that overrides
/// lid-close (clamshell) sleep on Apple Silicon. It is a single global bit
/// with no ownership or reference counting: Ampere's sleep hold / discharge
/// override raises it, but so do third-party keep-awake tools (e.g.
/// Lidless), and either side's clear cancels the other's hold. Both the app
/// (to detect an engaged hold being cleared externally) and the SMCWriter
/// helper (to capture the pre-override value into its marker) read it
/// through this one function so their view of the flag can't drift.
///
/// A missing property or failed read reports false ("not disabled"): the
/// property is absent until the flag is first set after boot, and false is
/// the safe direction everywhere this is consumed — the app re-asserts a
/// hold it believes was cleared (idempotent), and the helper captures/
/// restores 0, which matches the pre-marker behavior.
public func readSleepDisabledFlag() -> Bool {
    let entry = IOServiceGetMatchingService(kIOMainPortDefault,
        IOServiceMatching("IOPMrootDomain"))
    guard entry != MACH_PORT_NULL else { return false }
    defer { IOObjectRelease(entry) }
    let value = IORegistryEntryCreateCFProperty(entry, "SleepDisabled" as CFString,
        kCFAllocatorDefault, 0)?.takeRetainedValue()
    if let flag = value as? Bool { return flag }
    // pmset writes the flag as a CFBoolean, but tolerate a numeric
    // representation too — IORegistry properties bridge to NSNumber.
    if let number = value as? NSNumber { return number.boolValue }
    return false
}
