import XCTest
@testable import SumIt

/// AMT group from acceptance-tests.md §3 that concerns locale-aware input.
/// The parser consumes the whole string; a valid prefix is never acceptance.
final class AmountParserTests: XCTestCase {

    private func parse(_ text: String,
                       _ currency: String = "USD",
                       _ localeID: String = "en-US",
                       allowNegative: Bool = false,
                       allowZero: Bool = false) throws -> String {
        let value = try AmountParser.parse(text,
                                           currency: currency,
                                           locale: Locale(identifier: localeID),
                                           allowNegative: allowNegative,
                                           allowZero: allowZero)
        return try MoneyCodec.encode(value)
    }

    // MARK: — Decimal comma across the six supported app languages (AMT-03, AMT-04)

    func testDecimalCommaInCommaLocales() throws {
        for localeID in ["de-DE", "pl-PL", "ru-RU", "uk-UA", "es-ES"] {
            XCTAssertEqual(try parse("12,50", "EUR", localeID), "12.5", "locale \(localeID)")
        }
    }

    func testDecimalPointInEnglish() throws {
        XCTAssertEqual(try parse("12.50", "USD", "en-US"), "12.5")   // AMT-05
    }

    // MARK: — Grouping (AMT-06, AMT-07, AMT-08)

    func testValidGroupingIsAccepted() throws {
        XCTAssertEqual(try parse("1,234.56", "USD", "en-US"), "1234.56")
        XCTAssertEqual(try parse("1,234,567.89", "USD", "en-US"), "1234567.89")
        XCTAssertEqual(try parse("1.234,56", "EUR", "de-DE"), "1234.56")
        XCTAssertEqual(try parse("1.234.567,89", "EUR", "de-DE"), "1234567.89")
    }

    /// AMT-08. Ordinary space, no-break space and narrow no-break space are all
    /// accepted where the locale groups with a space.
    func testSpaceGroupingVariants() throws {
        XCTAssertEqual(try parse("1 234,56", "PLN", "pl-PL"), "1234.56")
        XCTAssertEqual(try parse("1\u{00A0}234,56", "PLN", "pl-PL"), "1234.56")
        XCTAssertEqual(try parse("1\u{202F}234,56", "PLN", "pl-PL"), "1234.56")
    }

    // MARK: — Ambiguity is decided by the app locale (AMT-09)

    func testAmbiguousSingleSeparatorFollowsAppLocale() throws {
        XCTAssertEqual(try parse("1,000", "USD", "en-US"), "1000")
        XCTAssertEqual(try parse("1,000", "EUR", "de-DE"), "1")
    }

    /// The alternative separator is accepted exactly when it cannot be valid
    /// grouping for that locale, so `12,50` in en-US is unambiguous.
    func testAlternativeSeparatorOnlyWhenGroupingIsImpossible() throws {
        XCTAssertEqual(try parse("12,50", "USD", "en-US"), "12.5")
        XCTAssertEqual(try parse("12.50", "EUR", "de-DE"), "12.5")
    }

    // MARK: — Rejection (AMT-10, AMT-11)

    func testMalformedInputIsRejected() {
        let cases = [
            "1,23,456",     // inconsistent grouping
            "12.3.4",       // two decimal separators
            "12.50abc",     // trailing garbage
            "1.234,56",     // German format offered to an en-US parser
            "",             // empty
            "   ",          // whitespace only
            "NaN",
            "Infinity",
            "1e3",          // exponent notation is not editable input
            "+12",          // leading plus
            "12.",          // open fraction
            ".5",           // no integer part
            "USD 12",       // currency word inside the amount field
        ]
        for text in cases {
            XCTAssertThrowsError(try parse(text), "parser accepted \(text)")
        }
    }

    func testNegativeIsRejectedUnlessAllowed() {
        XCTAssertThrowsError(try parse("-1")) { XCTAssertEqual($0 as? MoneyError, .outOfRange) }
        XCTAssertEqual(try? parse("-1", "USD", "en-US", allowNegative: true, allowZero: true), "-1")
    }

    /// AMT-12/AMT-19. Zero is a wallet-context value only, and negative zero
    /// canonicalizes rather than displaying as "-0".
    func testZeroRules() throws {
        XCTAssertThrowsError(try parse("0")) { XCTAssertEqual($0 as? MoneyError, .outOfRange) }
        XCTAssertEqual(try parse("0", "USD", "en-US", allowNegative: true, allowZero: true), "0")
        XCTAssertEqual(try parse("-0", "USD", "en-US", allowNegative: true, allowZero: true), "0")
    }

    // MARK: — Precision and range come from the shared codec

    func testPrecisionAndRangeAreEnforcedOnParse() {
        XCTAssertThrowsError(try parse("12.345", "USD")) { XCTAssertEqual($0 as? MoneyError, .excessPrecision) }
        XCTAssertThrowsError(try parse("12,5", "JPY", "de-DE")) { XCTAssertEqual($0 as? MoneyError, .excessPrecision) }
        XCTAssertThrowsError(try parse("1000000000001", "USD")) { XCTAssertEqual($0 as? MoneyError, .outOfRange) }
    }

    func testCryptoPrecisionSurvivesParsing() throws {
        XCTAssertEqual(try parse("0.00000001", "BTC"), "0.00000001")
        XCTAssertEqual(try parse("0.000000000000000001", "ETH"), "0.000000000000000001")
    }

    /// AMT-08 tail: an amount typed with the app locale must not depend on the
    /// device locale. The parser only ever reads the locale it is handed.
    func testParserIgnoresDeviceLocale() throws {
        XCTAssertEqual(try parse("12,50", "EUR", "de-DE"), "12.5")
        XCTAssertEqual(try parse("12.50", "USD", "en-US"), "12.5")
    }
}
