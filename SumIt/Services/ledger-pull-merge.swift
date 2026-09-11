import Foundation
import SwiftData

/// Reading side of the protocol. Kept in the same coordinator so push and pull
/// share one owner scope and one local persistence boundary.
extension LedgerSyncCoordinator {

    /// Applies every page of the owner's change feed through a fixed watermark.
    ///
    /// The restore this replaces fetched at most 1,000 rows, compared identity
    /// as **strings**, and constructed a brand-new model for anything it did not
    /// recognise — so a UUID that Swift had written in uppercase never matched
    /// the lowercase form and produced a second copy of the same transaction on
    /// every restore. Production still carries 32 of 70 rows in uppercase.
    ///
    /// Here identity is `(owner, kind, UUID)`, compared as UUID values; a page
    /// and the cursor it advances commit together, so an interrupted pull
    /// replays a page rather than skipping one; and a remote row is never
    /// dropped for being inconvenient.
    func pull(scope: AccountScope) async {
        guard !scope.isLocalOnly else { return }

        var cursor: Int64
        do { cursor = try checkpointCursor(ownerID: scope.ownerID) }
        catch { setPullError("checkpoint_read_failed"); return }

        var watermark: Int64?

        while !Task.isCancelled {
            let page: LedgerChangePage
            do {
                page = try await transportRead(after: cursor, through: watermark, scope: scope)
            } catch let error as LedgerTransportError {
                setPullError(pullCode(for: error))
                return
            } catch {
                setPullError("pull_failed")
                return
            }

            // The watermark is fixed for the whole run. A server that moved it
            // between pages would be able to hide a lower committed cursor.
            if let watermark, page.throughCursor.value != watermark {
                setPullError("watermark_moved")
                return
            }
            watermark = page.throughCursor.value

            guard page.nextCursor.value >= cursor else {
                setPullError("cursor_went_backwards")
                return
            }

            do {
                try applyPage(page, scope: scope)
            } catch {
                // The page did not land, so the cursor does not move. The next
                // attempt replays exactly this page.
                setPullError("page_apply_failed")
                return
            }

            cursor = page.nextCursor.value
            if !page.hasMore { break }
        }
        setPullError(nil)
    }

    // MARK: — One page, one transaction

    /// Applies every change in the page and advances the checkpoint in a single
    /// local commit. Either the whole page is visible with its new cursor, or
    /// none of it is and the cursor still points before it.
    private func applyPage(_ page: LedgerChangePage, scope: AccountScope) throws {
        for change in page.changes {
            try apply(change, scope: scope)
        }
        try advanceCheckpoint(to: page.nextCursor.value, ownerID: scope.ownerID)
        try commitPull()
    }

    private func apply(_ change: LedgerChange, scope: AccountScope) throws {
        let header = change.snapshot.header
        // Ownership is not inferred from the session: a row that does not say
        // whose it is, or says someone else's, is never adopted.
        guard header.userID == scope.ownerID else {
            throw LedgerWriteError.wrongScope
        }

        let revision = header.ledgerRevision.value
        let existing = try localRevision(kind: header.entityKind,
                                         entityID: header.localID,
                                         ownerID: scope.ownerID)

        // An event at or below what this row has already acknowledged is
        // history we have seen. Validate it, move on, never roll the row back.
        if let existing, existing >= revision {
            return
        }

        let isOwnOperation = try change.operationID.map {
            try isCompletedLocalOperation($0, ownerID: scope.ownerID)
        } ?? false

        if existing != nil,
           !isOwnOperation,
           try hasPendingWork(entityID: header.localID, ownerID: scope.ownerID) {
            // A different device changed the same entity while this one has an
            // unsent edit. Both candidates are kept; the user decides.
            try recordConflict(change, scope: scope)
            return
        }

        try materialize(change.snapshot, revision: revision, scope: scope, isOwnOperation: isOwnOperation)
    }

    // MARK: — Materializing a snapshot

