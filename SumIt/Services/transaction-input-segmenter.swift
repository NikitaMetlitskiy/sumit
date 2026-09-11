import Foundation

/// Failure modes of batch segmentation. Each one is shown to the user before
/// any paid parse happens; none of them silently drops or truncates input.
enum SegmentationError: Error, Equatable {
    case empty
    /// More than `TransactionInputSegmenter.maxSegments` intended entries.
    case tooManySegments(count: Int)
    /// A segment exceeds the server's per-parse character limit.
    case segmentTooLong(index: Int, length: Int, limit: Int)
}

/// Splits one chat submission into the transactions the user intended.
///
/// The previous implementation replaced `;` and ` + ` with commas, split on
/// every comma, and then **discarded** any chunk without a digit. That turned
/// `12,50 EUR coffee` into two fragments and silently lost text. Here a comma
/// is a boundary only when it is not sitting between two digits, and every
/// segment the user submitted is returned — including ones with no digits.
///
/// Segmentation runs on the raw text, before `BackendService.sanitize`, because
/// sanitization strips the newlines that carry intent.
enum TransactionInputSegmenter {

    /// Maximum intended entries in one submission.
    static let maxSegments = 20
    /// Per-segment character limit; mirrors `AppConfig.maxParseInputChars`.
    static let maxSegmentLength = 500

    /// Returns the ordered segments. A single-entry submission returns one
    /// element containing the trimmed original text.
    static func split(_ text: String) throws -> [String] {
        let normalized = normalizeLineEndings(text)
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SegmentationError.empty
        }

        let segments = scan(normalized)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // Fewer than two intended entries: the whole submission is one segment.
        let result = segments.count < 2
            ? [normalized.trimmingCharacters(in: .whitespacesAndNewlines)]
            : segments

        guard result.count <= maxSegments else {
            throw SegmentationError.tooManySegments(count: result.count)
        }
        for (index, segment) in result.enumerated() where segment.count > maxSegmentLength {
            throw SegmentationError.segmentTooLong(index: index,
                                                   length: segment.count,
                                                   limit: maxSegmentLength)
        }
        return result
    }

    // MARK: — Scan

    /// One pass over the characters. Boundaries are newline, semicolon, a
    /// spaced ` + `, and a comma whose immediate neighbours are not both
    /// decimal digits. Conjunctions ("and", "и") are never boundaries: they
    /// appear inside merchant names too often to be safe.
    private static func scan(_ text: String) -> [String] {
        var segments: [String] = []
        var current = ""
        let characters = Array(text)
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if character == "\n" || character == ";" {
                segments.append(current)
                current = ""
                index += 1
                continue
            }

            if character == "," {
                let previous = index > 0 ? characters[index - 1] : nil
                let next = index + 1 < characters.count ? characters[index + 1] : nil
                if !(isDigit(previous) && isDigit(next)) {
                    segments.append(current)
                    current = ""
                    index += 1
                    continue
                }
            }

            // Explicit spaced plus: "10 coffee + 20 taxi".
            if character == "+",
               index > 0, index + 1 < characters.count,
               isSpace(characters[index - 1]), isSpace(characters[index + 1]) {
                segments.append(current)
                current = ""
                index += 2   // skip the '+' and the space after it
                continue
            }

            current.append(character)
            index += 1
        }
        segments.append(current)
        return segments
    }

    private static func normalizeLineEndings(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func isDigit(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.isASCII && character.isNumber
    }

    private static func isSpace(_ character: Character) -> Bool {
        character == " " || character == "\u{00A0}" || character == "\u{202F}" || character == "\u{2009}"
    }
}
