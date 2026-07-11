import Foundation
import Combine
import IOKit

/// The host Mac's serial number from the IOKit registry, or nil if
/// unavailable. Registrations are bound to this value server-side.
func deviceSerialNumber() -> String? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault,
        IOServiceMatching("IOPlatformExpertDevice"))
    guard service != MACH_PORT_NULL else { return nil }
    defer { IOObjectRelease(service) }

    return IORegistryEntryCreateCFProperty(service,
        kIOPlatformSerialNumberKey as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? String
}

/// Client for the azcode license server.
///
/// Registration state (email, name, key, active flag) persists in UserDefaults
/// so the app restores it after a restart or crash. The server is the source of
/// truth: a periodic verify (email + device serial, no key) can flip the app
/// back to unregistered if the license was revoked or moved to another Mac.
/// Network failures never change local state — an offline Mac stays in its
/// last known state rather than losing its registration.
final class RegistrationManager: ObservableObject {
    @Published private(set) var isRegistered: Bool
    @Published private(set) var email: String
    @Published private(set) var name: String
    @Published private(set) var licenseKey: String
    @Published private(set) var isBusy = false
    @Published var lastError: String?

    let deviceSerial = deviceSerialNumber()

    private var verifyTimer: Timer?

    private static let emailDefaultsKey = "registration.email"
    private static let nameDefaultsKey = "registration.name"
    private static let keyDefaultsKey = "registration.licenseKey"
    private static let activeDefaultsKey = "registration.active"
    private static let product = "ampere"

    /// Bare app version ("0.0.48") reported with register/verify so the
    /// license dashboard can show what each Mac runs. Strips the git-tag
    /// "v" prefix, matching the updater's version comparison.
    private static let appVersion = AppVersion.current.hasPrefix("v")
        ? String(AppVersion.current.dropFirst())
        : AppVersion.current

    /// Production server; override for local testing with
    /// `defaults write <bundle id> registration.serverURL http://localhost:8080`.
    private static var baseURL: URL {
        if let override = UserDefaults.standard.string(forKey: "registration.serverURL"),
           let url = URL(string: override) {
            return url
        }
        return URL(string: "https://azcode.dev")!
    }

    init() {
        let defaults = UserDefaults.standard
        self.email = defaults.string(forKey: Self.emailDefaultsKey) ?? ""
        self.name = defaults.string(forKey: Self.nameDefaultsKey) ?? ""
        self.licenseKey = defaults.string(forKey: Self.keyDefaultsKey) ?? ""
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
             body: ["email": email, "license_key": key, "device_serial": serial,
                    "app_version": Self.appVersion]) { [weak self] result in
            guard let self else { return }
            self.isBusy = false
            switch result {
            case .success(let json):
                self.setState(registered: true, email: email, key: key,
                              name: json["name"] as? String ?? "")
                NSLog("Ampere: Registered to %@", email)
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
                NSLog("Ampere: Deregistered")
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
                    "app_version": Self.appVersion]) { [weak self] result in
            guard let self else { return }
            if case .success(let json) = result,
               let valid = json["valid"] as? Bool {
                if !valid {
                    NSLog("Ampere: Registration no longer valid, switching to unregistered")
                    self.setState(registered: false)
                    self.lastError = "Registration is no longer valid for this Mac"
                } else if let license = json["license"] as? [String: Any],
                          let name = license["name"] as? String, name != self.name {
                    // Keep the licensee name in sync with the server — it can
                    // be filled in or corrected after the initial registration.
                    self.setState(registered: true, name: name)
                }
            }
        }
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
    /// kept on deregistration so the form can prefill for a later re-register.
    private func setState(registered: Bool, email: String? = nil, key: String? = nil,
                          name: String? = nil) {
        let defaults = UserDefaults.standard
        if let email { self.email = email; defaults.set(email, forKey: Self.emailDefaultsKey) }
        if let name { self.name = name; defaults.set(name, forKey: Self.nameDefaultsKey) }
        if let key { self.licenseKey = key; defaults.set(key, forKey: Self.keyDefaultsKey) }
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
        var request = URLRequest(url: Self.baseURL.appendingPathComponent(path))
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
