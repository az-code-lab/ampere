public enum AppConstants {
    public static let appPrefix = "az-ampere"
    public static let helperPath = "/usr/local/bin/\(appPrefix)-smc"
    public static let sudoersPath = "/etc/sudoers.d/\(appPrefix)"
    public static let savedSleepPath = "/tmp/.\(appPrefix)-saved-sleep"
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
