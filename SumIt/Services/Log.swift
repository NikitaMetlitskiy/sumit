import Foundation
import os

/// Debug-only logger. Production builds emit nothing — keeps tokens, emails,
/// amounts and raw payloads out of TestFlight/App Store crash logs and Console.app.
enum Log {
    private static let logger = Logger(subsystem: "com.mykyta.SumIt", category: "app")

    static func debug(_ message: @autoclosure () -> String) {
        #if DEBUG
        logger.debug("\(message(), privacy: .private)")
        print(message())
        #endif
    }

    static func info(_ message: @autoclosure () -> String) {
        #if DEBUG
        logger.info("\(message(), privacy: .private)")
        print(message())
        #endif
    }

    static func warn(_ message: @autoclosure () -> String) {
        #if DEBUG
        logger.warning("\(message(), privacy: .private)")
        print(message())
        #endif
    }

    static func error(_ message: @autoclosure () -> String) {
        // Errors are kept in release builds too, but body is marked private so PII is redacted in os_log dumps.
        logger.error("\(message(), privacy: .private)")
        #if DEBUG
        print(message())
        #endif
    }
}
