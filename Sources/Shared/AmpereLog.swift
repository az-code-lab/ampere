import Foundation
import os

/// Every diagnostic line the app and the helper emit goes through here to
/// the unified log, with the message explicitly marked public. NSLog was
/// the previous channel; from macOS 27 its messages appear in `log show`
/// only as `<private>`, which turned the app's own diagnostics, the first
/// thing to look at when charge control misbehaves, into noise. Read them
/// with
///
///     log show --last 1h --predicate 'subsystem == "com.az-code-lab.ampere"'
///
/// The signature mirrors NSLog so call sites keep their printf-style
/// formats (`%d`, `%@`, `%08x`, `%%`); rendering is a pure function so a
/// test can pin those semantics. Nothing sensitive is logged: percentages,
/// key names, command names, and helper exit codes.
public enum AmpereLog {
    public static let subsystem = AppConstants.appBundleIdentifier
    private static let appLogger = Logger(subsystem: subsystem, category: "app")
    private static let helperLogger = Logger(subsystem: subsystem, category: "helper")

    /// The app's diagnostics. Default level, persisted to disk like NSLog.
    public static func app(_ format: String, _ args: CVarArg...) {
        appLogger.log(level: .default, "\(render(format, args), privacy: .public)")
    }

    /// The helper's and the watchdog's diagnostics. One-shot helper runs
    /// also report failures on stderr, which the app captures; the
    /// detached watchdog has only this channel.
    public static func helper(_ format: String, _ args: CVarArg...) {
        helperLogger.log(level: .default, "\(render(format, args), privacy: .public)")
    }

    /// NSLog-style rendering: the whole message is formatted here, so one
    /// already-rendered string reaches the log.
    public static func render(_ format: String, _ args: [CVarArg]) -> String {
        String(format: format, arguments: args)
    }
}
