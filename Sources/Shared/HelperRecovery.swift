/// Cleanup may partially succeed. Keep the watchdog until every required
/// restore succeeds. restoreSleep retains its markers on failure so the
/// next attempt can finish with the same saved settings.
public enum HelperRecovery {
    public static func restore(
        clearDischarge: () -> Bool,
        allowCharging: () -> Bool = { true },
        restoreSleep: () -> Bool,
        stopWatchdogs: () -> Bool = { true }
    ) -> Bool {
        let dischargeOK = clearDischarge()
        let chargingOK = allowCharging()
        // Never re-enable clamshell sleep while CHIE may still be set.
        guard dischargeOK else { return false }
        let sleepOK = restoreSleep()
        guard chargingOK && sleepOK else { return false }
        return stopWatchdogs()
    }
}
