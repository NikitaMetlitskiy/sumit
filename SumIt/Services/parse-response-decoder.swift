import Foundation

// MARK: — The app's locale

/// The locale the user chose inside the app, not the device's.
///
/// Amount parsing and amount display have to agree on which character is the
/// decimal separator. The formatter already followed the app language; the
/// editors and the parse request read `Locale.current`, so on a device set to
/// English with the app in Russian, "12,50" was displayed one way and parsed
/// another (UIEDIT-08).
enum AppLocale {
    nonisolated static var current: Locale {
        Locale(identifier: LocalizationManager.currentLanguageRaw)
    }

    nonisolated static var identifier: String {
        LocalizationManager.currentLanguageRaw
    }
}

// MARK: — Request

/// What the server needs to read the user's words the way the user meant them:
/// their own "today" (so "yesterday" is not resolved in UTC on a server
/// somewhere else), their time zone, and the app's locale.
nonisolated struct ParseContext: Equatable, Sendable {
    let localDate: String
    let timeZone: String
    let locale: String

    static func current(now: Date = .now,
                        timeZone: TimeZone = .current,
                        locale: String = AppLocale.identifier) -> ParseContext {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        let day = String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
        return ParseContext(localDate: day, timeZone: timeZone.identifier, locale: locale)
    }
}

/// Body of a contract-version-2 parse request. One shape for text and photo;
/// the unused field is omitted.
nonisolated struct ParseRequest: Encodable, Sendable {
    static let contractVersion = 2

    let text: String?
    let image: String?
    let model: String
    let wallets: String?
    let contractVersion: Int
    let localDate: String
    let timezone: String
    let locale: String
    let segmentIndex: Int?

    init(text: String? = nil, image: String? = nil, model: String, wallets: String? = nil,
         context: ParseContext, segmentIndex: Int? = nil) {
        self.text = text
        self.image = image
        self.model = model
        self.wallets = wallets
        self.contractVersion = Self.contractVersion
        self.localDate = context.localDate
        self.timezone = context.timeZone
        self.locale = context.locale
        self.segmentIndex = segmentIndex
    }

    enum CodingKeys: String, CodingKey {
        case text, image, model, wallets, timezone, locale
        case contractVersion = "contract_version"
        case localDate = "local_date"
        case segmentIndex = "segment_index"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(image, forKey: .image)
        try container.encode(model, forKey: .model)
        try container.encodeIfPresent(wallets, forKey: .wallets)
        try container.encode(contractVersion, forKey: .contractVersion)
        try container.encode(localDate, forKey: .localDate)
        try container.encode(timezone, forKey: .timezone)
        try container.encode(locale, forKey: .locale)
        try container.encodeIfPresent(segmentIndex, forKey: .segmentIndex)
    }
}

// MARK: — Response

/// Marked `Sendable` so it can cross the actor boundary in BackendService
/// without inheriting MainActor isolation from the enclosing file.
nonisolated struct BackendParseResponse: Decodable, Sendable {
    let contract_version: Int?
    let type: String?
    /// Version 2: the exact amount as digits. Authoritative when present.
    let amount_decimal: String?
    /// Version 1, and a derived mirror in version 2. Never read by a v2 client.
    let amount: Double?
    let currency: String?
    let category: String?
    let date: String?
    let merchant: String?
    let note: String?
    let confidence: Double?
    let error: String?
    let reason: String?
    let message: String?
    let wallet_name: String?
    let segment_index: Int?
}

// MARK: — Decoding

/// Turns a parse response into a `ParsedTransaction`, or refuses it.
///
/// A version-2 response is held to the contract it declares: an amount that is
/// not exact digits, a type the app does not know, a date that is not a day —
/// each is an error with its own code. Nothing falls back to the Double, and
/// nothing is defaulted into a different meaning; "unknown type → expense" is
/// how a transfer used to be recorded as spending.
///
/// A response with no `contract_version` came from a server that has not been
/// updated. It goes through `LegacyParseCompatibility`, which is named as what
/// it is so that nobody mistakes it for the exact path.
enum ParseResponseDecoder {

    nonisolated static func transaction(from response: BackendParseResponse,
                                        rawInput: String,
                                        source: TransactionSource,
                                        expectedSegmentIndex: Int? = nil,
                                        timeZone: TimeZone = .current) throws -> ParsedTransaction {
        if response.error == "not_a_transaction" { throw BackendError.parseFailed }
        if let error = response.error {
            throw error == "invalid_model_output"
                ? BackendError.malformedResponse(response.reason ?? error)
                : BackendError.parseFailed
        }

        switch response.contract_version {
        case .some(ParseRequest.contractVersion):
            return try decodeV2(response, rawInput: rawInput, source: source,
                                expectedSegmentIndex: expectedSegmentIndex, timeZone: timeZone)
        case .none:
            return try LegacyParseCompatibility.transaction(from: response, rawInput: rawInput,
                                                            source: source, timeZone: timeZone)
        case .some:
            throw BackendError.malformedResponse("unsupported_contract_version")
        }
    }

