import Foundation
import SwiftData
import CoreData   // NSPersistentStore*/NSMigration* error codes
import Combine
import CryptoKit

// MARK: — Failure description

/// What went wrong opening the persistent store, in a form that is safe to
/// show and safe to log. It carries a classification and a localization key —
/// never credentials, file contents or a raw underlying description.
struct StorageFailure: Equatable, Sendable {

    enum Kind: String, Sendable {
        /// The store on disk was written by an incompatible schema.
        case incompatibleSchema
        /// The device has no room to open or migrate the store.
        case diskFull
        /// The process cannot read or write the store's files.
        case permissions
        /// Anything not recognised. Still fails safely.
        case unknown
    }

    let kind: Kind
    /// Localization key for the sentence shown to the user.
    let messageKey: String
    /// Domain and code only. Enough to tell two failures apart in a report,
    /// with nothing from the user's data in it.
    let diagnostic: String

    init(error: Error) {
        let nsError = error as NSError
        let kind = Self.classify(nsError)
        self.kind = kind
        self.messageKey = kind.messageKey
        self.diagnostic = "\(nsError.domain) \(nsError.code)"
    }

    init(kind: Kind, diagnostic: String) {
        self.kind = kind
        self.messageKey = kind.messageKey
        self.diagnostic = diagnostic
    }

    private static func classify(_ error: NSError) -> Kind {
        // Cocoa/CoreData codes surface through SwiftData for these cases.
        switch error.code {
        case NSFileWriteOutOfSpaceError, NSFileWriteVolumeReadOnlyError:
            return .diskFull
        case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
            return .permissions
        case NSPersistentStoreIncompatibleVersionHashError,
             NSMigrationError, NSMigrationMissingSourceModelError,
             NSMigrationMissingMappingModelError, NSPersistentStoreIncompatibleSchemaError:
            return .incompatibleSchema
        default:
            // The nested error is often the informative one.
            if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
               underlying !== error {
                return classify(underlying)
            }
            return .unknown
        }
    }
}

extension StorageFailure.Kind {
    var messageKey: String {
        switch self {
        case .incompatibleSchema: return "storage_error_incompatible"
        case .diskFull:           return "storage_error_disk_full"
        case .permissions:        return "storage_error_permissions"
        case .unknown:            return "storage_error_unknown"
        }
    }
}

// MARK: — Recovery copy

/// A copy of the store files the user explicitly asked for, with a hash per
/// file so a support conversation can tell whether the copy is intact.
struct RecoveryCopy: Equatable, Sendable {
    struct File: Equatable, Sendable {
        let name: String
        let byteCount: Int
        /// Lowercase hex SHA-256 of the copied file.
        let sha256: String
    }
    let directory: URL
    let files: [File]
}

enum StorageRecoveryError: Error, Equatable {
    /// A copy may only be made while the store is closed.
    case storeIsOpen
    /// There is no store file to copy.
    case noStoreOnDisk
}

// MARK: — Bootstrap

/// Owns the one attempt to open the app's persistent store.
///
/// The previous startup caught an open failure and substituted an
/// `isStoredInMemoryOnly` container, then built the normal UI on top of it —
/// so the app looked healthy while every save went to memory and disappeared
/// on quit. Here a failure is a terminal state: no container, no writable
/// substitute, no financial UI, and the files on disk are left untouched.
@MainActor
final class StorageBootstrap: ObservableObject {

    enum State {
        case opening
        case ready(ModelContainer)
        case failed(StorageFailure)

        var container: ModelContainer? {
            if case .ready(let container) = self { return container }
            return nil
        }
        var failure: StorageFailure? {
            if case .failed(let failure) = self { return failure }
            return nil
        }
        var isReady: Bool { container != nil }
    }

    /// The current schema, taken from the versioned definition so the app and
    /// its migration plan can never drift apart.
    static let schema = Schema(versionedSchema: SumItSchemaV2.self)

    @Published private(set) var state: State = .opening

    /// Where the store lives. Resolved **before** any migration attempt, so a
    /// failed open can still point at the right files for a recovery copy.
    let storeURL: URL?

    private var isOpening = false
    private let openContainer: () throws -> ModelContainer

    /// - Parameter openContainer: injected in tests to force a failure. Production
    ///   passes nil and gets the real container.
    init(storeURL: URL? = nil, openContainer: (() throws -> ModelContainer)? = nil) {
        let resolvedURL = storeURL ?? Self.defaultStoreURL()
        self.storeURL = resolvedURL
        self.openContainer = openContainer ?? {
            let configuration: ModelConfiguration = resolvedURL.map {
                ModelConfiguration(schema: Self.schema, url: $0)
            } ?? ModelConfiguration(schema: Self.schema, isStoredInMemoryOnly: false)
            // A V1 store on a user's device is upgraded here. A migration that
            // fails must reach the recovery screen, never a fresh empty store.
            return try ModelContainer(for: Self.schema,
                                      migrationPlan: SumItMigrationPlan.self,
                                      configurations: configuration)
        }
    }

