public enum AppConstants {
    public static let appPrefix = "az-battery-manager"
    public static let helperPath = "/usr/local/bin/\(appPrefix)-smc"
    public static let sudoersPath = "/etc/sudoers.d/\(appPrefix)"
    public static let savedSleepPath = "/tmp/.\(appPrefix)-saved-sleep"
}
