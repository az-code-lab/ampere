import XCTest
@testable import Ampere

/// The registration client against a license server of the test's own. A
/// URLProtocol stub answers every call to license.test, an address that
/// exists nowhere, so a call the stub missed fails instead of reaching the
/// real server; a scratch defaults suite stands in for the app's preferences,
/// and the serial is made up. Pinned here: how many Macs the key registers is
/// read from the server's answers and survives a relaunch, the window's words
/// follow it, a full key's refusal reaches the user in the server's words, a
/// registration a verify ended keeps saying why until the next attempt, and
/// register names the product so another app's key is never bound.
final class RegistrationTests: XCTestCase {

    private static let serial = "C02TEST12345"
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ampere.tests.registration.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.set("https://license.test", forKey: "registration.serverURL")
        LicenseServerStub.reset()
        URLProtocol.registerClass(LicenseServerStub.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(LicenseServerStub.self)
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: Reading the server's answers

    func testLicenseFacts_ReadTheKeysMacCount() throws {
        XCTAssertEqual(try facts(#"{"license_key":"AMP-A","product":"ampere","email":"ada@example.com","name":"Ada","max_devices":5}"#),
                       LicenseFacts(name: "Ada", maxDevices: 5))
        XCTAssertEqual(try facts(#"{"name":"Ada","max_devices":1}"#).maxDevices, 1)
        // A server that says nothing, or nonsense, means one: the way the
        // server itself reads an unsaid count.
        for unsaid in [#"{"name":"Ada"}"#, #"{"max_devices":0}"#, #"{"max_devices":-2}"#, #"{"max_devices":"5"}"#, #"{"max_devices":null}"#] {
            XCTAssertEqual(try facts(unsaid).maxDevices, 1, unsaid)
        }
        XCTAssertNil(try facts(#"{"max_devices":5}"#).name)
    }

    // MARK: The window's words

    func testExplanation_FollowsTheKeysRoom() {
        let one = RegistrationManager.explanation(macs: 1)
        XCTAssertTrue(one.contains("one Mac at a time"), one)
        XCTAssertTrue(one.contains("the key moves there"), one)
        XCTAssertFalse(one.contains("My Licenses"), one)

        let five = RegistrationManager.explanation(macs: 5)
        XCTAssertTrue(five.contains("up to 5 Macs at once"), five)
        XCTAssertTrue(five.contains("refused until you make room"), five)
        XCTAssertTrue(five.contains("My Licenses at azcode.dev"), five)
        XCTAssertFalse(five.contains("moves there"), five)

        // No count yet: only what holds for every key, neither kind's rules.
        let unknown = RegistrationManager.explanation(macs: nil)
        XCTAssertTrue(unknown.contains("takes this Mac off the key"), unknown)
        for claim in ["one Mac", "Macs at once", "moves there", "refused"] {
            XCTAssertFalse(unknown.contains(claim), unknown)
        }
    }

    /// Existing users: a registration made by a build that kept no count
    /// stays registered through the update, says nothing about Macs until
    /// the server has said, and then keeps the key's own count.
    func testARegistrationFromAnEarlierBuild_WaitsForTheServersCount() {
        defaults.set(true, forKey: "registration.active")
        defaults.set("ada@example.com", forKey: "registration.email")
        defaults.set("Ada Lovelace", forKey: "registration.name")
        defaults.set("AMP-AAAAA-BBBBB", forKey: "registration.licenseKey")
        let registration = RegistrationManager(defaults: defaults, deviceSerial: Self.serial)
        XCTAssertTrue(registration.isRegistered)
        XCTAssertEqual(registration.email, "ada@example.com")
        XCTAssertEqual(registration.licenseKey, "AMP-AAAAA-BBBBB")
        XCTAssertNil(registration.maxDevices, "an earlier build kept no count, and none is guessed")

        LicenseServerStub.answer = { _ in (200, #"{"valid":true,"license":{"product":"ampere","email":"ada@example.com","name":"Ada Lovelace","max_devices":5}}"#) }
        registration.verify()
        waitUntil(registration.maxDevices != nil)
        XCTAssertEqual(registration.maxDevices, 5)
        XCTAssertTrue(registration.isRegistered)
        XCTAssertEqual(registration.name, "Ada Lovelace")
        XCTAssertEqual(RegistrationManager(defaults: defaults, deviceSerial: Self.serial).maxDevices, 5)
    }

    // MARK: Register and verify

    func testRegister_KeepsTheKeysMacCount_AcrossARelaunch() {
        LicenseServerStub.answer = { _ in
            (200, #"{"license_key":"AMP-AAAAA-BBBBB","product":"ampere","email":"ada@example.com","name":"Ada Lovelace","device_serial":"C02TEST12345","max_devices":5,"status":"active"}"#)
        }
        let registration = RegistrationManager(defaults: defaults, deviceSerial: Self.serial)
        XCTAssertNil(registration.maxDevices, "a copy the server has said nothing to knows no count")

        XCTAssertTrue(register(registration, email: "  Ada@Example.com ", key: " amp-aaaaa-bbbbb "))
        XCTAssertTrue(registration.isRegistered)
        XCTAssertNil(registration.lastError)
        XCTAssertEqual(registration.name, "Ada Lovelace")
        XCTAssertEqual(registration.maxDevices, 5, "the key's room, as the server said it")

        // What the server was sent: the pair, this Mac, and the app the key
        // must be for, so another app's key answers "Invalid license key".
        let call = LicenseServerStub.calls.last
        XCTAssertEqual(call?.path, "/api/pub/license/register")
        XCTAssertEqual(call?.body["email"] as? String, "ada@example.com")
        XCTAssertEqual(call?.body["license_key"] as? String, "AMP-AAAAA-BBBBB")
        XCTAssertEqual(call?.body["device_serial"] as? String, Self.serial)
        XCTAssertEqual(call?.body["product"] as? String, "ampere")

        // A relaunch restores the count with the rest of the registration,
        // before any verify has run.
        let relaunched = RegistrationManager(defaults: defaults, deviceSerial: Self.serial)
        XCTAssertTrue(relaunched.isRegistered)
        XCTAssertEqual(relaunched.maxDevices, 5)
        XCTAssertEqual(relaunched.name, "Ada Lovelace")
    }

    func testRegister_AFullKeysRefusalIsShownInTheServersWords() {
        let full = "This license key is already registered on 5 Macs, all it allows. Deregister one of them in the app, or release one under My Licenses at azcode.dev, and try again."
        LicenseServerStub.answer = { _ in (403, "\"\(full)\"") }
        let registration = RegistrationManager(defaults: defaults, deviceSerial: Self.serial)

        XCTAssertFalse(register(registration, email: "ada@example.com", key: "AMP-A"))
        XCTAssertFalse(registration.isRegistered)
        XCTAssertEqual(registration.lastError, full)
        XCTAssertFalse(RegistrationManager(defaults: defaults, deviceSerial: Self.serial).isRegistered,
                       "a refusal leaves nothing registered for the next launch")
    }

    func testVerify_FollowsTheServersCount_AndALapseSaysWhy() {
        LicenseServerStub.answer = { _ in (200, #"{"product":"ampere","email":"ada@example.com","name":"Ada","max_devices":1}"#) }
        let registration = RegistrationManager(defaults: defaults, deviceSerial: Self.serial)
        XCTAssertTrue(register(registration, email: "ada@example.com", key: "AMP-A"))
        XCTAssertEqual(registration.maxDevices, 1)

        // An admin gave the key room for more Macs, and renamed it: the next
        // check brings both, and a relaunch keeps them.
        LicenseServerStub.answer = { _ in (200, #"{"valid":true,"license":{"product":"ampere","email":"ada@example.com","name":"Ada King","max_devices":5}}"#) }
        registration.verify()
        waitUntil(registration.maxDevices == 5)
        XCTAssertEqual(registration.maxDevices, 5)
        XCTAssertEqual(registration.name, "Ada King")
        XCTAssertTrue(registration.isRegistered)
        let call = LicenseServerStub.calls.last
        XCTAssertEqual(call?.path, "/api/pub/license/verify")
        XCTAssertNil(call?.body["license_key"], "the key itself is never sent again")
        XCTAssertEqual(call?.body["product"] as? String, "ampere")
        XCTAssertEqual(RegistrationManager(defaults: defaults, deviceSerial: Self.serial).maxDevices, 5)

        // This Mac was released from the key (or the license ended): the
        // copy goes back to unregistered and says every way that happens.
        LicenseServerStub.answer = { _ in (200, #"{"valid":false}"#) }
        registration.verify()
        waitUntil(!registration.isRegistered)
        XCTAssertFalse(registration.isRegistered)
        XCTAssertEqual(registration.lastError, RegistrationManager.lapsedMessage)
        XCTAssertTrue(RegistrationManager.lapsedMessage.contains("released"))
        XCTAssertTrue(RegistrationManager.lapsedMessage.contains("another Mac took its place"))
        XCTAssertFalse(RegistrationManager(defaults: defaults, deviceSerial: Self.serial).isRegistered)

        // The window opening later still says why; the next attempt clears it.
        registration.clearStaleError()
        XCTAssertEqual(registration.lastError, RegistrationManager.lapsedMessage)
        LicenseServerStub.answer = { _ in (200, #"{"product":"ampere","email":"ada@example.com","name":"Ada","max_devices":5}"#) }
        XCTAssertTrue(register(registration, email: "ada@example.com", key: "AMP-A"))
        XCTAssertNil(registration.lastError)
        XCTAssertEqual(registration.maxDevices, 5)
    }

    func testClearStaleError_DropsAFormErrorButKeepsWhyARegistrationEnded() {
        let registration = RegistrationManager(defaults: defaults, deviceSerial: Self.serial)
        registration.lastError = "Invalid license key"
        registration.clearStaleError()
        XCTAssertNil(registration.lastError, "an earlier attempt's error does not greet the next opening")
        registration.lastError = RegistrationManager.lapsedMessage
        registration.clearStaleError()
        XCTAssertEqual(registration.lastError, RegistrationManager.lapsedMessage)
    }

    // MARK: Helpers

    private func facts(_ json: String) throws -> LicenseFacts {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return LicenseFacts(license: try XCTUnwrap(object as? [String: Any]))
    }

    /// Registers and waits for the answer, which arrives on the main queue.
    private func register(_ registration: RegistrationManager, email: String, key: String) -> Bool {
        let answered = expectation(description: "register answered")
        var result = false
        registration.register(email: email, key: key) { registered in
            result = registered
            answered.fulfill()
        }
        wait(for: [answered], timeout: 5)
        return result
    }

    /// Verify has no completion: its answer lands on the main queue and
    /// shows only in the published state, so the run loop turns until it does.
    private func waitUntil(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }
}

/// Answers the registration client in-process, for calls to license.test
/// only. Each call is recorded with its JSON body.
final class LicenseServerStub: URLProtocol {
    struct Call {
        let path: String
        let body: [String: Any]
    }

    private static let lock = NSLock()
    private static var _answer: (String) -> (Int, String) = { _ in (500, #""No answer was set""#) }
    private static var _calls: [Call] = []

    static var answer: (String) -> (Int, String) {
        get { lock.withLock { _answer } }
        set { lock.withLock { _answer = newValue } }
    }

    static var calls: [Call] { lock.withLock { _calls } }

    static func reset() {
        lock.withLock {
            _answer = { _ in (500, #""No answer was set""#) }
            _calls = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "license.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let body = Self.bodyData(of: request)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        Self.lock.withLock { Self._calls.append(Call(path: url.path, body: body)) }
        let (status, text) = Self.answer(url.path)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession hands a protocol the body as a stream, not as httpBody.
    private static func bodyData(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
