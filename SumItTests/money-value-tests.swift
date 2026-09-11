import XCTest
@testable import SumIt

/// AMT group from acceptance-tests.md §3 that concerns canonical encoding,
/// quantization and entry limits. Locale parsing lives in amount-parser-tests.
final class MoneyValueTests: XCTestCase {

    // MARK: — Canonical encoding (AMT-01, AMT-19, AMT-22)

    func testCanonicalNormalization() throws {
        XCTAssertEqual(try MoneyCodec.encode(MoneyCodec.decode("12.50")), "12.5")   // AMT-01
        XCTAssertEqual(try MoneyCodec.encode(MoneyCodec.decode("-0")), "0")         // AMT-19
        XCTAssertEqual(try MoneyCodec.encode(MoneyCodec.decode("0")), "0")
    }

    func testCanonicalRoundTrip() throws {
        for text in ["12.5", "0.001", "0.00000001", "0.000000000000000001", "1000", "0", "-1"] {
            XCTAssertEqual(try MoneyCodec.encode(MoneyCodec.decode(text)), text, "round trip of \(text)")
        }
    }

    /// AMT-22. `Decimal(string:)` accepts exponents and parses a valid prefix,
    /// so every one of these must be rejected by the grammar first.
    func testWireDecodeRejectsNonCanonicalText() {
        for text in ["1e3", "+12.5", "1,234.56", "", " 12.5", "12.5abc", "12..5", "12.", ".5", "NaN", "Infinity"] {
            XCTAssertThrowsError(try MoneyCodec.decode(text), "decode accepted \(text)") { error in
                XCTAssertEqual(error as? MoneyError, .invalidSyntax)
            }
        }
    }

    // MARK: — Arithmetic (AMT-02)

    func testDecimalArithmeticIsExact() throws {
        let sum = try MoneyCodec.decode("0.1") + MoneyCodec.decode("0.2")
        XCTAssertEqual(sum, try MoneyCodec.decode("0.3"))
        XCTAssertEqual(try MoneyCodec.encode(sum), "0.3")
    }

    // MARK: — Half-even quantization (AMT-20)

    func testHalfEvenQuantization() throws {
        XCTAssertEqual(try MoneyCodec.encode(MoneyCodec.quantize(MoneyCodec.decode("1.005"), scale: 2)), "1")
        XCTAssertEqual(try MoneyCodec.encode(MoneyCodec.quantize(MoneyCodec.decode("1.015"), scale: 2)), "1.02")
        XCTAssertEqual(try MoneyCodec.encode(MoneyCodec.quantize(MoneyCodec.decode("2.675"), scale: 2)), "2.68")
    }

    func testQuantizeRejectsImpossibleScale() {
        XCTAssertThrowsError(try MoneyCodec.quantize(Decimal(1), scale: -1)) { error in
            XCTAssertEqual(error as? MoneyError, .outOfRange)
        }
    }

    // MARK: — Fraction digits

    func testFractionDigitsFollowNormalizedExponent() throws {
        XCTAssertEqual(MoneyCodec.fractionDigits(of: try MoneyCodec.decode("12.50")), 1)
        XCTAssertEqual(MoneyCodec.fractionDigits(of: try MoneyCodec.decode("1000")), 0)
        XCTAssertEqual(MoneyCodec.fractionDigits(of: try MoneyCodec.decode("0.000000000000000001")), 18)
    }

    // MARK: — Entry limits (AMT-12..AMT-18)