    /// Also used by conflict resolution when the owner takes the server's version.
    func materialize(_ snapshot: LedgerSnapshot,
                     revision: Int64,
                     scope: AccountScope,
                     isOwnOperation: Bool) throws {
        switch snapshot {
        case .transaction(let value):
            try materializeTransaction(value, revision: revision, scope: scope, isOwnOperation: isOwnOperation)
        case .wallet(let value):
            try materializeWallet(value, revision: revision, scope: scope)
        case .category(let value):
            try materializeCategory(value, revision: revision, scope: scope)
        }
    }

    private func materializeTransaction(_ snapshot: TransactionSnapshotV1,
                                        revision: Int64,
                                        scope: AccountScope,
                                        isOwnOperation: Bool) throws {
        let identifier = snapshot.header.localID
        let owner = scope.ownerID
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.id == identifier && $0.userId == owner })
        let existing = try pullContext.fetch(descriptor).first

        let entity: Transaction
        if let existing {
            entity = existing
        } else {
            // The remote identity is reused, never regenerated. This is the
            // single line that stops a restore from duplicating history.
            entity = Transaction(id: identifier, userId: owner,
                                 originalAmount: 0, originalCurrency: snapshot.record.originalCurrency,
                                 amountInBase: 0, rateAtTime: 0,
                                 categoryName: snapshot.record.categoryName,
                                 merchant: snapshot.record.merchant)
            pullContext.insert(entity)
        }

        let record = snapshot.record
        entity.typeRaw = record.type
        entity.amountExact = record.originalAmount
        entity.originalCurrency = record.originalCurrency
        entity.baseAmountExact = record.baseAmount
        entity.rateExact = record.usdPerUnit
        entity.walletID = record.walletID
        entity.walletAmountExact = record.walletAmount
        entity.destinationWalletID = record.destinationWalletID
        entity.destinationAmountExact = record.destinationAmount
        entity.categoryName = record.categoryName
        entity.merchant = record.merchant
        entity.note = record.note
        // The instant the server holds, not the instant this device is at.
        entity.occurredAt = record.occurredAt
        entity.createdAt = snapshot.createdAt
        entity.sourceRaw = record.source
        entity.rawInput = record.rawInput
        entity.valuationStateRaw = record.valuationState.rawValue
        entity.quoteJSON = try record.quote.map { try JSONEncoder().encode($0) }
        entity.deletedAt = snapshot.header.deletedAt
        entity.serverRevision = revision
        entity.migrationState = .adopted
        entity.isSynced = true
        if let legacyName = snapshot.legacyWalletName { entity.walletName = legacyName }

        // Compatibility mirrors for views that have not migrated yet.
        entity.originalAmount = doubleMirror(record.originalAmount)
        entity.amountInBase = doubleMirror(record.baseAmount)
        entity.rateAtTime = doubleMirror(record.usdPerUnit)
        entity.confidence = doubleMirror(record.confidence)

        if !isOwnOperation { entity.localGeneration = 0 }

        // A row can legitimately arrive before the wallet it points at. It is
        // applied anyway and the gap is made visible, never silently dropped.
        for reference in [record.walletID, record.destinationWalletID].compactMap({ $0 }) {
            if try !walletExists(reference, ownerID: owner) {
                try recordIssue(kind: .invalidRemoteRow, entityKind: .transaction,
                                entityID: identifier, reason: "missing_wallet_reference",
                                localJSON: nil, remoteJSON: nil, scope: scope)
            }
        }
    }

    private func materializeWallet(_ snapshot: WalletSnapshotV1,
                                   revision: Int64,
                                   scope: AccountScope) throws {
        let identifier = snapshot.header.localID
        let owner = scope.ownerID
        let descriptor = FetchDescriptor<Wallet>(
            predicate: #Predicate { $0.id == identifier && $0.userId == owner })
        let existing = try pullContext.fetch(descriptor).first

        let entity: Wallet
        if let existing {
            entity = existing
        } else {
            entity = Wallet(id: identifier, userId: owner, name: snapshot.record.name,
                            currency: snapshot.record.currency)
            pullContext.insert(entity)
        }

        entity.name = snapshot.record.name
        entity.typeRaw = snapshot.record.type
        entity.currency = snapshot.record.currency
        entity.icon = snapshot.record.icon
        entity.openingBalanceExact = snapshot.record.openingBalance
        entity.createdAt = snapshot.createdAt
        entity.deletedAt = snapshot.header.deletedAt
        entity.serverRevision = revision
        entity.migrationState = .adopted
        entity.isSynced = true
    }

    private func materializeCategory(_ snapshot: CategorySnapshotV1,
                                     revision: Int64,
                                     scope: AccountScope) throws {
        let identifier = snapshot.header.localID
        let descriptor = FetchDescriptor<SumIt.Category>(predicate: #Predicate { $0.id == identifier })
        let existing = try pullContext.fetch(descriptor).first

        let entity: SumIt.Category
        if let existing {
            entity = existing
        } else {
            entity = SumIt.Category(id: identifier, name: snapshot.record.name,
                                    icon: snapshot.record.icon, colorHex: snapshot.record.colorHex,
                                    type: snapshot.record.type, isDefault: false,
                                    sortOrder: snapshot.record.sortOrder, ownerID: scope.ownerID)
            pullContext.insert(entity)
        }

        entity.name = snapshot.record.name
        entity.icon = snapshot.record.icon
        entity.colorHex = snapshot.record.colorHex
        entity.typeRaw = snapshot.record.type
        entity.sortOrder = snapshot.record.sortOrder
        entity.ownerID = scope.ownerID
        entity.deletedAt = snapshot.header.deletedAt
        entity.serverRevision = revision
    }

    private func doubleMirror(_ text: String?) -> Double {
        guard let text, let value = try? MoneyCodec.decode(text) else { return 0 }
        return NSDecimalNumber(decimal: value).doubleValue
    }
}

// MARK: — Pull support

extension LedgerSyncCoordinator {

    var pullContext: ModelContext { context }

    func setPullError(_ code: String?) { updatePullError(code) }

    func transportRead(after: Int64, through: Int64?, scope: AccountScope) async throws -> LedgerChangePage {
        try await transport.readLedgerChanges(after: after, through: through, limit: 250, scope: scope)
    }

    func commitPull() throws {
        do { try persist() }
        catch { throw LedgerWriteError.persistence(code: "pull_save_failed") }
    }

    // MARK: Checkpoint

    func checkpointCursor(ownerID: String) throws -> Int64 {
        let descriptor = FetchDescriptor<SyncCheckpoint>(predicate: #Predicate { $0.ownerID == ownerID })
        return try context.fetch(descriptor).first?.appliedCursor ?? 0
    }

    /// The checkpoint moves only inside the same commit as the page it belongs
    /// to. A crash between the two would otherwise skip a page permanently.
    func advanceCheckpoint(to cursor: Int64, ownerID: String) throws {
        let descriptor = FetchDescriptor<SyncCheckpoint>(predicate: #Predicate { $0.ownerID == ownerID })
        if let checkpoint = try context.fetch(descriptor).first {
            guard cursor >= checkpoint.appliedCursor else { return }
            checkpoint.appliedCursor = cursor
            checkpoint.updatedAt = now()
        } else {
            context.insert(SyncCheckpoint(ownerID: ownerID, appliedCursor: cursor, updatedAt: now()))
        }
    }

    // MARK: Local state lookups

    /// The revision this device has already acknowledged for an entity, or nil
    /// when it has never seen it.
    func localRevision(kind: LedgerEntityKind, entityID: UUID, ownerID: String) throws -> Int64? {
        switch kind {
        case .transaction:
            let descriptor = FetchDescriptor<Transaction>(
                predicate: #Predicate { $0.id == entityID && $0.userId == ownerID })
            return try context.fetch(descriptor).first?.serverRevision
        case .wallet:
            let descriptor = FetchDescriptor<Wallet>(
                predicate: #Predicate { $0.id == entityID && $0.userId == ownerID })
            return try context.fetch(descriptor).first?.serverRevision
        case .category:
            let descriptor = FetchDescriptor<SumIt.Category>(predicate: #Predicate { $0.id == entityID })
            return try context.fetch(descriptor).first?.serverRevision
        }
    }

    /// Recognising our own accepted operation coming back in the feed is what
    /// stops a device from reporting a conflict against itself.
    func isCompletedLocalOperation(_ operationID: UUID, ownerID: String) throws -> Bool {
        let completed = PendingMutationState.completed.rawValue
        let descriptor = FetchDescriptor<PendingMutation>(
            predicate: #Predicate { $0.operationID == operationID && $0.ownerID == ownerID
                                    && $0.stateRaw == completed })
        return try !context.fetch(descriptor).isEmpty
    }

    /// True when this device still has unsent or blocked work for the entity.
    func hasPendingWork(entityID: UUID, ownerID: String) throws -> Bool {
        let completed = PendingMutationState.completed.rawValue
        let descriptor = FetchDescriptor<PendingMutation>(
            predicate: #Predicate { $0.entityID == entityID && $0.ownerID == ownerID
                                    && $0.stateRaw != completed })
        return try !context.fetch(descriptor).isEmpty
    }

    func walletExists(_ walletID: UUID, ownerID: String) throws -> Bool {
        let descriptor = FetchDescriptor<Wallet>(
            predicate: #Predicate { $0.id == walletID && $0.userId == ownerID })
        return try !context.fetch(descriptor).isEmpty
    }

    // MARK: Issues

    /// A remote change met a local candidate. Both are preserved verbatim and
    /// the entity's queued work stops until the owner chooses.
    func recordConflict(_ change: LedgerChange, scope: AccountScope) throws {
        let entityID = change.snapshot.header.localID
        let owner = scope.ownerID
        let completed = PendingMutationState.completed.rawValue
        let descriptor = FetchDescriptor<PendingMutation>(
            predicate: #Predicate { $0.entityID == entityID && $0.ownerID == owner
                                    && $0.stateRaw != completed },
            sortBy: [SortDescriptor(\.createdAt)])
        let pending = try context.fetch(descriptor)

        try recordIssue(kind: .conflict,
                        entityKind: change.entityKind,
                        entityID: entityID,
                        reason: "remote_edit_meets_local_candidate",
                        localJSON: pending.first?.desiredSnapshotJSON,
                        remoteJSON: try? JSONEncoder().encode(change.snapshot),
                        scope: scope)

        for mutation in pending {
            mutation.state = .blocked
            mutation.lastErrorCode = "remote_edit_meets_local_candidate"
            mutation.updatedAt = now()
        }
    }

    func recordIssue(kind: SyncIssueKind, entityKind: LedgerEntityKind, entityID: UUID,
                     reason: String, localJSON: Data?, remoteJSON: Data?,
                     scope: AccountScope) throws {
        // One open issue per entity and reason; a repeated pull must not pile
        // duplicates in front of the user.
        let owner = scope.ownerID
        let descriptor = FetchDescriptor<SyncIssue>(
            predicate: #Predicate { $0.entityID == entityID && $0.ownerID == owner
                                    && $0.reason == reason && $0.resolvedAt == nil })
        guard try context.fetch(descriptor).isEmpty else { return }

        context.insert(SyncIssue(ownerID: owner, entityKind: entityKind, entityID: entityID,
                                 kind: kind, localSnapshotJSON: localJSON,
                                 remoteSnapshotJSON: remoteJSON, reason: reason,
                                 createdAt: now()))
    }

    func pullCode(for error: LedgerTransportError) -> String {
        switch error {
        case .configuration:             return "configuration"
        case .notAuthenticated:          return "not_authenticated"
        case .accessDenied:              return "access_denied"
        case .validationRejected(let c): return c
        case .retryable(let status, _):  return "retryable_\(status)"
        case .unreachable:               return "unreachable"
        case .unknownOutcome:            return "unknown_outcome"
        case .protocolMismatch:          return "protocol_mismatch"
        case .scopeChanged:              return "scope_changed"
        }
    }
}
