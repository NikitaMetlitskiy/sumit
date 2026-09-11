import XCTest
@testable import SumIt

/// SEG group from acceptance-tests.md §4. Segmentation is pure: none of these
/// cases needs the AI service to be reachable.
final class TransactionInputSegmenterTests: XCTestCase {

    // MARK: — Numeric punctuation is never a boundary (SEG-01..03, SEG-10)

    func testDecimalCommaIsNotABatchBoundary() throws {
        XCTAssertEqual(try TransactionInputSegmenter.split("12,50 EUR coffee"), ["12,50 EUR coffee"])
        XCTAssertEqual(try TransactionInputSegmenter.split("0,001 BTC"), ["0,001 BTC"])
        XCTAssertEqual(try TransactionInputSegmenter.split("1,000 USD rent"), ["1,000 USD rent"])
        XCTAssertEqual(try TransactionInputSegmenter.split("10,20"), ["10,20"])
    }

    // MARK: — Real boundaries (SEG-04..08)

    func testExplicitSeparatorsSplit() throws {
        XCTAssertEqual(try TransactionInputSegmenter.split("10 coffee, 20 taxi"), ["10 coffee", "20 taxi"])
        XCTAssertEqual(try TransactionInputSegmenter.split("10 coffee,20 taxi"), ["10 coffee", "20 taxi"])
        XCTAssertEqual(try TransactionInputSegmenter.split("10 coffee; 20 taxi"), ["10 coffee", "20 taxi"])
        XCTAssertEqual(try TransactionInputSegmenter.split("10 coffee + 20 taxi"), ["10 coffee", "20 taxi"])
    }

    /// SEG-07. Newlines carry intent and must be read before sanitization
    /// removes them, in all three line-ending conventions.
    func testLineEndingsSplitBeforeSanitization() throws {
        XCTAssertEqual(try TransactionInputSegmenter.split("10 coffee\n20 taxi"), ["10 coffee", "20 taxi"])
        XCTAssertEqual(try TransactionInputSegmenter.split("10 coffee\r\n20 taxi"), ["10 coffee", "20 taxi"])
        XCTAssertEqual(try TransactionInputSegmenter.split("10 coffee\r20 taxi"), ["10 coffee", "20 taxi"])
    }

    /// SEG-09. The old implementation filtered out chunks with no digit, which
    /// silently deleted the first entry here.
    func testSegmentWithoutDigitsIsRetained() throws {
        XCTAssertEqual(try TransactionInputSegmenter.split("ten dollars coffee; 20 taxi"),
                       ["ten dollars coffee", "20 taxi"])
    }

    func testConjunctionsAndUnspacedPlusAreNotBoundaries() throws {
        XCTAssertEqual(try TransactionInputSegmenter.split("coffee and tea 10"), ["coffee and tea 10"])
        XCTAssertEqual(try TransactionInputSegmenter.split("кофе и чай 10"), ["кофе и чай 10"])
        XCTAssertEqual(try TransactionInputSegmenter.split("10+20"), ["10+20"])
    }

    func testOrderIsPreservedAndEmptiesDropped() throws {
        XCTAssertEqual(try TransactionInputSegmenter.split("10 coffee,, 20 taxi;\n30 bus"),
                       ["10 coffee", "20 taxi", "30 bus"])
        XCTAssertEqual(try TransactionInputSegmenter.split("  10 coffee ;  20 taxi  "),
                       ["10 coffee", "20 taxi"])
    }

    /// Fewer than two nonempty segments means the original submission is sent
    /// unchanged, so a stray trailing delimiter is preserved rather than edited.
    func testSingleSegmentReturnsOriginalInput() throws {
        XCTAssertEqual(try TransactionInputSegmenter.split("  12,50 EUR coffee  "), ["12,50 EUR coffee"])
        XCTAssertEqual(try TransactionInputSegmenter.split("10 coffee,"), ["10 coffee,"])
    }

    // MARK: — Limits are errors, not truncation (SEG-12, SEG-13)

    func testSegmentCountLimit() throws {
        let twenty = (1...20).map { "\($0) item" }.joined(separator: ";")
        XCTAssertEqual(try TransactionInputSegmenter.split(twenty).count, 20)

        let twentyOne = (1...21).map { "\($0) item" }.joined(separator: ";")
        XCTAssertThrowsError(try TransactionInputSegmenter.split(twentyOne)) { error in
            XCTAssertEqual(error as? SegmentationError, .tooManySegments(count: 21))
        }
    }

    func testOverLongSegmentIsRejectedNotTruncated() throws {
        let long = String(repeating: "a", count: 501)
        XCTAssertThrowsError(try TransactionInputSegmenter.split(long)) { error in
            XCTAssertEqual(error as? SegmentationError, .segmentTooLong(index: 0, length: 501, limit: 500))
        }
        XCTAssertThrowsError(try TransactionInputSegmenter.split("10 coffee;" + long)) { error in
            XCTAssertEqual(error as? SegmentationError, .segmentTooLong(index: 1, length: 501, limit: 500))
        }
        XCTAssertEqual(try TransactionInputSegmenter.split(String(repeating: "b", count: 500)).count, 1)
    }

    func testEmptyInputIsExplicit() {
        for text in ["", "   \n  "] {
            XCTAssertThrowsError(try TransactionInputSegmenter.split(text)) { error in
                XCTAssertEqual(error as? SegmentationError, .empty)
            }
        }
    }

    /// No submitted text may disappear between input and segments.
    func testNoContentIsLost() throws {
        for text in ["10 coffee, 20 taxi", "12,50 EUR coffee", "ten dollars coffee; 20 taxi",
                     "10 coffee + 20 taxi", "a,b;c\nd"] {
            let segments = try TransactionInputSegmenter.split(text)
            let inputContent = text.filter { $0.isNumber || $0.isLetter }
            let outputContent = segments.joined().filter { $0.isNumber || $0.isLetter }
            XCTAssertEqual(inputContent, outputContent, "content lost for \(text)")
        }
    }
}
