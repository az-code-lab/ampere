import Foundation

/// macOS's own Manual Charge Limit, used as the charge-control path on
/// firmware that no longer exposes the CHTE key (macOS 27, and the same
/// firmware in the macOS 26.7 update). Apple's replacement SMC keys are
/// locked behind a private entitlement, but the limit itself lives in
/// PowerUIAgent's preferences: a feature switch and a target percentage.
/// The agent registers the target with powerd and the firmware enforces it,
/// including during sleep, and drains the battery down to the target when
/// it sits above it. The agent's request interface refuses targets outside
/// Apple's slider range, so the helper writes these keys directly (it runs
/// as root, and so does the agent) and posts the reload notification the
/// agent observes. Pure constants and parsing live here so the helper, the
/// app, and the tests share one definition.
public enum NativeChargeLimit {
    /// The agent's preference domain, in root's home (`/var/root/Library/
    /// Preferences/<domain>.plist`), which is where a root process's
    /// `kCFPreferencesCurrentUser` writes land.
    public static let preferencesDomain = "com.apple.smartcharging.topoffprotection"
    /// 1 while the manual charge limit is on, 0 while off.
    public static let featureStateKey = "MCLFeatureState"
    /// The target state of charge, in percent.
    public static let limitValueKey = "mclLimitValue"
    /// Darwin notification the agent observes to reload its preferences
    /// (it logs "Loaded Settings" the moment it is posted).
    public static let reloadNotification = "com.apple.smartcharging.defaultschanged"

    /// Targets the firmware accepts. 100 means "no limit" to the agent.
    public static func validLimit(_ percent: Int) -> Bool {
        percent >= 1 && percent <= 100
    }

    /// The agent's pre-override values, captured before the first override
    /// so a release can put the user's own setting back. A key can be
    /// absent (a Mac where the feature was never touched).
    public struct Originals: Equatable {
        public var featureState: Int?
        public var limit: Int?
        public init(featureState: Int?, limit: Int?) {
            self.featureState = featureState
            self.limit = limit
        }
        /// True when the user had a limit of their own switched on.
        public var featureWasOn: Bool { featureState == 1 }
    }

    /// Marker file format: "<state> <limit>", "-" for an absent key,
    /// e.g. "0 100" or "- -".
    public static func markerString(_ originals: Originals) -> String {
        let state = originals.featureState.map(String.init) ?? "-"
        let limit = originals.limit.map(String.init) ?? "-"
        return "\(state) \(limit)"
    }

    /// Parse a marker. Nil for anything but two tokens that are each an
    /// integer or "-"; a corrupt marker must not drive a restore that
    /// switches the user's limit on with a made-up value.
    public static func parseMarker(_ raw: String) -> Originals? {
        let tokens = raw.split(whereSeparator: { $0.isWhitespace })
        guard tokens.count == 2 else { return nil }
        func value(_ token: Substring) -> Int?? {
            if token == "-" { return .some(nil) }
            guard let n = Int(token) else { return nil }
            return .some(n)
        }
        guard let state = value(tokens[0]), let limit = value(tokens[1]) else { return nil }
        return Originals(featureState: state, limit: limit)
    }

    /// The targets powerd currently enforces, parsed from `pmset -g
    /// battlimit`, whose entries look like
    ///
    ///     chargeSocLimitSoc = 60;
    ///
    /// one per registered limit (the agent's own and powerd's mirror of it).
    /// "No battery level limits set" yields an empty array. Anything else
    /// unparseable also yields empty, so the caller treats "no entries" as
    /// "nothing enforced" in both cases.
    public static func registeredLimits(inBattlimitOutput output: String) -> [Int] {
        var limits: [Int] = []
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("chargeSocLimitSoc") else { continue }
            let digits = trimmed.drop(while: { !$0.isNumber }).prefix(while: { $0.isNumber })
            if let n = Int(digits) { limits.append(n) }
        }
        return limits
    }
}
