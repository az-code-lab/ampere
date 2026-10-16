import XCTest
import Combine
@testable import Ampere

/// The registration client against a license server of the test's own. A
/// URLProtocol stub answers every call to license.test, an address that
/// exists nowhere, so a call the stub missed fails instead of reaching the
/// real server; a scratch defaults suite stands in for the app's preferences,
/// and the serial is made up. Pinned here: how many Macs the key registers,
/// and how many it is in use on, are read from the server's answers and
/// survive a relaunch; the window's words follow them, and opening the window
/// checks the registration so the Macs in use are current; a verify answer
/// that lands after this copy deregistered changes nothing, even once it has
/// registered again to the same email; a full key's
/// refusal reaches the user in the server's words; a registration a verify
/// ended keeps saying why until the next attempt; and register names the
/// product so another app's key is never bound.
final class RegistrationTests: XCTestCase {

    private static let serial = "C02TEST12345"
    private var folder: URL!
    private var defaults: UserDefaults!

    /// The test's preferences live in a folder of their own under the
    /// temporary directory, removed after the test. A suite named by a path
    /// keeps its file at that path; a plain suite name would land in
    /// ~/Library/Preferences, where the preferences daemon writes an emptied
    /// domain back after `removePersistentDomain`, so every run would leave
    /// files there for good (DBClient's ScratchPreferences, which this
    /// follows, found 3,000 of them).
    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ampere-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: folder.appendingPathComponent("registration").path)
        defaults.set("https://license.test", forKey: "registration.serverURL")
        LicenseServerStub.reset()
        URLProtocol.registerClass(LicenseServerStub.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(LicenseServerStub.self)
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    // MARK: Reading the server's answers

    func testLicenseFacts_ReadTheKeysMacCounts() throws {
        XCTAssertEqual(try facts(#"{"license_key":"AMP-A","product":"ampere","email":"ada@example.com","name":"Ada","max_devices":5,"device_count":2}"#),
                       LicenseFacts(name: "Ada", maxDevices: 5, deviceCount: 2))
        XCTAssertEqual(try facts(#"{"name":"Ada","max_devices":1}"#).maxDevices, 1)
        // A server that says nothing, or nonsense, means one: the way the
        // server itself reads an unsaid count.
        for unsaid in [#"{"name":"Ada"}"#, #"{"max_devices":0}"#, #"{"max_devices":-2}"#, #"{"max_devices":"5"}"#, #"{"max_devices":null}"#] {
            XCTAssertEqual(try facts(unsaid).maxDevices, 1, unsaid)
        }
        XCTAssertNil(try facts(#"{"max_devices":5}"#).name)
        // How many Macs the key is in use on is never guessed: a server that
        // does not say (one from before the count was sent), or says
        // nonsense, leaves it unknown.
        for unsaid in [#"{"max_devices":5}"#, #"{"device_count":0}"#, #"{"device_count":-1}"#, #"{"device_count":"2"}"#, #"{"device_count":null}"#] {
            XCTAssertNil(try facts(unsaid).deviceCount, unsaid)
        }
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

    func testUsage_SaysTheMacsInUseOutOfTheKeysRoom() {
        XCTAssertEqual(RegistrationManager.usage(macs: 2, of: 5), "Macs in use: 2 of 5")
        XCTAssertEqual(RegistrationManager.usage(macs: 5, of: 5), "Macs in use: 5 of 5")
        XCTAssertNil(RegistrationManager.usage(macs: 1, of: 1), "a one-Mac key is only ever in use on this Mac")
        XCTAssertNil(RegistrationManager.usage(macs: nil, of: 5), "no line while the server has not said")
        XCTAssertNil(RegistrationManager.usage(macs: 2, of: nil))
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
            (200, #"{"license_key":"AMP-AAAAA-BBBBB","product":"ampere","email":"ada@example.com","name":"Ada Lovelace","device_serial":"C02TEST12345","max_devices":5,"device_count":2,"status":"active"}"#)
        }
        let registration = RegistrationManager(defaults: defaults, deviceSerial: Self.serial)
        XCTAssertNil(registration.maxDevices, "a copy the server has said nothing to knows no count")
        XCTAssertNil(registration.deviceCount)

        XCTAssertTrue(register(registration, email: "  Ada@Example.com ", key: " amp-aaaaa-bbbbb "))
        XCTAssertTrue(registration.isRegistered)
        XCTAssertNil(registration.lastError)
        XCTAssertEqual(registration.name, "Ada Lovelace")
        XCTAssertEqual(registration.maxDevices, 5, "the key's room, as the server said it")
        XCTAssertEqual(registration.deviceCount, 2, "the Macs in use, this one included, as the server counted them")

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
        XCTAssertEqual(relaunched.deviceCount, 2)
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

    func testVerify_FollowsTheServersCounts_AndALapseSaysWhy() {
        LicenseServerStub.answer = { _ in (200, #"{"product":"ampere","email":"ada@example.com","name":"Ada","max_devices":1,"device_count":1}"#) }
        let registration = RegistrationManager(defaults: defaults, deviceSerial: Self.serial)
        XCTAssertTrue(register(registration, email: "ada@example.com", key: "AMP-A"))
        XCTAssertEqual(registration.maxDevices, 1)
        XCTAssertEqual(registration.deviceCount, 1)

        // An admin gave the key room for more Macs and renamed it, and two
        // more Macs joined: the next check brings all of it, and a relaunch
        // keeps it.
        LicenseServerStub.answer = { _ in (200, #"{"valid":true,"license":{"product":"ampere","email":"ada@example.com","name":"Ada King","max_devices":5,"device_count":3}}"#) }
        registration.verify()
        waitUntil(registration.maxDevices == 5)
        XCTAssertEqual(registration.maxDevices, 5)
        XCTAssertEqual(registration.deviceCount, 3)
        XCTAssertEqual(registration.name, "Ada King")
        XCTAssertTrue(registration.isRegistered)
        let call = LicenseServerStub.calls.last
        XCTAssertEqual(call?.path, "/api/pub/license/verify")
        XCTAssertNil(call?.body["license_key"], "the key itself is never sent again")
        XCTAssertEqual(call?.body["product"] as? String, "ampere")
        let relaunched = RegistrationManager(defaults: defaults, deviceSerial: Self.serial)
        XCTAssertEqual(relaunched.maxDevices, 5)
        XCTAssertEqual(relaunched.deviceCount, 3)

        // This Mac was released from the key (or the license ended): the
        // copy goes back to unregistered, says every way that happens, and
        // keeps no count of Macs it is no longer one of.
        LicenseServerStub.answer = { _ in (200, #"{"valid":false}"#) }
        registration.verify()
        waitUntil(!registration.isRegistered)
        XCTAssertFalse(registration.isRegistered)
        XCTAssertNil(registration.deviceCount)
        XCTAssertEqual(registration.lastError, RegistrationManager.lapsedMessage)
        XCTAssertTrue(RegistrationManager.lapsedMessage.contains("released"))
        XCTAssertTrue(RegistrationManager.lapsedMessage.contains("another Mac took its place"))
        XCTAssertFalse(RegistrationManager(defaults: defaults, deviceSerial: Self.serial).isRegistered)
        XCTAssertNil(RegistrationManager(defaults: defaults, deviceSerial: Self.serial).deviceCount)

        // The window opening later still says why, and an unregistered copy
        // asks the server nothing; the next attempt clears the reason.
        let asked = LicenseServerStub.calls.count
        registration.windowOpened()
        XCTAssertEqual(registration.lastError, RegistrationManager.lapsedMessage)
        XCTAssertEqual(LicenseServerStub.calls.count, asked, "an unregistered copy never contacts the license server")
        LicenseServerStub.answer = { _ in (200, #"{"product":"ampere","email":"ada@example.com","name":"Ada","max_devices":5,"device_count":2}"#) }
        XCTAssertTrue(register(registration, email: "ada@example.com", key: "AMP-A"))
        XCTAssertNil(registration.lastError)
        XCTAssertEqual(registration.maxDevices, 5)
        XCTAssertEqual(registration.deviceCount, 2)
    }

    func testWindowOpened_DropsAFormErrorButKeepsWhyARegistrationEnded() {
        let registration = RegistrationManager(defaults: defaults, deviceSerial: Self.serial)
        registration.lastError = "Invalid license key"
        registration.windowOpened()
        XCTAssertNil(registration.lastError, "an earlier attempt's error does not greet the next opening")
        registration.lastError = RegistrationManager.lapsedMessage
        registration.windowOpened()
        XCTAssertEqual(registration.lastError, RegistrationManager.lapsedMessage)
        XCTAssertTrue(LicenseServerStub.calls.isEmpty, "an unregistered copy asks nothing when the window opens")
    }

    /// Opening the window asks the server for the registration as it stands,
    /// so a Mac that joined the key since the last check is counted at once.
    func testWindowOpened_ChecksTheRegistrationSoTheMacsInUseAreCurrent() {
        LicenseServerStub.answer = { _ in (200, #"{"product":"ampere","email":"ada@example.com","name":"Ada","max_devices":5,"device_count":1}"#) }
        let registration = RegistrationManager(defaults: defaults, deviceSerial: Self.serial)
        XCTAssertTrue(register(registration, email: "ada@example.com", key: "AMP-A"))
        XCTAssertEqual(RegistrationManager.usage(macs: registration.deviceCount, of: registration.maxDevices), "Macs in use: 1 of 5")

        LicenseServerStub.answer = { _ in (200, #"{"valid":true,"license":{"product":"ampere","email":"ada@example.com","name":"Ada","max_devices":5,"device_count":2}}"#) }
        registration.windowOpened()
        waitUntil(registration.deviceCount == 2)
        XCTAssertEqual(LicenseServerStub.calls.last?.path, "/api/pub/license/verify")
        XCTAssertEqual(RegistrationManager.usage(macs: registration.deviceCount, of: registration.maxDevices), "Macs in use: 2 of 5")
        XCTAssertTrue(registration.isRegistered)
    }

    /// Deregister clicked while the window's own check is still on the wire:
    /// its answer speaks of a registration this copy no longer holds, so it
    /// changes nothing. Without the guard, a late "valid" would mark the copy
    /// registered again.
    func testAVerifyAnswerForARegistrationThatEnded_ChangesNothing() {
        LicenseServerStub.answer = { path in
            path.hasSuffix("/deregister")
                ? (200, #""License deregistered""#)
                : (200, #"{"product":"ampere","email":"ada@example.com","name":"Ada","max_devices":5,"device_count":2}"#)
        }
        let registration = RegistrationManager(defaults: defaults, deviceSerial: Self.serial)
        XCTAssertTrue(register(registration, email: "ada@example.com", key: "AMP-A"))
        // What a check sent now would carry back with its answer.
        let asked = registration.registrationGeneration
        let deregistered = expectation(description: "deregistered")
        registration.deregister { _ in deregistered.fulfill() }
        wait(for: [deregistered], timeout: 5)
        XCTAssertFalse(registration.isRegistered)
        XCTAssertNil(registration.deviceCount, "a Mac off the key keeps no count of the key's Macs")

        let lateValid: [String: Any] = ["valid": true, "license": ["name": "Ada", "max_devices": 5, "device_count": 3]]
        registration.applyVerification(lateValid, askedUnder: asked)
        XCTAssertFalse(registration.isRegistered, "a late yes does not register a deregistered copy again")
        XCTAssertNil(registration.deviceCount)
        registration.applyVerification(["valid": false], askedUnder: asked)
        XCTAssertNil(registration.lastError, "a deliberate deregistration is not reported as a lapse")
        XCTAssertFalse(RegistrationManager(defaults: defaults, deviceSerial: Self.serial).isRegistered)

        // Registered again, to another address: an answer asked under the
        // old registration still changes nothing.
        XCTAssertTrue(register(registration, email: "bob@example.com", key: "AMP-B"))
        registration.applyVerification(lateValid, askedUnder: asked)
        XCTAssertEqual(registration.deviceCount, 2, "the count stays the one this registration's own answer gave")
    }

    /// Deregistered and registered again to the same email while a check of
    /// the first registration was still on the wire, and the server answered
    /// it after the deregistration: "not valid" is true of the registration
    /// it was asked about and false of the one this copy now holds. Taken for
    /// the new one, it would end it, report a lapse, and (through the bounds
    /// lock) reset the charge bounds. The registration's own check still
    /// ends it, and a check that only refreshes the key's facts does not
    /// invalidate another in flight.
    func testAStaleNotValidCannotEndARegistrationMadeAgainToTheSameEmail() {
        LicenseServerStub.answer = { path in
            path.hasSuffix("/deregister")
                ? (200, #""License deregistered""#)
                : (200, #"{"product":"ampere","email":"ada@example.com","name":"Ada","max_devices":5,"device_count":1}"#)
        }
        let registration = RegistrationManager(defaults: defaults, deviceSerial: Self.serial)
        XCTAssertTrue(register(registration, email: "ada@example.com", key: "AMP-A"))
        let asked = registration.registrationGeneration
        let deregistered = expectation(description: "deregistered")
        registration.deregister { _ in deregistered.fulfill() }
        wait(for: [deregistered], timeout: 5)
        XCTAssertTrue(register(registration, email: "ada@example.com", key: "AMP-A"))
        XCTAssertNotEqual(registration.registrationGeneration, asked)

        registration.applyVerification(["valid": false], askedUnder: asked)
        XCTAssertTrue(registration.isRegistered, "the answer is about the registration that ended, not this one")
        XCTAssertNil(registration.lastError)
        XCTAssertTrue(RegistrationManager(defaults: defaults, deviceSerial: Self.serial).isRegistered)

        let current = registration.registrationGeneration
        registration.applyVerification(["valid": true, "license": ["name": "Ada B.", "max_devices": 5, "device_count": 2]],
                                       askedUnder: current)
        XCTAssertEqual(registration.name, "Ada B.")
        XCTAssertEqual(registration.registrationGeneration, current, "refreshing the key's facts is not a new registration")

        registration.applyVerification(["valid": false], askedUnder: current)
        XCTAssertFalse(registration.isRegistered, "the current registration's own check still ends it")
        XCTAssertEqual(registration.lastError, RegistrationManager.lapsedMessage)
    }

    // MARK: The free license (the owner's call, 2026-10-16)

    /// The server says which kind a key is with every answer (`is_trial`,
    /// the field DBClient's trial travels under). Unsaid, or nonsense, means
    /// bought: a paid registration can never be read as a free one.
    func testLicenseFacts_ReadWhetherTheKeyIsFree() throws {
        XCTAssertTrue(try facts(#"{"name":"Ada","max_devices":1,"is_trial":true}"#).isFree)
        XCTAssertFalse(try facts(#"{"name":"Ada","max_devices":5,"is_trial":false}"#).isFree)
        for unsaid in [#"{"name":"Ada","max_devices":5}"#, #"{"is_trial":null}"#, #"{"is_trial":"yes"}"#] {
            XCTAssertFalse(try facts(unsaid).isFree, unsaid)
        }
    }

    func testTier_FollowsTheRegistrationAndTheKind() {
        XCTAssertEqual(RegistrationManager.tier(registered: false, free: false), .unlicensed)
        XCTAssertEqual(RegistrationManager.tier(registered: false, free: true), .unlicensed,
                       "a free key the copy is not registered to allows nothing")
        XCTAssertEqual(RegistrationManager.tier(registered: true, free: true), .free)
        XCTAssertEqual(RegistrationManager.tier(registered: true, free: false), .paid)
    }

    /// Existing paid users: a registration made by a build from before the
    /// free license stored no kind. It is a paid one, since every key before
    /// then was bought, so the update locks nothing: not the bounds, not
    /// Keep Awake. The first verify after the update says so too, and a
    /// server that says nothing of the kind leaves it paid.
    func testARegistrationFromAnEarlierBuild_IsAPaidOne() {
        defaults.set(true, forKey: "registration.active")
        defaults.set("ada@example.com", forKey: "registration.email")
        defaults.set("AMP-AAAAA-BBBBB", forKey: "registration.licenseKey")
        let registration = RegistrationManager(defaults: defaults, deviceSerial: Self.serial)
        XCTAssertTrue(registration.isRegistered)
        XCTAssertFalse(registration.isFree)
        XCTAssertEqual(registration.tier, .paid)

        var tiers: [LicenseTier] = []
        let subscription = registration.tierPublisher.sink { tiers.append($0) }
        defer { subscription.cancel() }
        waitUntil(!tiers.isEmpty)
        XCTAssertEqual(tiers, [.paid], "the publisher opens with the tier in force")

        LicenseServerStub.answer = { _ in (200, #"{"valid":true,"license":{"product":"ampere","email":"ada@example.com","name":"Ada","max_devices":5,"device_count":1,"is_trial":false}}"#) }
        registration.verify()
        waitUntil(registration.maxDevices == 5)
        XCTAssertEqual(registration.tier, .paid)
        LicenseServerStub.answer = { _ in (200, #"{"valid":true,"license":{"product":"ampere","email":"ada@example.com","name":"Ada King","max_devices":5}}"#) }
        registration.verify()
        waitUntil(registration.name == "Ada King")
        XCTAssertEqual(registration.tier, .paid, "a server that says nothing of the kind leaves a paid key paid")
        waitUntil(false, timeout: 0.2)
        XCTAssertEqual(tiers, [.paid], "nothing of this moved the tier")
        XCTAssertEqual(RegistrationManager(defaults: defaults, deviceSerial: Self.serial).tier, .paid)
    }

    /// The free license, end to end: asked for with a name and an address,
    /// the key comes by mail and never in the answer; entered, it registers
    /// through the ordinary register call and the copy is on the free tier;
    /// the daily check that ends it says so in the free license's words.
    func testRequestFreeLicense_MailsTheKey_AndTheKeyRegistersTheFreeTier() {
        LicenseServerStub.answer = { path in
            path.hasSuffix("/trial")
                ? (200, #"{"product":"ampere","email":"ada@example.com","name":"Ada Lovelace","device_serial":"C02TEST12345","max_devices":1,"device_count":0,"is_trial":true,"status":"available"}"#)
                : (200, #"{"license_key":"AMP-FREE1-00001","product":"ampere","email":"ada@example.com","name":"Ada Lovelace","device_serial":"C02TEST12345","max_devices":1,"device_count":1,"is_trial":true,"status":"active"}"#)
        }
        let registration = RegistrationManager(defaults: defaults, deviceSerial: Self.serial)
        var tiers: [LicenseTier] = []
        // Each tier must arrive once the registration's own properties agree
        // with it: a subscriber that saw them mid-change would act, and let
        // the window draw, the old state (see tierPublisher).
        var deliveredMidChange = false
        let subscription = registration.tierPublisher.sink { tier in
            tiers.append(tier)
            if registration.tier != tier { deliveredMidChange = true }
        }
        defer { subscription.cancel() }

        // A form with nothing of the free license's in it asks nothing.
        XCTAssertFalse(requestFreeLicense(registration, name: "  ", email: "ada@example.com"))
        XCTAssertEqual(registration.lastError, "Enter your name and the email address the free license should be issued to")
        XCTAssertTrue(LicenseServerStub.calls.isEmpty)

        XCTAssertTrue(requestFreeLicense(registration, name: " Ada Lovelace ", email: " Ada@Example.com "))
        XCTAssertFalse(registration.isRegistered, "the key is in the mail, not in the answer")
        XCTAssertTrue(registration.isFree)
        XCTAssertEqual(registration.licenseKey, "")
        XCTAssertEqual(registration.email, "ada@example.com")
        XCTAssertEqual(registration.name, "Ada Lovelace")
        XCTAssertNil(registration.lastError)
        XCTAssertEqual(registration.tier, .unlicensed)
        let asked = LicenseServerStub.calls.last
        XCTAssertEqual(asked?.path, "/api/pub/license/trial")
        XCTAssertEqual(asked?.body["name"] as? String, "Ada Lovelace")
        XCTAssertEqual(asked?.body["email"] as? String, "ada@example.com")
        XCTAssertEqual(asked?.body["device_serial"] as? String, Self.serial)
        XCTAssertEqual(asked?.body["product"] as? String, "ampere")
        XCTAssertNotNil(asked?.body["app_version"], "the version says this build takes the key from its mailbox")
        XCTAssertEqual(asked?.body.count, 5, "and nothing more goes along")
        // What the window says meanwhile, and after a launch.
        XCTAssertTrue(RegistrationManager.pendingFreeKeyMessage(email: registration.email).contains("emailed to ada@example.com"))
        let waiting = RegistrationManager(defaults: defaults, deviceSerial: Self.serial)
        XCTAssertTrue(waiting.isFree && !waiting.isRegistered && waiting.licenseKey.isEmpty)

        // The key, entered from the mail, registers like any key.
        XCTAssertTrue(register(registration, email: "ada@example.com", key: "amp-free1-00001"))
        XCTAssertTrue(registration.isRegistered)
        XCTAssertTrue(registration.isFree)
        XCTAssertEqual(registration.tier, .free)
        XCTAssertEqual(registration.maxDevices, 1)
        XCTAssertEqual(LicenseServerStub.calls.last?.path, "/api/pub/license/register")
        XCTAssertEqual(LicenseServerStub.calls.last?.body["license_key"] as? String, "AMP-FREE1-00001")
        XCTAssertEqual(RegistrationManager(defaults: defaults, deviceSerial: Self.serial).tier, .free, "kept for the next launch")

        // Off the key (released, or this Mac deregistered elsewhere): the
        // check ends it in the free license's words, the key stays in the
        // form, and the window keeps saying why until the next attempt.
        LicenseServerStub.answer = { _ in (200, #"{"valid":false}"#) }
        registration.verify()
        waitUntil(!registration.isRegistered)
        XCTAssertEqual(registration.tier, .unlicensed)
        XCTAssertTrue(registration.isFree)
        XCTAssertEqual(registration.licenseKey, "AMP-FREE1-00001")
        XCTAssertEqual(registration.lastError, RegistrationManager.freeLapsedMessage)
        registration.windowOpened()
        XCTAssertEqual(registration.lastError, RegistrationManager.freeLapsedMessage)
        waitUntil(tiers.count == 3)
        XCTAssertEqual(tiers, [.unlicensed, .free, .unlicensed], "each change once: the publisher drops repeats")
        XCTAssertFalse(deliveredMidChange, "every tier arrived after the registration had changed, never during")
    }

    /// A refusal — the address or this Mac already had one, a mail that
    /// could not go — reaches the user in the server's words and changes
    /// nothing. A paid key registered afterwards is a paid registration:
    /// the kind follows the key, not the request that came before.
    func testRequestFreeLicense_ARefusalIsShownInTheServersWords_AndAPaidKeyIsPaid() {
        let refused = "A free license was already issued to this email address."
        LicenseServerStub.answer = { path in
            path.hasSuffix("/trial")
                ? (403, "\"\(refused)\"")
                : (200, #"{"license_key":"AMP-PAID1-00001","product":"ampere","email":"ada@example.com","name":"Ada","max_devices":5,"device_count":1,"is_trial":false}"#)
        }
        let registration = RegistrationManager(defaults: defaults, deviceSerial: Self.serial)
        XCTAssertFalse(requestFreeLicense(registration, name: "Ada", email: "ada@example.com"))
        XCTAssertEqual(registration.lastError, refused)
        XCTAssertFalse(registration.isFree)
        XCTAssertFalse(registration.isRegistered)

        XCTAssertTrue(register(registration, email: "ada@example.com", key: "AMP-PAID1-00001"))
        XCTAssertEqual(registration.tier, .paid)
        XCTAssertNil(registration.lastError)
    }

    // MARK: Helpers

    /// Asks for a free license and waits for the answer, which arrives on
    /// the main queue.
    private func requestFreeLicense(_ registration: RegistrationManager, name: String, email: String) -> Bool {
        let answered = expectation(description: "free license answered")
        var result = false
        registration.requestFreeLicense(name: name, email: email) { mailed in
            result = mailed
            answered.fulfill()
        }
        wait(for: [answered], timeout: 5)
        return result
    }

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
