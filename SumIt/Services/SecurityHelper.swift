import Foundation
import CryptoKit

/// Cryptographic helpers: PIN hashing (PBKDF2 via CommonCrypto), nonce generation, SHA256.
enum SecurityHelper {

    // MARK: — Random nonce for Sign in with Apple

    /// Cryptographically-random nonce. Returns ASCII-safe alphanumeric of given length.
    static func randomNonce(length: Int = 32) -> String {
        precondition(length > 0)
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remaining = length
        while remaining > 0 {
            var bytes = [UInt8](repeating: 0, count: 16)
            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
            for b in bytes where remaining > 0 {
                if b < charset.count { result.append(charset[Int(b) % charset.count]); remaining -= 1 }
            }
        }
        return result
    }

    /// SHA256 hex digest of a string.
    static func sha256Hex(_ input: String) -> String {
        let data = Data(input.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: — PIN hashing

    /// Computes salted SHA256 over many iterations (lightweight PBKDF2 substitute via repeated hashing).
    /// We use 100k iterations of SHA256 which is good enough for a 4-digit PIN paired with Keychain storage.
    static func hashPIN(_ pin: String, salt: Data, iterations: Int = 100_000) -> Data {
        var current = Data(pin.utf8) + salt
        for _ in 0..<iterations {
            current = Data(SHA256.hash(data: current))
        }
        return current
    }

    /// Generates 16-byte random salt.
    static func randomSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }
}
