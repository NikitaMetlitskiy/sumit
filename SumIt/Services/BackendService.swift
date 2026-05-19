import Foundation

/// Marked `Sendable` so it can cross the actor boundary in BackendService
/// without inheriting MainActor isolation from the enclosing file.
nonisolated struct BackendParseResponse: Decodable, Sendable {
    let type: String?
    let amount: Double?
    let currency: String?
    let category: String?
    let date: String?
    let merchant: String?
    let note: String?
    let confidence: Double?
    let error: String?
    let message: String?
    let wallet_name: String?
}

actor BackendService {
    static let shared = BackendService()

    private var baseURL: String { AppConfig.backendURL }
    private let useMock = false

    // MARK: — Parse text
    func parseText(_ rawText: String, walletNames: [String] = []) async throws -> ParsedTransaction {
        let text = sanitize(rawText)
        if useMock { return try mockParse(text: text, source: .text) }

        let model = await MainActor.run { StoreKitManager.shared.currentTier.gptModel }

        var body: [String: String] = ["text": text, "model": model]
        if !walletNames.isEmpty {
            body["wallets"] = walletNames.joined(separator: ", ")
        }

        let response = try await post(endpoint: "/api/parse", body: body)
        var tx = try buildTransaction(from: response, rawInput: text, source: .text)

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
        let response = try await post(endpoint: "/api/parse-image", body: ["image": dataURL, "model": model])
        return try buildTransaction(from: response, rawInput: "📷 Receipt", source: .photo)
    }

    // MARK: — POST helper (attaches Supabase JWT for backend auth + rate limiting)
    private func post(endpoint: String, body: [String: String]) async throws -> BackendParseResponse {
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
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            throw BackendError.serverError(code)
        }
        return try JSONDecoder().decode(BackendParseResponse.self, from: data)
    }

    // MARK: — Build ParsedTransaction
    private func buildTransaction(from r: BackendParseResponse, rawInput: String, source: TransactionSource) throws -> ParsedTransaction {
        if r.error != nil {
            throw BackendError.parseFailed
        }
        guard let amount = r.amount, amount > 0, let currency = r.currency else {
            throw BackendError.noAmount
        }
        // Reject unknown currency at the boundary so we never store garbage.
        guard CurrencyService.isSupported(currency) else {
            throw BackendError.unknownCurrency(currency)
        }

        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"; fmt.locale = Locale(identifier: "en_US_POSIX")
        let date = r.date.flatMap { fmt.date(from: $0) } ?? .now

        return ParsedTransaction(
            type: TransactionType(rawValue: r.type ?? "expense") ?? .expense,
            amount: min(amount, 1e12),
            currency: currency.uppercased(),
            categoryName: r.category ?? "Other",
            merchant: r.merchant ?? "",
            note: r.note ?? "",
            occurredAt: date,
            confidence: r.confidence ?? 0.8,
            rawInput: rawInput,
            source: source,
            walletName: r.wallet_name ?? ""
        )
    }

    // MARK: — Mock parser (dev only)
    func mockParse(text: String, source: TransactionSource) throws -> ParsedTransaction {
        let lower = text.lowercased()
        var amount = 0.0
        if let regex = try? NSRegularExpression(pattern: #"(\d+(?:[.,]\d+)?)"#),
           let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let r = Range(m.range(at: 1), in: text) {
            amount = Double(text[r].replacingOccurrences(of: ",", with: ".")) ?? 0
        }
        guard amount > 0 else { throw BackendError.noAmount }

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
            walletName: ""
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

    var errorDescription: String? {
        switch self {
        case .badURL:                 return L("backend_bad_url")
        case .serverError(let code):  return String(format: L("backend_server_error"), code)
        case .parseFailed:            return L("backend_parse_failed")
        case .noAmount:               return L("backend_no_amount")
        case .unknownCurrency(let c): return String(format: L("backend_unknown_currency"), c)
        case .imageTooLarge:          return L("backend_image_too_large")
        }
    }
}
