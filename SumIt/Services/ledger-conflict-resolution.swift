import Foundation
import SwiftData

/// What the owner chose to do about a conflict.
enum ConflictResolution: String, CaseIterable, Sendable {
    /// Take the server's version. The local candidate is kept as a recoverable
    /// draft until the owner dismisses the issue.
    case useServer
    /// Send the local version again, as a new operation against the revision
    /// the server actually holds now.
    case keepLocal
    /// The server deleted this entity and the owner wants their version anyway:
    /// it is recorded as a **new** transaction with a new identity.
    case saveAsNew
}

extension LedgerSyncCoordinator {

    /// Applies the owner's decision. Money fields are never merged: one side
    /// wins wholesale, or a new record is created. There is no automatic
    /// resolution anywhere in this file.
    func resolve(issueID: UUID, with resolution: ConflictResolution, scope: AccountScope) throws {
        guard let issue = try issue(id: issueID, ownerID: scope.ownerID) else {
            throw LedgerWriteError.missingEntity(issueID)
        }
        guard issue.resolvedAt == nil else { return }

        switch resolution {
        case .useServer:  try applyServerVersion(issue, scope: scope)
        case .keepLocal:  try resendLocalVersion(issue, scope: scope)
        case .saveAsNew:  try saveLocalAsNewEntity(issue, scope: scope)
        }

        issue.resolvedAt = now()
        try commitPull()
    }

    /// Removes a resolved issue and, with it, the recoverable copy of whatever
    /// was discarded. Deliberately a separate, explicit step.
    func dismiss(issueID: UUID, scope: AccountScope) throws {
        guard let issue = try issue(id: issueID, ownerID: scope.ownerID) else { return }
        guard issue.resolvedAt != nil else {
            throw LedgerWriteError.validation(code: "issue_not_resolved")
        }
        context.delete(issue)
        try commitPull()
    }

    // MARK: — The three outcomes

    private func applyServerVersion(_ issue: SyncIssue, scope: AccountScope) throws {
        guard let snapshot = try remoteSnapshot(issue) else {
            throw LedgerWriteError.validation(code: "no_remote_candidate")
        }
        // The queued work for this entity is cancelled, not hidden: the local
        // candidate stays inside the issue until the owner dismisses it.
        try cancelQueuedWork(entityID: issue.entityID, ownerID: scope.ownerID)
        try materialize(snapshot, revision: snapshot.header.ledgerRevision.value,
                        scope: scope, isOwnOperation: false)
    }

    private func resendLocalVersion(_ issue: SyncIssue, scope: AccountScope) throws {
        guard let candidate = issue.localSnapshotJSON else {
            throw LedgerWriteError.validation(code: "no_local_candidate")
        }
        guard let snapshot = try remoteSnapshot(issue) else {
            throw LedgerWriteError.validation(code: "no_remote_candidate")
        }
        // A fresh write is made against the revision the server actually holds.
        // If another device writes again in the meantime this conflicts again,
        // which is correct: it is never a silent last-write-wins.
        try setAcknowledgedRevision(snapshot.header.ledgerRevision.value,
                                    kind: issue.entityKind,
                                    entityID: issue.entityID,
                                    ownerID: scope.ownerID)
        try cancelQueuedWork(entityID: issue.entityID, ownerID: scope.ownerID)

        let replacement = PendingMutation(ownerID: scope.ownerID,
                                          entityKind: issue.entityKind,
                                          entityID: issue.entityID,
                                          localGeneration: try currentLocalGeneration(
                                            kind: issue.entityKind,
                                            entityID: issue.entityID,
                                            ownerID: scope.ownerID),
                                          predecessorOperationID: nil,
                                          desiredSnapshotJSON: candidate,
                                          createdAt: now())
        context.insert(replacement)
    }