    nonisolated private static func decodeV2(_ response: BackendParseResponse,
                                             rawInput: String,
                                             source: TransactionSource,
                                             expectedSegmentIndex: Int?,
                                             timeZone: TimeZone) throws -> ParsedTransaction {
        guard let typeText = response.type, let type = TransactionType(rawValue: typeText) else {
            throw BackendError.malformedResponse("unknown_type")
        }
        guard let currencyText = response.currency else { throw BackendError.noAmount }
        let currency = currencyText.uppercased()
        guard MoneyPrecision.isSupported(currency) else { throw BackendError.unknownCurrency(currency) }

        guard let exact = response.amount_decimal else {
            throw BackendError.malformedResponse("missing_amount_decimal")
        }
        let amount: Decimal
        do {
            amount = try MoneyCodec.decode(exact)
            try MoneyCodec.validateEntry(amount, currency: currency)
        } catch let error as MoneyError {
            throw BackendError.malformedResponse(code(for: error))
        }

        guard let dateText = response.date, let date = day(dateText, timeZone: timeZone) else {
            throw BackendError.malformedResponse("invalid_date")
        }
        guard let confidence = response.confidence, confidence.isFinite, (0...1).contains(confidence) else {
            throw BackendError.malformedResponse("invalid_confidence")
        }
        if let expectedSegmentIndex, response.segment_index != expectedSegmentIndex {
            // An answer for a different segment must not be confirmed as this one.
            throw BackendError.malformedResponse("segment_index_mismatch")
        }

        return ParsedTransaction(
            type: type,
            amount: NSDecimalNumber(decimal: amount).doubleValue,
            currency: currency,
            categoryName: response.category ?? "Other",
            merchant: response.merchant ?? "",
            note: response.note ?? "",
            occurredAt: date,
            confidence: confidence,
            rawInput: rawInput,
            source: source,
            walletName: response.wallet_name ?? "",
            amountExact: try MoneyCodec.encode(amount))
    }

    /// `YYYY-MM-DD` as the start of that day in the user's time zone.
    nonisolated static func day(_ text: String, timeZone: TimeZone) -> Date? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let dayNumber = Int(parts[2]) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = DateComponents(year: year, month: month, day: dayNumber)
        guard let date = calendar.date(from: components) else { return nil }
        // Rejects 2026-02-30, which `Calendar` would otherwise roll into March.
        let check = calendar.dateComponents([.year, .month, .day], from: date)
        guard check.year == year, check.month == month, check.day == dayNumber else { return nil }
        return date
    }

    nonisolated static func code(for error: MoneyError) -> String {
        switch error {
        case .invalidSyntax:       return "invalid_amount"
        case .nonFinite:           return "non_finite_amount"
        case .outOfRange:          return "amount_out_of_range"
        case .excessPrecision:     return "excess_precision"
        case .arithmeticFailure:   return "arithmetic_failure"
        case .unsupportedCurrency: return "unsupported_currency"
        }
    }
}

/// **Compatibility only.** Reads a response from a server that predates
/// contract version 2 and therefore sends the amount as a JSON number.
///
/// The number has already been through a binary double, so the exact digits
/// the user wrote cannot be recovered. This reads the double's shortest decimal
/// description — the value it actually denotes — and still applies every rule
/// the exact path applies: no unknown type becomes an expense, and nothing is
/// capped into range. It exists so a client released before the backend is
/// deployed keeps working, and should be removed once every server speaks v2.
enum LegacyParseCompatibility {

    nonisolated static func transaction(from response: BackendParseResponse,
                                        rawInput: String,
                                        source: TransactionSource,
                                        timeZone: TimeZone) throws -> ParsedTransaction {
        guard let number = response.amount, number > 0, let currencyText = response.currency else {
            throw BackendError.noAmount
        }
        let currency = currencyText.uppercased()
        guard MoneyPrecision.isSupported(currency) else { throw BackendError.unknownCurrency(currency) }
        guard let type = TransactionType(rawValue: response.type ?? "") else {
            throw BackendError.malformedResponse("unknown_type")
        }
        guard number.isFinite else { throw BackendError.malformedResponse("non_finite_amount") }

        let amount: Decimal
        do {
            amount = try MoneyCodec.decode(String(number))
            try MoneyCodec.validateEntry(amount, currency: currency)
        } catch let error as MoneyError {
            throw BackendError.malformedResponse(ParseResponseDecoder.code(for: error))
        }

        let date = response.date.flatMap { ParseResponseDecoder.day($0, timeZone: timeZone) } ?? .now
        let confidence = response.confidence.flatMap { $0.isFinite ? min(max($0, 0), 1) : nil } ?? 0.8

        return ParsedTransaction(
            type: type,
            amount: number,
            currency: currency,
            categoryName: response.category ?? "Other",
            merchant: response.merchant ?? "",
            note: response.note ?? "",
            occurredAt: date,
            confidence: confidence,
            rawInput: rawInput,
            source: source,
            walletName: response.wallet_name ?? "",
            amountExact: try MoneyCodec.encode(amount))
    }
}
