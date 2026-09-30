import Foundation
import Shared
import Combine
import IOKit

/// The host Mac's serial number from the IOKit registry, or nil if
/// unavailable. The license server lists each Mac registered to a key by
/// this value.
func deviceSerialNumber() -> String? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault,
        IOServiceMatching("IOPlatformExpertDevice"))
    guard service != MACH_PORT_NULL else { return nil }
    defer { IOObjectRelease(service) }

    return IORegistryEntryCreateCFProperty(service,
        kIOPlatformSerialNumberKey as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? String
}

/// What the license server says of a key, as far as the app uses it: whose it
/// is and how many Macs it registers at once. Read off the key the register
/// call answers with, or the one the verify call wraps in its verdict.
struct LicenseFacts: Equatable {
    /// The licensee's name; nil when the server does not say.
    var name: String?
    /// How many Macs the key registers at once: the terms of the license
    /// model it was issued from, which the key keeps even when the model
    /// changes later. One when the server does not say, or says nonsense,
    /// the way the server itself reads an unsaid count.
    var maxDevices: Int

    init(name: String?, maxDevices: Int) {
        self.name = name
        self.maxDevices = max(1, maxDevices)
    }

    init(license: [String: Any]) {
        self.init(name: license["name"] as? String,
                  maxDevices: license["max_devices"] as? Int ?? 1)
    }
}

/// Client for the azcode license server.
///
/// Register adds this Mac to a key and binds the key to the email. A key
/// registers as many Macs at once as the server says for it (`maxDevices`):
/// a one-Mac key moves to the Mac that registers it, and a key with room for
/// several fills up and refuses a further Mac until one is deregistered here
/// or released under My Licenses at azcode.dev.
///
/// Registration state (email, name, key, the key's Mac count, active flag)
/// persists in UserDefaults so the app restores it after a restart or crash.
/// The server is the source of truth: a periodic verify (email + device
/// serial, no key) can flip the app back to unregistered if this Mac was
/// deregistered or released from the key, another Mac took its place on a
/// one-Mac key, or the license ended or was revoked. Network failures never
/// change local state — an offline Mac stays in its last known state rather
/// than losing its registration.
final class RegistrationManager: ObservableObject {
    @Published private(set) var isRegistered: Bool
    @Published private(set) var email: String
    @Published private(set) var name: String
    @Published private(set) var licenseKey: String
    /// How many Macs the key registers at once, as the server last said for
    /// it. Nil until it has said: a registration an earlier build made keeps
    /// no count, and its first verify after the update brings one. The
    /// registration window words the key's rules by it (`explanation(macs:)`),
    /// and without a count it words them so they hold for any key.
    @Published private(set) var maxDevices: Int?
    @Published private(set) var isBusy = false
    @Published var lastError: String?

    let deviceSerial: String?

    /// Where the state persists: the app's standard defaults, or a scratch
    /// suite in tests.
    private let defaults: UserDefaults
    private var verifyTimer: Timer?

    private static let emailDefaultsKey = "registration.email"
    private static let nameDefaultsKey = "registration.name"
    private static let keyDefaultsKey = "registration.licenseKey"
    private static let maxDevicesDefaultsKey = "registration.maxDevices"
    private static let activeDefaultsKey = "registration.active"
    /// Sent with every call, so the server only ever hands this app an
    /// Ampere key: another app's key answers "Invalid license key" instead
    /// of taking one of its own Macs' places for this one.
    private static let product = "ampere"

    /// Bare app version ("0.0.48") reported with register/verify so the
    /// license dashboard can show what each Mac runs. Strips the git-tag
    /// "v" prefix, matching the updater's version comparison.
    private static let appVersion = AppVersion.current.hasPrefix("v")
        ? String(AppVersion.current.dropFirst())
        : AppVersion.current

    /// This Mac's macOS version ("26.7.1"), reported with register/verify
    /// beside the app version. It shows the license dashboard which systems
    /// registered Macs run, which is what decides the oldest macOS the app
    /// has to keep supporting. Only registered copies ever send it: an
    /// unregistered copy makes no license-server call at all.
    private static let macOSVersion = SystemVersion.current