    private func saveLocalAsNewEntity(_ issue: SyncIssue, scope: AccountScope) throws {
        guard issue.entityKind == .transaction,
              let candidate = issue.localSnapshotJSON,
              let record = try? JSONDecoder().decode(TransactionRecordV1.self, from: candidate) else {
            throw LedgerWriteError.validation(code: "cannot_save_as_new")
        }

        // A new identity, because the old one belongs to a record the server
        // has deleted. Recreating it under the old id would resurrect a
        // tombstone, which the protocol refuses and the owner did not ask for.
        let newID = UUID()
        let entity = Transaction(id: newID, userId: scope.ownerID,
                                 type: TransactionType(rawValue: record.type) ?? .expense,
                                 originalAmount: 0, originalCurrency: record.originalCurrency,
                                 amountInBase: 0, rateAtTime: 0,
                                 categoryName: record.categoryName, merchant: record.merchant,
                                 note: record.note, occurredAt: record.occurredAt,
                                 source: TransactionSource(rawValue: record.source) ?? .manual,
                                 rawInput: record.rawInput, isSynced: false)
        entity.amountExact = record.originalAmount
        entity.walletID = record.walletID
        entity.walletAmountExact = record.walletAmount
        entity.destinationWalletID = record.destinationWalletID
        entity.destinationAmountExact = record.destinationAmount
        entity.baseAmountExact = record.baseAmount
        entity.rateExact = record.usdPerUnit
        entity.valuationStateRaw = record.valuationState.rawValue
        entity.quoteJSON = try record.quote.map { try JSONEncoder().encode($0) }
        entity.migrationState = .adopted
        entity.localGeneration = 1
        entity.originalAmount = (try? MoneyCodec.decode(record.originalAmount))
            .map { NSDecimalNumber(decimal: $0).doubleValue } ?? 0
        context.insert(entity)

        try cancelQueuedWork(entityID: issue.entityID, ownerID: scope.ownerID)

        // The original identity takes the server's version, tombstone included.
        if let snapshot = try remoteSnapshot(issue) {
            try materialize(snapshot, revision: snapshot.header.ledgerRevision.value,
                            scope: scope, isOwnOperation: false)
        }

        context.insert(PendingMutation(ownerID: scope.ownerID,
                                       entityKind: .transaction,
                                       entityID: newID,
                                       localGeneration: 1,
                                       desiredSnapshotJSON: candidate,
                                       createdAt: now()))
    }

    // MARK: — Helpers

    private func issue(id: UUID, ownerID: String) throws -> SyncIssue? {
        let descriptor = FetchDescriptor<SyncIssue>(
            predicate: #Predicate { $0.id == id && $0.ownerID == ownerID })
        return try context.fetch(descriptor).first
    }

    private func remoteSnapshot(_ issue: SyncIssue) throws -> LedgerSnapshot? {
        guard let data = issue.remoteSnapshotJSON else { return nil }
        return try? JSONDecoder().decode(LedgerSnapshot.self, from: data)
    }

    /// Drops every queued or blocked operation for an entity. The work is not
    /// lost: the issue holds the candidate until it is dismissed.
    private func cancelQueuedWork(entityID: UUID, ownerID: String) throws {
        let completed = PendingMutationState.completed.rawValue
        let descriptor = FetchDescriptor<PendingMutation>(
            predicate: #Predicate { $0.entityID == entityID && $0.ownerID == ownerID
                                    && $0.stateRaw != completed })
        for mutation in try context.fetch(descriptor) {
            context.delete(mutation)
        }
    }

    private func setAcknowledgedRevision(_ revision: Int64, kind: LedgerEntityKind,
                                         entityID: UUID, ownerID: String) throws {
        switch kind {
        case .transaction:
            let descriptor = FetchDescriptor<Transaction>(
                predicate: #Predicate { $0.id == entityID && $0.userId == ownerID })
            try context.fetch(descriptor).first?.serverRevision = revision
        case .wallet:
            let descriptor = FetchDescriptor<Wallet>(
                predicate: #Predicate { $0.id == entityID && $0.userId == ownerID })
            try context.fetch(descriptor).first?.serverRevision = revision
        case .category:
            let descriptor = FetchDescriptor<SumIt.Category>(predicate: #Predicate { $0.id == entityID })
            try context.fetch(descriptor).first?.serverRevision = revision
        }
    }

    private func currentLocalGeneration(kind: LedgerEntityKind, entityID: UUID,
                                        ownerID: String) throws -> Int64 {
        switch kind {
        case .transaction:
            let descriptor = FetchDescriptor<Transaction>(
                predicate: #Predicate { $0.id == entityID && $0.userId == ownerID })
            return try context.fetch(descriptor).first?.localGeneration ?? 1
        case .wallet:
            let descriptor = FetchDescriptor<Wallet>(
                predicate: #Predicate { $0.id == entityID && $0.userId == ownerID })
            return try context.fetch(descriptor).first?.localGeneration ?? 1
        case .category:
            let descriptor = FetchDescriptor<SumIt.Category>(predicate: #Predicate { $0.id == entityID })
            return try context.fetch(descriptor).first?.localGeneration ?? 1
        }
    }
}
