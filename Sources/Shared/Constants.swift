public enum AppConstants {
    // Only the derived paths below are part of the public API — keep the
    // raw prefix private since nothing outside this file references it.
    private static let appPrefix = "az-ampere"
    public static let helperDirectory = "/Library/PrivilegedHelperTools"
    public static let helperPath = "\(helperDirectory)/\(appPrefix)-smc"
    /// Removed after the new helper has restored the old session successfully.
    public static let legacyHelperPath = "/usr/local/bin/\(appPrefix)-smc"
    public static let sudoersPath = "/etc/sudoers.d/\(appPrefix)"
    /// Root-owned state directory for the saved-pmset markers. Deliberately
    /// NOT under /tmp: macOS wipes /tmp at boot, while `pmset -a` overrides
    /// persist across reboots — a crash + reboot during discharge would lose
    /// a /tmp marker and strand the user with sleep permanently disabled.
    public static let stateDirPath = "/Library/Application Support/\(appPrefix)"
    public static let savedSleepPath = "\(stateDirPath)/saved-sleep"
    public static let savedDisplaySleepPath = "\(stateDirPath)/saved-sleep-display"
    /// Pre-override value of the system-wide SleepDisabled flag ("1"/"0").
    /// Captured alongside the sleep-minute markers so a restore can put the
    /// flag back instead of forcing 0 — forcing 0 silently cancels any
    /// OTHER keep-awake tool (e.g. Lidless) that had raised the same flag.
    /// No legacy /tmp path: older builds never wrote this marker.
    public static let savedSleepDisabledPath = "\(stateDirPath)/saved-sleep-disabled"
    /// Legacy marker locations used by older builds. Readers fall back to
    /// these so an upgrade with a marker still outstanding restores correctly.
    public static let legacySavedSleepPath = "/tmp/.\(appPrefix)-saved-sleep"
    public static let legacySavedDisplaySleepPath = "/tmp/.\(appPrefix)-saved-sleep-display"
}

/// Pack a 4-character SMC key (e.g. "CHTE") into a UInt32 in big-endian
/// order, matching what the SMC kernel extension expects.
public func smcFourCharCode(_ str: String) -> UInt32 {
    var result: UInt32 = 0
    for char in str.utf8.prefix(4) { result = (result << 8) | UInt32(char) }
    return result
}

/// SMC kernel command codes (the `data8` field of SMCKeyData specifies
/// which operation the call invokes). Documented from reverse-engineered
/// public Apple SMC headers — must match what AppleSMC's kernel extension
/// expects.
public enum SMCCmd {
    public static let readKey: UInt8 = 5
    public static let writeBytes: UInt8 = 6
    public static let readKeyInfo: UInt8 = 9

    /// Selector index for `IOConnectCallStructMethod` against both
    /// `AppleSMCKeysEndpoint` and `AppleSMC` — all SMC keys-endpoint
    /// operations go through this single selector and dispatch on the
    /// `data8` field.
    public static let userClientSelector: UInt32 = 2
}

/// SMC struct layout — used by both the Ampere app (for reads) and the
/// SMCWriter helper (for reads + writes). Lives in Shared so the layout
/// can't drift between the two targets.
public struct SMCKeyData {
    /// Capacity of the `bytes` tuple field — used as the upper bound when
    /// validating `keyInfo.dataSize` from a kernel response.
    public static let bytesCapacity: UInt32 = 32

    public struct Vers {
        public var major: UInt8 = 0
        public var minor: UInt8 = 0
        public var build: UInt8 = 0
        public var reserved: UInt8 = 0
        public var release: UInt16 = 0
        public init() {}
    }

    public struct PLimitData {
        public var version: UInt16 = 0
        public var length: UInt16 = 0
        public var cpuPLimit: UInt32 = 0
        public var gpuPLimit: UInt32 = 0
        public var memPLimit: UInt32 = 0
        public init() {}
    }

    public struct KeyInfo {
        public var dataSize: UInt32 = 0
        public var dataType: UInt32 = 0
        public var dataAttributes: UInt8 = 0
        public init() {}
    }

    public var key: UInt32 = 0
    public var vers: Vers = Vers()
    public var pLimitData: PLimitData = PLimitData()
    public var keyInfo: KeyInfo = KeyInfo()
    public var padding: UInt16 = 0
    public var result: UInt8 = 0
    public var status: UInt8 = 0
    public var data8: UInt8 = 0
    public var data32: UInt32 = 0
    public var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)

    public init() {}
}

/// SMC key/value constants for charge control.
public enum SMC {
    // MARK: - Keys
    public static let keyChargeTerminate = "CHTE"
    public static let keyChargeInhibit  = "CHIE"

    // MARK: - Byte values (for writing)
    public static let chteInhibit: [UInt8] = [0x01, 0x00, 0x00, 0x00]
    public static let chteAllow:   [UInt8] = [0x00, 0x00, 0x00, 0x00]
    public static let chieDischarge: [UInt8] = [0x08]
    public static let chieNormal:    [UInt8] = [0x00]

    // MARK: - Integer values (for reading/comparison)
    public static let chteInhibitInt = 1
    public static let chteAllowInt   = 0
    public static let chieDischargeInt = 8
    public static let chieNormalInt    = 0

    // MARK: - Display strings (for health check UI)
    public static let chteInhibitHex  = "0x01 00 00 00"
    public static let chteAllowHex    = "0x00 00 00 00"
    public static let chieDischargeHex = "0x08"
    public static let chieNormalHex    = "0x00"
}