    /// Production server; override for local testing with
    /// `defaults write <bundle id> registration.serverURL http://localhost:8080`.
    private var baseURL: URL {
        if let override = defaults.string(forKey: "registration.serverURL"),
           let url = URL(string: override) {
            return url
        }
        return URL(string: "https://azcode.dev")!
    }

    /// The defaults are the app's own and the serial this Mac's; tests pass a
    /// scratch suite and a made-up serial, so nothing they do reaches the
    /// real preferences or names a real Mac.
    init(defaults: UserDefaults = .standard, deviceSerial: String? = deviceSerialNumber()) {
        self.defaults = defaults
        self.deviceSerial = deviceSerial
        self.email = defaults.string(forKey: Self.emailDefaultsKey) ?? ""
        self.name = defaults.string(forKey: Self.nameDefaultsKey) ?? ""
        self.licenseKey = defaults.string(forKey: Self.keyDefaultsKey) ?? ""
        // Absent for a copy registered before the count was kept: unknown,
        // not one, until the first verify brings the key's own count.
        self.maxDevices = (defaults.object(forKey: Self.maxDevicesDefaultsKey) as? Int).map { max(1, $0) }
        self.isRegistered = defaults.bool(forKey: Self.activeDefaultsKey)

        // Verify shortly after launch, then ~daily with jitter (same rationale
        // as the update check: avoid coordinated client stampedes).
        verifyTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            self?.verify()
            self?.scheduleNextVerify()
        }
    }

    deinit {
        verifyTimer?.invalidate()
    }

    // MARK: - Actions

    func register(email rawEmail: String, key rawKey: String, completion: @escaping (Bool) -> Void) {
        let email = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !email.isEmpty, email.contains("@"), !key.isEmpty else {
            lastError = "Enter a valid email and registration key"
            completion(false)
            return
        }
        guard let serial = deviceSerial else {
            lastError = "Could not identify this Mac"
            completion(false)
            return
        }

        isBusy = true
        lastError = nil
        post("/api/pub/license/register",
             body: ["email": email, "license_key": key, "device_serial": serial, "product": Self.product,
                    "app_version": Self.appVersion, "macos_version": Self.macOSVersion]) { [weak self] result in
            guard let self else { return }
            self.isBusy = false
            switch result {
            case .success(let json):
                let facts = LicenseFacts(license: json)
                self.setState(registered: true, email: email, key: key,
                              name: facts.name ?? "", maxDevices: facts.maxDevices)
                AmpereLog.app("Ampere: Registered to %@ (a key for %d Macs)", email, facts.maxDevices)
                completion(true)
            case .failure(let message, _):
                self.lastError = message
                completion(false)
            }
        }
    }

    func deregister(completion: @escaping (Bool) -> Void) {
        guard let serial = deviceSerial else {
            lastError = "Could not identify this Mac"
            completion(false)
            return
        }
        isBusy = true
        lastError = nil
        post("/api/pub/license/deregister",
             body: ["email": email, "device_serial": serial, "product": Self.product]) { [weak self] result in
            guard let self else { return }
            self.isBusy = false
            switch result {
            case .success:
                self.setState(registered: false)
                AmpereLog.app("Ampere: Deregistered")
                completion(true)
            case .failure(_, let status) where status == 404:
                // The server has no active registration for this Mac — the
                // goal state is already true, so agree with it locally.
                self.setState(registered: false)
                completion(true)
            case .failure(let message, _):
                self.lastError = message
                completion(false)
            }
        }
    }

    /// Ask the server whether this email + serial still hold a valid
    /// registration. Only a definitive `valid: false` clears local state;
    /// errors and network failures leave it untouched.
    func verify() {
        guard isRegistered, !email.isEmpty, let serial = deviceSerial else { return }
        post("/api/pub/license/verify",
             body: ["email": email, "device_serial": serial, "product": Self.product,
                    "app_version": Self.appVersion, "macos_version": Self.macOSVersion]) { [weak self] result in
            guard let self else { return }
            if case .success(let json) = result,
               let valid = json["valid"] as? Bool {
                if !valid {
                    AmpereLog.app("Ampere: Registration no longer valid, switching to unregistered")
                    self.setState(registered: false)
                    self.lastError = Self.lapsedMessage
                } else if let license = json["license"] as? [String: Any] {
                    // Keep the licensee name and the key's Mac count in sync
                    // with the server: the name can be filled in or corrected
                    // after the initial registration, and an admin can give
                    // the key room for more Macs (or fewer).
                    let facts = LicenseFacts(license: license)
                    let name = facts.name.flatMap { $0 == self.name ? nil : $0 }
                    let maxDevices = facts.maxDevices == self.maxDevices ? nil : facts.maxDevices
                    if name != nil || maxDevices != nil {
                        self.setState(registered: true, name: name, maxDevices: maxDevices)
                    }
                }
            }
        }
    }

    /// Called as the registration window opens: a stale form error from an
    /// earlier attempt goes, but why a daily verify ended the registration
    /// stays. The window is usually closed when a verify ends it, and opening
    /// it is where the user looks; the next register attempt clears it.
    func clearStaleError() {
        if lastError != Self.lapsedMessage { lastError = nil }
    }

    // MARK: - Words

    /// What the registration window says when a daily verify ends the
    /// registration: every way a key can stop holding this Mac.
    static let lapsedMessage = "The registration is no longer valid for this Mac: this Mac was deregistered or released from the key, another Mac took its place, the license ended, or it was withdrawn."

    /// The registered window's account of the key's rules, for the key this
    /// copy holds: how many Macs it registers and how room is made on it. A
    /// one-Mac key moves to whichever Mac registers it; a key with room for
    /// several holds them, and refuses a further Mac once full. Before the
    /// server has said (nil), only what holds for every key.
    static func explanation(macs count: Int?) -> String {
        guard let count else {
            return "Deregister This Mac takes this Mac off the key, so another Mac can register with it."
        }
        return count <= 1
            ? "This key registers one Mac at a time. To move it, deregister here, or simply register on the other Mac with the same email and key: the key moves there, and this Mac goes back to unregistered at its next check."
            : "This key registers up to \(count) Macs at once. Deregister This Mac takes this Mac off the key, and a Mac that is gone can be released under My Licenses at azcode.dev. When the key is full, another Mac is refused until you make room."
    }

    // MARK: - Internals

    private func scheduleNextVerify() {
        verifyTimer = Timer.scheduledTimer(
            withTimeInterval: Double.random(in: 79200 ..< 93600),
            repeats: false
        ) { [weak self] _ in
            self?.verify()
            self?.scheduleNextVerify()
        }
    }

    /// Persist and publish a registration state change. Email/name/key are
    /// kept on deregistration so the form can prefill for a later re-register;
    /// the key's Mac count is kept too, and replaced by the server's own at
    /// the next registration.
    private func setState(registered: Bool, email: String? = nil, key: String? = nil,
                          name: String? = nil, maxDevices: Int? = nil) {
        if let email { self.email = email; defaults.set(email, forKey: Self.emailDefaultsKey) }
        if let name { self.name = name; defaults.set(name, forKey: Self.nameDefaultsKey) }
        if let key { self.licenseKey = key; defaults.set(key, forKey: Self.keyDefaultsKey) }
        if let maxDevices {
            self.maxDevices = max(1, maxDevices)
            defaults.set(self.maxDevices, forKey: Self.maxDevicesDefaultsKey)
        }
        isRegistered = registered
        defaults.set(registered, forKey: Self.activeDefaultsKey)
    }

    private enum PostResult {
        case success([String: Any])
        case failure(String, Int)

        static func failure(_ message: String) -> PostResult { .failure(message, 0) }
    }

    /// POST JSON to the license server and deliver the parsed response on the
    /// main queue. Non-2xx responses surface the server's message (the API
    /// returns a bare JSON string on errors).
    private func post(_ path: String, body: [String: Any],
                      completion: @escaping (PostResult) -> Void) {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 15

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            let result: PostResult
            if let error {
                result = .failure(error.localizedDescription)
            } else if let http = response as? HTTPURLResponse {
                // .fragmentsAllowed: the API returns bare JSON strings for
                // error messages, which are fragments at the top level.
                let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0, options: .fragmentsAllowed) }
                if (200 ..< 300).contains(http.statusCode) {
                    result = .success(json as? [String: Any] ?? [:])
                } else {
                    let message = json as? String ?? "Server error (\(http.statusCode))"
                    result = .failure(message, http.statusCode)
                }
            } else {
                result = .failure("No response from server")
            }
            DispatchQueue.main.async { completion(result) }
        }
        task.resume()
    }
}
