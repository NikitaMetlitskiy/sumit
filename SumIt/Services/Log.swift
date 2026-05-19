import Foundation
import os

/// Debug-only logger. Production builds emit nothing — keeps tokens, emails,
/// amounts and raw payloads out of TestFlight/App Store crash logs and Console.app.
/// All methods `nonisolated` so they can be called from any actor context.
enum Log {
    nonisolated private static let logger = Logger(subsystem: "com.mykyta.SumIt", category: "app")

    nonisolated static func debug(_ message: @autoclosure @escaping () -> String) {
        #if DEBUG
        let value = message()
        logger.debug("\(value, privacy: .private)")
        print(value)
        #endif
    }

    nonisolated static func info(_ message: @autoclosure @escaping () -> String) {
        #if DEBUG
        let value = message()
        logger.info("\(value, privacy: .private)")
        print(value)
        #endif
    }

    nonisolated static func warn(_ message: @autoclosure @escaping () -> String) {
        #if DEBUG
        let value = message()
        logger.warning("\(value, privacy: .private)")
        print(value)
        #endif
    }

    nonisolated static func error(_ message: @autoclosure @escaping () -> String) {
        // Errors are kept in release builds too, but body is marked private so PII is redacted in os_log dumps.
        let value = message()
        logger.error("\(value, privacy: .private)")
        #if DEBUG
        print(value)
        #endif
    }
}
