import Foundation

actor BackendService {
    static let shared = BackendService()

    private var baseURL: String { AppConfig.backendURL }
    private let useMock = false

    // MARK: — Parse text
    /// - Parameter segmentIndex: the position of this text in a batch. Sent to
    ///   the server and checked on the way back, so an answer can only ever be
    ///   confirmed against the segment it was produced for.
    func parseText(_ rawText: String, walletNames: [String] = [],
                   segmentIndex: Int? = nil) async throws -> ParsedTransaction {
        let text = sanitize(rawText)
        if useMock { return try mockParse(text: text, source: .text) }

        let model = await MainActor.run { StoreKitManager.shared.currentTier.gptModel }

        let request = ParseRequest(text: text, model: model,
                                   wallets: walletNames.isEmpty ? nil : walletNames.joined(separator: ", "),
                                   context: .current(), segmentIndex: segmentIndex)
        let response = try await post(endpoint: "/api/parse", body: request)
        var tx = try ParseResponseDecoder.transaction(from: response, rawInput: text, source: .text,
                                                      expectedSegmentIndex: segmentIndex)

        if tx.walletName.isEmpty && !walletNames.isEmpty {
            tx.walletName = matchWallet(text: text, walletNames: walletNames)
        }
        return tx
    }

    // MARK: — Sanitize input
    private func sanitize(_ input: String) -> String {
        // Strip ASCII control bytes; cap length so prompt injection / billing-abuse is bounded.
        let filtered = input.unicodeScalars.filter { $0.value > 0x1F && !$0.properties.isDefaultIgnorableCodePoint }
        var s = String(String.UnicodeScalarView(filtered))
        if s.count > AppConfig.maxParseInputChars {
            s = String(s.prefix(AppConfig.maxParseInputChars))
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: — Client-side wallet fuzzy matching
    private func matchWallet(text: String, walletNames: [String]) -> String {
        let lower = text.lowercased()
        let translit: [Character: String] = [
            "а":"a","б":"b","в":"v","г":"g","д":"d","е":"e","ё":"yo","ж":"zh",
            "з":"z","и":"i","й":"y","к":"k","л":"l","м":"m","н":"n","о":"o",
            "п":"p","р":"r","с":"s","т":"t","у":"u","ф":"f","х":"kh","ц":"ts",
            "ч":"ch","ш":"sh","щ":"shch","ы":"y","э":"e","ю":"yu","я":"ya",
            "і":"i","ї":"yi","є":"ye","ґ":"g"
        ]
        func transliterate(_ s: String) -> String {
            s.lowercased().map { translit[$0] ?? String($0) }.joined()
        }
        for name in walletNames {
            let nameLower = name.lowercased()
            let nameTranslit = transliterate(name)
            if lower.contains(nameLower) { return name }
            let inputTranslit = transliterate(lower)
            if inputTranslit.contains(nameTranslit) { return name }
            if lower.contains(nameTranslit) { return name }
            if inputTranslit.contains(nameLower) { return name }
        }
        return ""
    }

    // MARK: — Parse image
    func parseImage(dataURL: String) async throws -> ParsedTransaction {
        guard dataURL.count < AppConfig.maxImageUploadBytes * 2 else {
            throw BackendError.imageTooLarge
        }
        let model = await MainActor.run { StoreKitManager.shared.currentTier.gptModel }
        let request = ParseRequest(image: dataURL, model: model, context: .current())
        let response = try await post(endpoint: "/api/parse-image", body: request)
        return try ParseResponseDecoder.transaction(from: response, rawInput: "📷 Receipt", source: .photo)
    }

    // MARK: — Rates (checked GET)

    /// `GET /api/rates` through the same endpoint and authentication as parsing.
    /// Sends currency codes and an optional day — never an amount, text or
    /// wallet. Returns the raw body; decoding happens where the quote is used.
    func getRates(currencies: [String], date: String?) async throws -> Data {
        guard var components = URLComponents(string: "\(baseURL)/api/rates") else { throw BackendError.badURL }
        var items = [URLQueryItem(name: "currencies", value: currencies.joined(separator: ","))]
        if let date { items.append(URLQueryItem(name: "date", value: date)) }
        components.queryItems = items
        guard let url = components.url else { throw BackendError.badURL }

        guard let token = await MainActor.run(body: { AuthService.shared.accessToken }) else {
            throw BackendError.notSignedIn
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-Id")
        req.timeoutInterval = 20

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw BackendError.serverError(status) }
        return data
    }

    // MARK: — POST helper (attaches Supabase JWT for backend auth + rate limiting)
    private func post(endpoint: String, body: ParseRequest) async throws -> BackendParseResponse {
        guard let url = URL(string: "\(baseURL)\(endpoint)") else { throw BackendError.badURL }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-Id")
        if let token = await MainActor.run(body: { AuthService.shared.accessToken }) {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONEncoder().encode(body)
        req.timeoutInterval = 60

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        // 422 carries a structured "the model's answer broke the contract"
        // body; decoding it lets the reason reach the user instead of a bare
        // status code.
        if status == 422, let body = try? JSONDecoder().decode(BackendParseResponse.self, from: data) {
            return body
        }
        guard status == 200 else { throw BackendError.serverError(status) }
        return try JSONDecoder().decode(BackendParseResponse.self, from: data)
    }

    // MARK: — Mock parser (dev only)
    func mockParse(text: String, source: TransactionSource) throws -> ParsedTransaction {
        let lower = text.lowercased()
        var exact = ""
        if let regex = try? NSRegularExpression(pattern: #"(\d+(?:[.,]\d+)?)"#),
           let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let r = Range(m.range(at: 1), in: text) {
            exact = text[r].replacingOccurrences(of: ",", with: ".")
        }
        guard let decimal = try? MoneyCodec.decode(exact), decimal > 0 else { throw BackendError.noAmount }
        let amount = NSDecimalNumber(decimal: decimal).doubleValue

        let currency: String
        if lower.contains("usdc") || lower.contains("usdt") { currency = "USDC" }
        else if lower.contains("btc") { currency = "BTC" }
        else if lower.contains("eth") { currency = "ETH" }
        else if lower.contains("uah") || lower.contains("грн") || lower.contains("₴") { currency = "UAH" }
        else if lower.contains("$") || lower.contains("usd") || lower.contains("долл") { currency = "USD" }
        else if lower.contains("€") || lower.contains("eur") { currency = "EUR" }
        else { currency = "UAH" }

        return ParsedTransaction(
            type: .expense, amount: amount, currency: currency,
            categoryName: "Other", merchant: "", note: "",
            occurredAt: .now, confidence: 0.85, rawInput: text, source: source,
            walletName: "", amountExact: try MoneyCodec.encode(decimal)
        )
    }
}

enum BackendError: LocalizedError {
    case badURL
    case serverError(Int)
    case parseFailed
    case noAmount
    case unknownCurrency(String)
    case imageTooLarge
    /// The response broke the contract it declared. Carries the machine reason.
    case malformedResponse(String)
    /// The request needs an account and there is no session.
    case notSignedIn

    var errorDescription: String? {
        switch self {
        case .badURL:                 return L("backend_bad_url")
        case .serverError(let code):  return String(format: L("backend_server_error"), code)
        case .parseFailed:            return L("backend_parse_failed")
        case .noAmount:               return L("backend_no_amount")
        case .unknownCurrency(let c): return String(format: L("backend_unknown_currency"), c)
        case .imageTooLarge:          return L("backend_image_too_large")
        case .malformedResponse:      return L("backend_malformed_response")
        case .notSignedIn:            return L("rate_reason_not_signed_in")
        }
    }
}