    /// The URL SwiftData would use by default, resolved without opening anything.
    static func defaultStoreURL() -> URL? {
        ModelConfiguration(schema: schema, isStoredInMemoryOnly: false).url
    }

    /// Attempts to open the store. Safe to call repeatedly; overlapping calls
    /// are ignored rather than racing two migrations against the same files.
    func open() {
        guard !isOpening else { return }
        isOpening = true
        defer { isOpening = false }
        do {
            state = .ready(try openContainer())
        } catch {
            Log.error("SwiftData open failed")
            state = .failed(StorageFailure(error: error))
        }
    }

    /// User-initiated Retry from the recovery screen.
    func retry() {
        guard !state.isReady else { return }
        state = .opening
        open()
    }

    // MARK: Recovery copy

    /// Copies the store and its sidecar files into `directory`.
    ///
    /// Only ever called from an explicit user action: the app never exports a
    /// user's financial database on its own. It refuses to run while a
    /// container is open, because copying an open SQLite store with an
    /// uncheckpointed write-ahead log produces a copy that is not the data.
    @discardableResult
    func makeRecoveryCopy(into directory: URL) throws -> RecoveryCopy {
        guard !state.isReady else { throw StorageRecoveryError.storeIsOpen }
        guard let storeURL, FileManager.default.fileExists(atPath: storeURL.path) else {
            throw StorageRecoveryError.noStoreOnDisk
        }

        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)

        // The main file plus SQLite's write-ahead log and shared memory file.
        // A copy missing -wal can be missing the most recent transactions.
        let sources = [storeURL,
                       URL(fileURLWithPath: storeURL.path + "-wal"),
                       URL(fileURLWithPath: storeURL.path + "-shm")]

        var files: [RecoveryCopy.File] = []
        for source in sources where manager.fileExists(atPath: source.path) {
            let destination = directory.appendingPathComponent(source.lastPathComponent)
            if manager.fileExists(atPath: destination.path) {
                try manager.removeItem(at: destination)
            }
            try manager.copyItem(at: source, to: destination)
            let data = try Data(contentsOf: destination)
            files.append(RecoveryCopy.File(name: source.lastPathComponent,
                                           byteCount: data.count,
                                           sha256: Self.hex(SHA256.hash(data: data))))
        }
        // The originals are never moved, renamed or deleted by this method.
        return RecoveryCopy(directory: directory, files: files)
    }

    private static func hex(_ digest: SHA256Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: — Launch construction

extension StorageBootstrap {
    /// The bootstrap the app launches with. In a Debug build it honours the UI
    /// test hooks below; a Release build always gets the plain one.
    static func makeForLaunch() -> StorageBootstrap {
        #if DEBUG
        if UITestHooks.isActive { return UITestHooks.makeBootstrap() }
        #endif
        return StorageBootstrap()
    }
}

#if DEBUG
/// Hooks that let a UI test drive a storage failure deliberately.
///
/// Debug-only on purpose: a shipping build has no way to be told to fail its
/// own database. They also use a throwaway store in the temporary directory,
/// so a UI test can never touch a real user's data.
extension StorageBootstrap {
    enum UITestHooks {
        private static var arguments: [String] { ProcessInfo.processInfo.arguments }

        static var isActive: Bool { arguments.contains("-SumItUITest") }
        static var failsFirstOpen: Bool { arguments.contains("-SumItFailStorageOpenOnce") }
        static var seedsBaseline: Bool { arguments.contains("-SumItSeedBaseline") }

        static var storeURL: URL {
            URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("sumit-uitest.store")
        }

        nonisolated(unsafe) private static var firstOpenConsumed = false

        static func makeBootstrap() -> StorageBootstrap {
            // Start every UI test run from a clean throwaway store.
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: storeURL.path + suffix)
            }
            firstOpenConsumed = false
            let url = storeURL
            return StorageBootstrap(storeURL: url, openContainer: {
                if failsFirstOpen && !firstOpenConsumed {
                    firstOpenConsumed = true
                    throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
                }
                let configuration = ModelConfiguration(schema: StorageBootstrap.schema, url: url)
                return try ModelContainer(for: StorageBootstrap.schema, configurations: configuration)
            })
        }

        /// Inserts one known expense so a UI test can assert the exact amount
        /// that survived the failure and retry. Runs at most once.
        @MainActor
        static func seedIfRequested(_ container: ModelContainer) {
            guard isActive, seedsBaseline else { return }
            let context = ModelContext(container)
            let existing = (try? context.fetchCount(FetchDescriptor<Transaction>())) ?? 0
            guard existing == 0 else { return }

            let wallet = Wallet(userId: "local", name: "Monobank", type: .bank,
                                currency: "USD", balance: 1000)
            let transaction = Transaction(userId: "local", type: .expense,
                                          originalAmount: 12.50, originalCurrency: "USD",
                                          amountInBase: 12.50, rateAtTime: 1.0,
                                          categoryName: "Food", merchant: "Cafe",
                                          walletName: "Monobank")
            context.insert(wallet)
            context.insert(transaction)
            try? context.save()
        }
    }
}
#endif