    func testCurrencyPrecisionLimits() throws {
        XCTAssertThrowsError(try MoneyCodec.validateEntry(MoneyCodec.decode("12.345"), currency: "USD")) {
            XCTAssertEqual($0 as? MoneyError, .excessPrecision)      // AMT-13
        }
        XCTAssertThrowsError(try MoneyCodec.validateEntry(MoneyCodec.decode("12.5"), currency: "JPY")) {
            XCTAssertEqual($0 as? MoneyError, .excessPrecision)      // AMT-14
        }
        XCTAssertNoThrow(try MoneyCodec.validateEntry(MoneyCodec.decode("12"), currency: "JPY"))
        XCTAssertNoThrow(try MoneyCodec.validateEntry(MoneyCodec.decode("0.123456"), currency: "USDC"))
        XCTAssertThrowsError(try MoneyCodec.validateEntry(MoneyCodec.decode("0.1234567"), currency: "USDC")) {
            XCTAssertEqual($0 as? MoneyError, .excessPrecision)      // AMT-17
        }
        XCTAssertNoThrow(try MoneyCodec.validateEntry(MoneyCodec.decode("0.00000001"), currency: "BTC"))       // AMT-15
        XCTAssertNoThrow(try MoneyCodec.validateEntry(MoneyCodec.decode("0.000000000000000001"), currency: "ETH")) // AMT-16
    }

    func testZeroAndNegativeRules() throws {
        XCTAssertThrowsError(try MoneyCodec.validateEntry(0, currency: "USD")) {
            XCTAssertEqual($0 as? MoneyError, .outOfRange)           // AMT-12
        }
        XCTAssertThrowsError(try MoneyCodec.validateEntry(MoneyCodec.decode("-1"), currency: "USD")) {
            XCTAssertEqual($0 as? MoneyError, .outOfRange)
        }
        XCTAssertNoThrow(try MoneyCodec.validateEntry(0, currency: "USD", allowNegative: true, allowZero: true))
        XCTAssertNoThrow(try MoneyCodec.validateEntry(try MoneyCodec.decode("-1"), currency: "USD",
                                                      allowNegative: true, allowZero: true))
    }

    /// AMT-18. Over the limit is an error, never a silent cap.
    func testRangeLimitIsNotACap() throws {
        XCTAssertNoThrow(try MoneyCodec.validateEntry(MoneyCodec.decode("1000000000000"), currency: "USD"))
        XCTAssertThrowsError(try MoneyCodec.validateEntry(MoneyCodec.decode("1000000000001"), currency: "USD")) {
            XCTAssertEqual($0 as? MoneyError, .outOfRange)
        }
    }

    func testUnsupportedCurrencyIsExplicit() {
        XCTAssertThrowsError(try MoneyCodec.validateEntry(Decimal(10), currency: "XYZ")) {
            XCTAssertEqual($0 as? MoneyError, .unsupportedCurrency)
        }
    }

    /// AMT-21. A legacy amount outside the new entry precision still encodes
    /// and decodes exactly; only new entry is restricted.
    func testLegacyOverPrecisionValueIsPreserved() throws {
        XCTAssertEqual(try MoneyCodec.encode(MoneyCodec.decode("12.345")), "12.345")
    }

    // MARK: — Edit strings (UIEDIT-01..03 support)

    func testEditStringHasNoGroupingAndNoPrecisionLoss() throws {
        XCTAssertEqual(try MoneyCodec.editString(MoneyCodec.decode("1234.56"), locale: Locale(identifier: "en-US")),
                       "1234.56")
        XCTAssertEqual(try MoneyCodec.editString(MoneyCodec.decode("1234.56"), locale: Locale(identifier: "de-DE")),
                       "1234,56")
        XCTAssertEqual(try MoneyCodec.editString(MoneyCodec.decode("0.00000001"), locale: Locale(identifier: "en-US")),
                       "0.00000001")
    }

    /// An editor that opens a value and saves it untouched must reproduce the
    /// exact stored string in every supported app locale.
    func testEditStringSurvivesReparseInEverySupportedLocale() throws {
        let value = try MoneyCodec.decode("1234.56")
        for identifier in ["en", "uk", "ru", "es", "de", "pl"] {
            let locale = Locale(identifier: identifier)
            let text = try MoneyCodec.editString(value, locale: locale)
            let parsed = try AmountParser.parse(text, currency: "USD", locale: locale)
            XCTAssertEqual(parsed, value, "round trip in \(identifier) via \(text)")
        }
    }
}
