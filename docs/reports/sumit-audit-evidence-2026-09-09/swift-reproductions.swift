import Foundation
    func splitTransactionInput(_ text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: " + ", with: ",")
            .replacingOccurrences(of: ";", with: ",")
        // Split on commas only — " и "/" and " is too dangerous (breaks merchant names).
        let parts = normalized.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let regex = try? NSRegularExpression(pattern: #"\d+"#) else { return [text] }
        let withNumbers = parts.filter {
            regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil
        }
        return withNumbers.count >= 2 ? withNumbers : [text]
    }

for input in ["12,50 EUR coffee", "1,000 USD rent", "10 coffee, 20 taxi", "0,001 BTC"] { print("split: \(input) -> \(splitTransactionInput(input))") }
for amount in [12.50, 0.001, 19.99] { print("edit round trip: \(amount) -> \(String(format: "%.0f", amount))") }
let iso = ISO8601DateFormatter(); print("timestamp fractional seconds accepted: \(iso.date(from: "2026-05-19T10:00:00.123456+00:00") != nil)")
