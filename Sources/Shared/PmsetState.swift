import Foundation

/// A pmset value captured per power profile. Discharge overrides sleep with
/// `pmset -a`, which writes ALL profiles — so a faithful restore must put
/// back the Battery (`pmset -b`) and AC (`pmset -c`) values separately, not
/// blanket the AC-profile value over both with `-a`.
public struct PmsetProfileValues: Equatable {
    public let battery: Int
    public let ac: Int
    public init(battery: Int, ac: Int) {
        self.battery = battery
        self.ac = ac
    }
}

/// Pure parsing/serialization for the saved-pmset markers, shared between
/// the SMCWriter helper (which does the actual pmset calls) and the tests
/// (the helper target itself isn't importable from the test bundle).
public enum PmsetState {
    /// Extract one key's value from both profile sections of
    /// `pmset -g custom` output, e.g.
    ///
    ///     Battery Power:
    ///      displaysleep         10
    ///      sleep                10
    ///     AC Power:
    ///      sleep                0
    ///
    /// Returns nil unless BOTH profiles yield a value — a partial capture
    /// must never drive a save, or the restore would fabricate one side.
    /// The exact-match on `parts[0]` keeps "sleep" from latching onto
    /// "displaysleep"/"disksleep" lines; annotations after the value
    /// ("sleep 1 (sleep prevented by powerd)") are tolerated.
    public static func profileValues(forKey key: String, inCustomOutput output: String) -> PmsetProfileValues? {
        enum Section { case battery, ac, none }
        var section = Section.none
        var battery: Int?
        var ac: Int?
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("Battery Power") { section = .battery; continue }
            if trimmed.hasPrefix("AC Power") { section = .ac; continue }
            guard trimmed.hasPrefix(key) else { continue }
            let parts = trimmed.split(separator: " ")
            guard parts.count >= 2, parts[0] == Substring(key), let val = Int(parts[1]) else { continue }
            switch section {
            case .battery: if battery == nil { battery = val }
            case .ac: if ac == nil { ac = val }
            case .none: break
            }
        }
        guard let battery, let ac else { return nil }
        return PmsetProfileValues(battery: battery, ac: ac)
    }

    /// Marker file format: "<battery> <ac>", e.g. "10 0".
    public static func markerString(_ values: PmsetProfileValues) -> String {
        "\(values.battery) \(values.ac)"
    }

    /// Parse marker contents. Also accepts the legacy single-value format
    /// written by older builds — those captured the active (always AC,
    /// since discharge requires an adapter) profile and restored it with
    /// `-a`, so applying the one value to both profiles matches what the
    /// old restore would have done.
    public static func parseMarker(_ raw: String) -> PmsetProfileValues? {
        let tokens = raw.split(whereSeparator: { $0.isWhitespace })
        let nums = tokens.compactMap { Int($0) }
        guard nums.count == tokens.count else { return nil }
        if nums.count == 2 { return PmsetProfileValues(battery: nums[0], ac: nums[1]) }
        if nums.count == 1 { return PmsetProfileValues(battery: nums[0], ac: nums[0]) }
        return nil
    }

    /// Validate before passing a value back to pmset: pmset rejects the
    /// *entire* command atomically if any arg is invalid, which would leave
    /// disablesleep=1 stuck. Accept only 0–1440 (= up to 24h, well past any
    /// sensible user setting; 0 = "never" is a legitimate value).
    public static func validMinutes(_ n: Int) -> Bool {
        n >= 0 && n <= 1440
    }

    // MARK: - SleepDisabled marker

    /// Marker file format for the saved SleepDisabled flag: "1" or "0".
    public static func flagMarkerString(_ value: Bool) -> String {
        value ? "1" : "0"
    }

    /// Parse a SleepDisabled marker. Strict on purpose: anything but a bare
    /// "0"/"1" (whitespace-trimmed) is nil, and callers treat nil as
    /// "restore 0" — an unreadable marker must never guess its way into
    /// leaving a Mac unable to sleep.
    public static func parseFlagMarker(_ raw: String?) -> Bool? {
        guard let raw else { return nil }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "1": return true
        case "0": return false
        default: return nil
        }
    }

    /// The disablesleep value a restore should write back. The saved marker
    /// alone is not enough: "1" is only trustworthy while the flag is in
    /// fact still raised. The external holder that justified the save can
    /// release mid-override (Lidless's auto-off timer, its crash watchdog,
    /// a manual `pmset disablesleep 0`) — the flag then reads 0 despite our
    /// own override, because the bit is global and last-writer-wins. In
    /// that case restoring the saved "1" would strand the Mac unable to
    /// sleep with nobody left to clear it, which is the one outcome every
    /// restore path in this project is designed to avoid. So: restore 1
    /// only when the marker says 1 AND the flag still reads 1; every other
    /// combination (no marker, saved 0, externally cleared) restores 0.
    public static func restoreSleepDisabled(marker: Bool?, current: Bool) -> Bool {
        (marker ?? false) && current
    }
}
