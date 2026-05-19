import Foundation

/// Central configuration: endpoints, public keys, build-time flags.
/// Every property is marked `nonisolated` so actors (BackendService, SupabaseService)
/// can read them without hopping to the main actor.
enum AppConfig {
    nonisolated static let supabaseURL: String = readPlist(
        "SUPABASE_URL",
        default: "https://mjhosrblavjdxirayvqt.supabase.co"
    )
    nonisolated static let supabaseAnonKey: String = readPlist(
        "SUPABASE_ANON_KEY",
        default: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im1qaG9zcmJsYXZqZHhpcmF5dnF0Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzQ0OTUyOTgsImV4cCI6MjA5MDA3MTI5OH0.EcheZQDXIdtdmVolauEvmdTajPdPE4OKwkNUG1UZYPA"
    )
    nonisolated static let backendURL: String = readPlist(
        "SUMIT_BACKEND_URL",
        default: "https://sumit-puce.vercel.app"
    )

    /// Toggle paywall gating. When false, all parses/features are free (used for TestFlight before SKU creation).
    nonisolated static let paywallEnabled: Bool = false

    /// Max user text length sent to GPT (truncated server-side too).
    nonisolated static let maxParseInputChars: Int = 500

    /// Max image upload size in bytes.
    nonisolated static let maxImageUploadBytes: Int = 2 * 1024 * 1024

    /// Image long-edge after downscale.
    nonisolated static let imageMaxEdge: CGFloat = 1600

    /// Lock screen brute-force protection.
    nonisolated static let pinMaxAttempts = 5
    nonisolated static let pinLockoutSeconds: [TimeInterval] = [30, 120, 600, 3600]

    private nonisolated static func readPlist(_ key: String, default fallback: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallback
    }
}

/// Bridge legacy global to AppConfig. The right-hand side is nonisolated already,
/// so the global is too — no annotation needed.
let PAYWALL_ENABLED: Bool = AppConfig.paywallEnabled
