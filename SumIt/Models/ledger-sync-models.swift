import Foundation
import SwiftData

// MARK: — Pending mutation

enum PendingMutationState: String, Codable, Sendable, CaseIterable {
    /// Created locally, not yet dispatched. Its request bytes are not frozen yet.
    case queued
    /// Dispatch has begun. `frozenRequestJSON` is immutable from here on.
    case inFlight = "in_flight"
    /// Server accepted it and the acknowledgment is persisted locally.
    case completed
    /// Held back by a conflict or a failed dependency. Never silently dropped.
    case blocked
}

/// One durable intent to change the server's copy of an entity.
///
/// The queue is a persisted model, not a `Task` collection or a `UserDefaults`
/// list: an operation must survive a crash, a force quit and a reboot, because
/// that is the whole point of promising the user their edit is not lost.
@Model
final class PendingMutation {
    /// Immutable identity of this operation. Retrying reuses it, which is what
    /// lets the server's receipt recognise a replay instead of writing twice.
    var operationID: UUID
    var ownerID: String
    var entityKindRaw: String
    var entityID: UUID
    /// The local generation of the entity this operation describes.
    var localGeneration: Int64
    /// The operation that must be acknowledged before this one may dispatch.
    var predecessorOperationID: UUID?
    /// The entity as this operation wants it, for display and for building the
    /// request. Superseded by `frozenRequestJSON` once dispatch begins.
    var desiredSnapshotJSON: Data?
    /// The exact bytes sent. A newer local edit must never rewrite them.
    var frozenRequestJSON: Data?
    var stateRaw: String
    var attemptCount: Int
    var nextAttemptAt: Date?
    /// Status or error code only — never a receipt, note, merchant or token.
    var lastErrorCode: String?
    var createdAt: Date
    var updatedAt: Date

    var entityKind: LedgerEntityKind {
        get { LedgerEntityKind(rawValue: entityKindRaw) ?? .transaction }
        set { entityKindRaw = newValue.rawValue }
    }

    var state: PendingMutationState {
        get { PendingMutationState(rawValue: stateRaw) ?? .queued }
        set { stateRaw = newValue.rawValue }
    }

    init(operationID: UUID = UUID(),
         ownerID: String,
         entityKind: LedgerEntityKind,
         entityID: UUID,
         localGeneration: Int64,
         predecessorOperationID: UUID? = nil,
         desiredSnapshotJSON: Data? = nil,
         state: PendingMutationState = .queued,
         createdAt: Date = .now) {
        self.operationID = operationID
        self.ownerID = ownerID
        self.entityKindRaw = entityKind.rawValue
        self.entityID = entityID
        self.localGeneration = localGeneration
        self.predecessorOperationID = predecessorOperationID
        self.desiredSnapshotJSON = desiredSnapshotJSON
        self.frozenRequestJSON = nil
        self.stateRaw = state.rawValue
        self.attemptCount = 0
        self.nextAttemptAt = nil
        self.lastErrorCode = nil
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }
}

// MARK: — Sync checkpoint

/// How far this device has durably applied the owner's change feed.
/// The cursor and the page that produced it are committed together, so a crash
/// mid-pull replays a page rather than skipping one.
@Model
final class SyncCheckpoint {
    var ownerID: String
    /// Stored as Int64; the wire form is a decimal string (see `LedgerCursor`).
    var appliedCursor: Int64
    /// Which adoption step this account has reached on this device.
    var adoptionVersion: Int
    var updatedAt: Date

    init(ownerID: String, appliedCursor: Int64 = 0, adoptionVersion: Int = 0, updatedAt: Date = .now) {
        self.ownerID = ownerID
        self.appliedCursor = appliedCursor
        self.adoptionVersion = adoptionVersion
        self.updatedAt = updatedAt
    }
}

// MARK: — Sync issue

enum SyncIssueKind: String, Codable, Sendable, CaseIterable {
    /// Two devices changed the same entity; the user must choose.
    case conflict
    /// A pre-ledger record whose identity or meaning cannot be resolved safely.
    case legacyAmbiguity = "legacy_ambiguity"
    /// A remote row that failed validation and must not be applied.
    case invalidRemoteRow = "invalid_remote_row"
}

/// Something that needs the owner's decision. This is the durable basis of the
/// recovery and conflict UI — not telemetry, and never resolved automatically.
@Model
final class SyncIssue {
    var id: UUID
    var ownerID: String
    var entityKindRaw: String
    var entityID: UUID
    var kindRaw: String
    /// The local candidate, preserved even when the server version wins, so a
    /// discarded edit stays recoverable until the user dismisses it.
    var localSnapshotJSON: Data?
    var remoteSnapshotJSON: Data?
    /// A short machine reason, e.g. `revision_mismatch`. No financial payload.
    var reason: String
    var createdAt: Date
    var resolvedAt: Date?

    var kind: SyncIssueKind {
        get { SyncIssueKind(rawValue: kindRaw) ?? .conflict }
        set { kindRaw = newValue.rawValue }
    }

    var entityKind: LedgerEntityKind {
        get { LedgerEntityKind(rawValue: entityKindRaw) ?? .transaction }
        set { entityKindRaw = newValue.rawValue }
    }

    init(id: UUID = UUID(),
         ownerID: String,
         entityKind: LedgerEntityKind,
         entityID: UUID,
         kind: SyncIssueKind,
         localSnapshotJSON: Data? = nil,
         remoteSnapshotJSON: Data? = nil,
         reason: String,
         createdAt: Date = .now) {
        self.id = id
        self.ownerID = ownerID
        self.entityKindRaw = entityKind.rawValue
        self.entityID = entityID
        self.kindRaw = kind.rawValue
        self.localSnapshotJSON = localSnapshotJSON
        self.remoteSnapshotJSON = remoteSnapshotJSON
        self.reason = reason
        self.createdAt = createdAt
        self.resolvedAt = nil
    }
}

// MARK: — Cached rate quote

/// A rate the app has seen, kept so an offline device can still show and reuse
/// a dated valuation. Quote rows are immutable: a refresh inserts a new row
/// rather than rewriting the one a saved transaction already points at.
@Model
final class CachedRateQuote {
    /// Server-issued quote identity, when the quote came from a provider.
    var quoteID: UUID?
    var currency: String
    /// Canonical decimal string: USD per one unit of `currency`.
    var usdPerUnitExact: String
    /// ISO day requested, or nil for a current quote.
    var requestedDate: String?
    var effectiveAt: Date
    var fetchedAt: Date
    var source: String
    var valuationKindRaw: String
    var sourceDetailJSON: Data?
    /// When this cache row stops being usable as a *current* rate. A quote that
    /// is already attached to a saved transaction is never invalidated by it.
    var expiresAt: Date?

    var valuationKind: ValuationKind {
        get { ValuationKind(rawValue: valuationKindRaw) ?? .manual }
        set { valuationKindRaw = newValue.rawValue }
    }

    init(quoteID: UUID?,
         currency: String,
         usdPerUnitExact: String,
         requestedDate: String?,
         effectiveAt: Date,
         fetchedAt: Date,
         source: String,
         valuationKind: ValuationKind,
         sourceDetailJSON: Data? = nil,
         expiresAt: Date? = nil) {
        self.quoteID = quoteID
        self.currency = currency
        self.usdPerUnitExact = usdPerUnitExact
        self.requestedDate = requestedDate
        self.effectiveAt = effectiveAt
        self.fetchedAt = fetchedAt
        self.source = source
        self.valuationKindRaw = valuationKind.rawValue
        self.sourceDetailJSON = sourceDetailJSON
        self.expiresAt = expiresAt
    }
}
