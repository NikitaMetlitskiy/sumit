import XCTest
import SwiftData
import CoreData
import CryptoKit
@testable import SumIt

/// Task 01 / P8. A persistent-store failure must be terminal and safe: no
/// writable substitute, no financial UI, and every original file left alone.
@MainActor
final class StorageBootstrapTests: XCTestCase {

    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories where FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sumit-storage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private struct InjectedError: Error {}

    // MARK: — A failed open is terminal

    func testForcedOpenErrorLeavesNoContainer() {
        let bootstrap = StorageBootstrap(storeURL: nil, openContainer: { throw InjectedError() })
        bootstrap.open()

        XCTAssertFalse(bootstrap.state.isReady)
        XCTAssertNil(bootstrap.state.container, "a failed open must not hand out any container")
        XCTAssertNotNil(bootstrap.state.failure)
    }

    /// The regression for the original bug: the old startup substituted an
    /// `isStoredInMemoryOnly` container and carried on. There must be no
    /// state in which the app has a writable container it did not open from disk.
    func testNoInMemoryFallbackIsEverProduced() {
        let bootstrap = StorageBootstrap(storeURL: nil, openContainer: { throw InjectedError() })
        bootstrap.open()
        bootstrap.retry()
        bootstrap.retry()
        XCTAssertNil(bootstrap.state.container)
    }

    func testStateStartsOpeningBeforeAnyAttempt() {
        let bootstrap = StorageBootstrap(storeURL: nil, openContainer: { throw InjectedError() })
        if case .opening = bootstrap.state {} else {
            XCTFail("bootstrap must start in .opening, not with a container")
        }
    }

    // MARK: — Failure classification and sanitization

