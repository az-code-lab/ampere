import XCTest
@testable import Ampere

/// The Temperature card starts in the unit macOS is set to and keeps the
/// unit a click chose. These pin that rule and the card's text. The locales
/// stand in for a Mac's Language & Region settings, which a test must not
/// change: a region gives its own unit, and the `mu` keyword is how a
/// locale identifier spells the Temperature setting when it differs.
final class TemperatureDisplayTests: XCTestCase {

    // MARK: Never clicked

    func testNeverClicked_ShowsTheRegionsUnit() {
        XCTAssertTrue(TemperatureDisplay.usesFahrenheit(stored: nil, locale: Locale(identifier: "en_US")))
        for region in ["en_GB", "en_CA", "en_AU", "de_DE", "fr_FR", "ja_JP", "zh_CN"] {
            XCTAssertFalse(TemperatureDisplay.usesFahrenheit(stored: nil, locale: Locale(identifier: region)), region)
        }
    }

    /// The Temperature setting is separate from the region: a Mac in the
    /// United States can be set to Celsius, and one in Germany to Fahrenheit.
    func testNeverClicked_TheTemperatureSettingWinsOverTheRegion() {
        XCTAssertFalse(TemperatureDisplay.usesFahrenheit(stored: nil, locale: Locale(identifier: "en_US@mu=celsius")))
        XCTAssertTrue(TemperatureDisplay.usesFahrenheit(stored: nil, locale: Locale(identifier: "de_DE@mu=fahrenhe")))
    }

    /// Left to its default, the rule asks this Mac, whichever unit that is:
    /// a fixed locale in its place would bring back one unit for everyone.
    func testNeverClicked_AsksThisMacByDefault() {
        XCTAssertEqual(TemperatureDisplay.usesFahrenheit(stored: nil),
                       UnitTemperature(forLocale: .current) == .fahrenheit)
    }

    /// The sensor reports Celsius, so that is what a unit the card cannot
    /// show falls back to.
    func testNeverClicked_AUnitTheCardCannotShowReadsAsCelsius() {
        XCTAssertFalse(TemperatureDisplay.usesFahrenheit(stored: nil, locale: Locale(identifier: "en_US@mu=kelvin")))
    }

    // MARK: Clicked

    /// A click's choice is what a relaunch shows, whatever macOS is set to
    /// by then.
    func testClicked_TheStoredChoiceWinsOverTheSystemUnit() {
        for system in ["en_US", "de_DE", "en_US@mu=celsius", "de_DE@mu=fahrenhe"] {
            let locale = Locale(identifier: system)
            XCTAssertTrue(TemperatureDisplay.usesFahrenheit(stored: true, locale: locale), system)
            XCTAssertFalse(TemperatureDisplay.usesFahrenheit(stored: false, locale: locale), system)
        }
    }

    // MARK: Text

    func testLabel_OneDecimalInEitherUnit() {
        XCTAssertEqual(TemperatureDisplay.label(celsius: 30.4, fahrenheit: false), "30.4°C")
        XCTAssertEqual(TemperatureDisplay.label(celsius: 30.4, fahrenheit: true), "86.7°F")
        XCTAssertEqual(TemperatureDisplay.label(celsius: 0, fahrenheit: false), "0.0°C")
        XCTAssertEqual(TemperatureDisplay.label(celsius: 0, fahrenheit: true), "32.0°F")
        XCTAssertEqual(TemperatureDisplay.label(celsius: -10, fahrenheit: true), "14.0°F")
    }
}
