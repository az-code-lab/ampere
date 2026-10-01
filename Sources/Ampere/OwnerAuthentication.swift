import Foundation
import LocalAuthentication
import Shared

/// Confirms that the person at the Mac is the account owner before an
/// action that changes who can use it. Keep Display On stops the Mac
/// from locking on its own, so it is the one switch on the panel that
/// must not be flipped by whoever happens to be at an unlocked Mac. The
/// prompt is the system's (`deviceOwnerAuthentication`): Touch ID where
/// a sensor is reachable, otherwise the account password (a Mac without
/// a sensor, or a MacBook running lid-closed in clamshell mode), or
/// Apple Watch where that is set up. Every request prompts afresh;
/// nothing is cached and nothing is stored.
enum OwnerAuthentication {
    enum Outcome: Equatable {
        case granted
        /// Declined at the prompt (Cancel, or the system dismissed it):
        /// nothing to explain to the user.
        case cancelled
        /// The system could not confirm the owner, in its own words (no
        /// password set on the account, too many failed attempts).
        case failed(String)
    }

    /// The context behind the prompt that is up, held here for the
    /// prompt's duration so the caller's scope ending cannot release it
    /// under the prompt.
    private static var inFlight: LAContext?

    /// `reason` completes the prompt's "Ampere is trying to …" sentence.
    /// `completion` runs on the main queue, exactly once.
    static func authenticate(reason: String, completion: @escaping (Outcome) -> Void) {
        let context = LAContext()
        var unavailable: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &unavailable) else {
            let why = unavailable?.localizedDescription ?? "Authentication is not available"
            AmpereLog.app("Ampere: Owner authentication unavailable: %@", why)
            DispatchQueue.main.async { completion(.failed(why)) }
            return
        }
        inFlight = context
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { granted, error in
            let outcome: Outcome
            if granted {
                outcome = .granted
            } else if let code = (error as? LAError)?.code,
                      [.userCancel, .systemCancel, .appCancel].contains(code) {
                outcome = .cancelled
            } else {
                outcome = .failed(error?.localizedDescription ?? "Authentication failed")
            }
            DispatchQueue.main.async {
                if inFlight === context { inFlight = nil }
                completion(outcome)
            }
        }
    }
}