    func testDiskFullIsClassified() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        XCTAssertEqual(StorageFailure(error: error).kind, .diskFull)
        XCTAssertEqual(StorageFailure(error: error).messageKey, "storage_error_disk_full")
    }

    func testPermissionsIsClassified() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        XCTAssertEqual(StorageFailure(error: error).kind, .permissions)
    }

    func testIncompatibleSchemaIsClassified() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSPersistentStoreIncompatibleVersionHashError)
        XCTAssertEqual(StorageFailure(error: error).kind, .incompatibleSchema)
        XCTAssertEqual(StorageFailure(error: error).messageKey, "storage_error_incompatible")
    }

    func testNestedUnderlyingErrorIsClassified() {
        let underlying = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        let wrapper = NSError(domain: "SwiftDataError", code: 1,
                              userInfo: [NSUnderlyingErrorKey: underlying])
        XCTAssertEqual(StorageFailure(error: wrapper).kind, .diskFull)
    }

    func testUnknownFailsSafelyRatherThanGuessing() {
        let error = NSError(domain: "Some.Other.Domain", code: 999)
        XCTAssertEqual(StorageFailure(error: error).kind, .unknown)
    }

    /// The diagnostic is shown on screen and may end up in a support message,
    /// so it must carry no file path, no user content and no credential.
    func testDiagnosticIsSanitized() throws {
        let directory = try makeTemporaryDirectory()
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError,
                            userInfo: [NSFilePathErrorKey: directory.path,
                                       NSLocalizedDescriptionKey: "merchant: Cafe, amount 12.50"])
        let diagnostic = StorageFailure(error: error).diagnostic
        XCTAssertEqual(diagnostic, "\(NSCocoaErrorDomain) \(NSFileWriteOutOfSpaceError)")
        XCTAssertFalse(diagnostic.contains(directory.path))
        XCTAssertFalse(diagnostic.contains("Cafe"))
        XCTAssertFalse(diagnostic.contains("12.50"))
    }

    // MARK: — One attempt at a time, and recovery

    func testOverlappingOpenAttemptsAreIgnored() {
        var attempts = 0
        var bootstrap: StorageBootstrap!
        bootstrap = StorageBootstrap(storeURL: nil, openContainer: {
            attempts += 1
            bootstrap.open()          // reentrant call from inside the attempt
            throw InjectedError()
        })
        bootstrap.open()
        XCTAssertEqual(attempts, 1, "a second open must not run while one is in flight")
    }

    func testRetrySucceedsAfterATransientFailure() throws {
        let directory = try makeTemporaryDirectory()
        let storeURL = directory.appendingPathComponent("retry.store")
        var shouldFail = true
        let bootstrap = StorageBootstrap(storeURL: storeURL, openContainer: {
            if shouldFail { throw InjectedError() }
            let configuration = ModelConfiguration(schema: StorageBootstrap.schema, url: storeURL)
            return try ModelContainer(for: StorageBootstrap.schema, configurations: configuration)
        })

        bootstrap.open()
        XCTAssertNil(bootstrap.state.container)

        shouldFail = false
        bootstrap.retry()
        XCTAssertNotNil(bootstrap.state.container, "Retry must be able to recover")
        XCTAssertTrue(bootstrap.state.isReady)
    }

    func testRetryIsANoOpOnceReady() throws {
        let directory = try makeTemporaryDirectory()
        let storeURL = directory.appendingPathComponent("ready.store")
        var attempts = 0
        let bootstrap = StorageBootstrap(storeURL: storeURL, openContainer: {
            attempts += 1
            let configuration = ModelConfiguration(schema: StorageBootstrap.schema, url: storeURL)
            return try ModelContainer(for: StorageBootstrap.schema, configurations: configuration)
        })
        bootstrap.open()
        bootstrap.retry()
        XCTAssertEqual(attempts, 1)
    }

    // MARK: — Recovery copy

    func testRecoveryCopyPreservesOriginalsAndHashesFiles() throws {
        let fixture = try PersistentStoreFixture.makeBaseline()
        defer { try? fixture.destroy() }
        let destination = try makeTemporaryDirectory().appendingPathComponent("copy", isDirectory: true)

        let bootstrap = StorageBootstrap(storeURL: fixture.storeURL,
                                         openContainer: { throw InjectedError() })
        bootstrap.open()
        let copy = try bootstrap.makeRecoveryCopy(into: destination)

        XCTAssertFalse(copy.files.isEmpty)
        XCTAssertTrue(copy.files.contains { $0.name == fixture.storeURL.lastPathComponent })

        for file in copy.files {
            let copied = destination.appendingPathComponent(file.name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path))
            let data = try Data(contentsOf: copied)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(file.sha256, digest, "hash must match the copied bytes")
            XCTAssertEqual(file.byteCount, data.count)

            // The original is still where it was.
            let original = URL(fileURLWithPath: fixture.storeURL.deletingLastPathComponent().path)
                .appendingPathComponent(file.name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: original.path),
                          "original \(file.name) must not be moved or deleted")
        }
    }

    /// Copying an open SQLite store can miss an uncheckpointed write-ahead log,
    /// producing a copy that is not the user's data.
    func testRecoveryCopyRefusesWhileTheStoreIsOpen() throws {
        let directory = try makeTemporaryDirectory()
        let storeURL = directory.appendingPathComponent("open.store")
        let bootstrap = StorageBootstrap(storeURL: storeURL, openContainer: {
            let configuration = ModelConfiguration(schema: StorageBootstrap.schema, url: storeURL)
            return try ModelContainer(for: StorageBootstrap.schema, configurations: configuration)
        })
        bootstrap.open()
        XCTAssertTrue(bootstrap.state.isReady)

        XCTAssertThrowsError(try bootstrap.makeRecoveryCopy(into: directory.appendingPathComponent("c"))) { error in
            XCTAssertEqual(error as? StorageRecoveryError, .storeIsOpen)
        }
    }

    func testRecoveryCopyReportsMissingStoreInsteadOfInventingOne() throws {
        let directory = try makeTemporaryDirectory()
        let bootstrap = StorageBootstrap(storeURL: directory.appendingPathComponent("absent.store"),
                                         openContainer: { throw InjectedError() })
        bootstrap.open()
        XCTAssertThrowsError(try bootstrap.makeRecoveryCopy(into: directory.appendingPathComponent("c"))) { error in
            XCTAssertEqual(error as? StorageRecoveryError, .noStoreOnDisk)
        }
    }

    /// No failure path may delete or truncate the store.
    func testFailedOpenDeletesNothing() throws {
        let fixture = try PersistentStoreFixture.makeBaseline()
        defer { try? fixture.destroy() }
        let before = try fixture.snapshot()
        let sizeBefore = try Data(contentsOf: fixture.storeURL).count

        let bootstrap = StorageBootstrap(storeURL: fixture.storeURL,
                                         openContainer: { throw InjectedError() })
        bootstrap.open()
        bootstrap.retry()

        XCTAssertEqual(try Data(contentsOf: fixture.storeURL).count, sizeBefore)
        try fixture.closeAndReopen()
        XCTAssertEqual(try fixture.snapshot(), before, "the fixture's data must be intact after a failed open")
    }

    // MARK: — Localization

    func testEveryRecoveryStringIsTranslatedInAllSixLanguages() {
        let keys = ["storage_error_title", "storage_data_preserved", "storage_retry",
                    "storage_save_copy", "storage_copy_failed"]
            + StorageFailure.Kind.allKeys
        for key in keys {
            let translations = LocalizationManager.translationsData[key]
            XCTAssertNotNil(translations, "missing translations for \(key)")
            for language in ["en", "uk", "ru", "es", "de", "pl"] {
                XCTAssertNotNil(translations?[language], "\(key) has no \(language) translation")
            }
        }
    }
}

private extension StorageFailure.Kind {
    static var allKeys: [String] {
        [StorageFailure.Kind.incompatibleSchema, .diskFull, .permissions, .unknown].map(\.messageKey)
    }
}
