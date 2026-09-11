import Foundation
import SwiftData
import Combine

/// The transport the coordinator talks to. `SupabaseService` satisfies it in
/// production; tests supply a fake so no unit test touches the network.
protocol LedgerTransport: Sendable {
    func applyLedgerMutation(_ request: LedgerMutationRequest,
                             scope: AccountScope) async throws -> LedgerMutationResult
    func readLedgerChanges(after: Int64, through: Int64?, limit: Int,
                           scope: AccountScope) async throws -> LedgerChangePage
}

extension SupabaseService: LedgerTransport {}

/// Sends queued mutations, one owner at a time, and records what came back.
///
/// The path this replaces was a fire-and-forget `Task` per save that called
/// Supabase and, on success, flipped `isSynced`. Nothing survived a relaunch,
/// nothing retried, ordering was whatever the scheduler chose, and a failure
/// was a log line. Here the queue is on disk, the request bytes are frozen
/// before dispatch, an acknowledgment is itself a durable write, and no
/// operation is ever discarded because it failed too often.
@MainActor
final class LedgerSyncCoordinator: ObservableObject {

    /// What the UI needs to tell the truth about sync state.
    @Published private(set) var isRunning = false
    @Published private(set) var pendingCount = 0
    @Published private(set) var blockedCount = 0
    /// Machine code of the last transport failure, or nil. Never a payload.
    @Published private(set) var lastErrorCode: String?
    /// Machine code of the last pull failure, or nil.
    @Published private(set) var lastPullErrorCode: String?

    let context: ModelContext
    let transport: LedgerTransport
    let now: @MainActor () -> Date
    let persist: () throws -> Void

    private var task: Task<Void, Never>?

    /// Backoff ladder in seconds; the last value repeats. Jitter is applied on
    /// top so a fleet of devices coming back online does not synchronise.
    static let backoff: [TimeInterval] = [2, 10, 30, 120, 300]

    init(context: ModelContext,
         transport: LedgerTransport = SupabaseService.shared,
         now: @escaping @MainActor () -> Date = { Date() },
         persist: (() throws -> Void)? = nil) {
        self.context = context
        self.transport = transport
        self.now = now
        self.persist = persist ?? { [context] in try context.save() }
        refreshCounts()
    }

    // MARK: — Control

    /// Coalesces triggers: startup, foreground, a local commit and an explicit
    /// Retry all land here, and only one dispatcher ever runs.
    func trigger(scope: AccountScope) {
        guard task == nil else { return }
        guard !scope.isLocalOnly else { return }   // the signed-out dataset is never dispatched
        isRunning = true
        task = Task { @MainActor in
            await run(scope: scope)
            task = nil
            isRunning = false
            refreshCounts()
        }
    }

    /// Waits for the current dispatcher to finish. Used by tests, and by any
    /// caller that needs the queue quiescent before it inspects it.
    func waitUntilIdle() async {
        await task?.value
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    /// Explicit user Retry for one operation: clears its wait and its error, and
    /// releases it if it was blocked. It never rewrites the frozen request.
    func retry(operationID: UUID, scope: AccountScope) throws {
        guard let mutation = try mutation(operationID: operationID, ownerID: scope.ownerID) else {
            throw LedgerWriteError.missingEntity(operationID)
        }
        mutation.nextAttemptAt = nil
        mutation.lastErrorCode = nil
        mutation.attemptCount = 0
        if mutation.state == .blocked { mutation.state = .queued }
        mutation.updatedAt = now()
        try commit()
        trigger(scope: scope)
    }

    // MARK: — The loop

    private func run(scope: AccountScope) async {
        while !Task.isCancelled {
            let next: PendingMutation?
            do { next = try nextEligible(scope: scope) }
            catch { lastErrorCode = "queue_read_failed"; return }

            guard let mutation = next else { return }   // nothing to do right now

            let request: LedgerMutationRequest
            do { request = try freeze(mutation, scope: scope) }
            catch let error as LedgerWriteError {
                // A malformed queue entry must not spin: park it for the user.
                block(mutation, code: error.code)
                try? commit()
                continue
            } catch {
                lastErrorCode = "freeze_failed"
                return
            }

            do {
                let result = try await transport.applyLedgerMutation(request, scope: scope)
                guard !Task.isCancelled else { return }
                try acknowledge(result, operationID: mutation.operationID, scope: scope)
                lastErrorCode = nil
            } catch let error as LedgerTransportError {
                let shouldContinue = handle(error, mutation: mutation)
                guard shouldContinue else { return }
            } catch {
                // A local persistence failure stops sync entirely: continuing
                // would mean sending operations we cannot record the answers to.
                lastErrorCode = "local_write_failed"
                return
            }
            refreshCounts()
        }
    }

    // MARK: — Eligibility

    /// The next operation that may be dispatched: this owner's, not completed,
    /// past its wait, whose predecessor is acknowledged and whose referenced
    /// wallets and categories already exist on the server.
    private func nextEligible(scope: AccountScope) throws -> PendingMutation? {
        let owner = scope.ownerID
        let completed = PendingMutationState.completed.rawValue
        let blocked = PendingMutationState.blocked.rawValue
        let descriptor = FetchDescriptor<PendingMutation>(
            predicate: #Predicate { $0.ownerID == owner && $0.stateRaw != completed && $0.stateRaw != blocked },
            sortBy: [SortDescriptor(\.createdAt)])
        let candidates = try context.fetch(descriptor)
        let currentTime = now()

        for candidate in candidates {
            if let waitUntil = candidate.nextAttemptAt, waitUntil > currentTime { continue }
            if try !predecessorSatisfied(candidate, ownerID: owner) { continue }
            if try !dependenciesSatisfied(candidate, ownerID: owner) { continue }
            return candidate
        }
        return nil
    }

    private func predecessorSatisfied(_ mutation: PendingMutation, ownerID: String) throws -> Bool {
        guard let predecessorID = mutation.predecessorOperationID else { return true }
        guard let predecessor = try self.mutation(operationID: predecessorID, ownerID: ownerID) else {
            return true      // already completed and pruned
        }
        return predecessor.state == .completed
    }

    /// A transaction cannot be sent while a wallet or category it references is
    /// still waiting to be created: the server would reject the reference.
    private func dependenciesSatisfied(_ mutation: PendingMutation, ownerID: String) throws -> Bool {
        guard mutation.entityKind == .transaction,
              let payload = mutation.desiredSnapshotJSON,
              let record = try? JSONDecoder().decode(TransactionRecordV1.self, from: payload) else {
            return true
        }
        for reference in [record.walletID, record.destinationWalletID].compactMap({ $0 }) {
            let completed = PendingMutationState.completed.rawValue
            let descriptor = FetchDescriptor<PendingMutation>(
                predicate: #Predicate { $0.ownerID == ownerID && $0.entityID == reference && $0.stateRaw != completed })
            if try !context.fetch(descriptor).isEmpty { return false }
        }
        return true
    }

    // MARK: — Freezing

    /// Builds the request once and stores it. A later local edit appends a new
    /// operation; it can never mutate these bytes.
    ///
    /// The server keeps the request as `jsonb` and compares a replay with `=`,
    /// which is a value comparison rather than a textual one, so re-encoding the
    /// same values on a retry is safe. What must not change is the *content*.
    private func freeze(_ mutation: PendingMutation, scope: AccountScope) throws -> LedgerMutationRequest {
        guard mutation.ownerID == scope.ownerID else { throw LedgerWriteError.wrongScope }

        if let frozen = mutation.frozenRequestJSON,
           let request = try? JSONDecoder().decode(LedgerMutationRequest.self, from: frozen) {
            // A restart or a retry replays the exact operation. The attempt
            // count still advances: it drives the backoff ladder, and counting
            // only the first freeze would pin every retry to the first rung
            // forever. It is a counter, never a limit — nothing is discarded
            // at any value.
            mutation.attemptCount += 1
            mutation.updatedAt = now()
            try commit()
            return request
        }

        let action: LedgerAction = mutation.desiredSnapshotJSON == nil ? .delete : .put
        let record = try decodeRecord(mutation)
        let expected = try acknowledgedRevision(for: mutation)

        let request = LedgerMutationRequest(
            protocolVersion: 1,
            operationID: mutation.operationID,
            entityKind: mutation.entityKind,
            entityID: mutation.entityID,
            action: action,
            expectedRevision: try LedgerCursor(expected),
            record: record)

        guard let encoded = try? JSONEncoder().encode(request) else {
            throw LedgerWriteError.validation(code: "encode_failed")
        }
        mutation.frozenRequestJSON = encoded
        mutation.state = .inFlight
        mutation.attemptCount += 1
        mutation.updatedAt = now()
        // Frozen and in-flight reach the disk *before* the request goes out, so
        // a crash between here and the response still replays the same bytes.
        try commit()
        return request
    }

    private func decodeRecord(_ mutation: PendingMutation) throws -> LedgerRecord? {
        guard let payload = mutation.desiredSnapshotJSON else { return nil }
        let decoder = JSONDecoder()
        do {
            switch mutation.entityKind {
            case .transaction: return .transaction(try decoder.decode(TransactionRecordV1.self, from: payload))
            case .wallet:      return .wallet(try decoder.decode(WalletRecordV1.self, from: payload))
            case .category:    return .category(try decoder.decode(CategoryRecordV1.self, from: payload))
            }
        } catch {
            throw LedgerWriteError.validation(code: "queued_record_unreadable")
        }
    }

    /// The revision the server last acknowledged for this entity — the base a
    /// compare-and-set write must be made against.
    private func acknowledgedRevision(for mutation: PendingMutation) throws -> Int64 {
        let entityID = mutation.entityID
        let owner = mutation.ownerID
        switch mutation.entityKind {
        case .transaction:
            let descriptor = FetchDescriptor<Transaction>(
                predicate: #Predicate { $0.id == entityID && $0.userId == owner })
            return try context.fetch(descriptor).first?.serverRevision ?? 0
        case .wallet:
            let descriptor = FetchDescriptor<Wallet>(
                predicate: #Predicate { $0.id == entityID && $0.userId == owner })
            return try context.fetch(descriptor).first?.serverRevision ?? 0
        case .category:
            let descriptor = FetchDescriptor<SumIt.Category>(predicate: #Predicate { $0.id == entityID })
            return try context.fetch(descriptor).first?.serverRevision ?? 0
        }
    }

    // MARK: — Acknowledgment

    /// One local transaction: complete this operation, record the accepted
    /// revision, and update the visible entity **only** if it still holds the
    /// generation the server accepted.
    private func acknowledge(_ result: LedgerMutationResult,
                             operationID: UUID,
                             scope: AccountScope) throws {
        guard let mutation = try mutation(operationID: operationID, ownerID: scope.ownerID) else {
            throw LedgerWriteError.missingEntity(operationID)
        }

        switch result {
        case .accepted(let accepted):
            let generationMatches = try currentGeneration(for: mutation) == mutation.localGeneration
            try recordAccepted(revision: accepted.revision.value,
                               mutation: mutation,
                               markSynced: generationMatches)
            mutation.state = .completed
            mutation.lastErrorCode = nil

        case .conflict(let conflict):
            // The server's version differs. Both candidates are kept and the
            // user decides; nothing is merged automatically.
            let issue = SyncIssue(ownerID: scope.ownerID,
                                  entityKind: mutation.entityKind,
                                  entityID: mutation.entityID,
                                  kind: .conflict,
                                  localSnapshotJSON: mutation.desiredSnapshotJSON,
                                  remoteSnapshotJSON: try? JSONEncoder().encode(conflict.serverSnapshot),
                                  reason: conflict.reason,
                                  createdAt: now())
            context.insert(issue)
            block(mutation, code: conflict.reason)
            try blockDescendants(of: mutation)
        }

        mutation.updatedAt = now()
        try commit()
    }

    /// Sets the acknowledged base revision, and marks the row synced only when
    /// the generation the server accepted is still the current one. A newer
    /// local edit keeps its pending status and its own values.
    private func recordAccepted(revision: Int64, mutation: PendingMutation, markSynced: Bool) throws {
        let entityID = mutation.entityID
        let owner = mutation.ownerID
        switch mutation.entityKind {
        case .transaction:
            let descriptor = FetchDescriptor<Transaction>(
                predicate: #Predicate { $0.id == entityID && $0.userId == owner })
            guard let entity = try context.fetch(descriptor).first else { return }
            entity.serverRevision = revision
            if markSynced { entity.isSynced = true }
        case .wallet:
            let descriptor = FetchDescriptor<Wallet>(
                predicate: #Predicate { $0.id == entityID && $0.userId == owner })
            guard let entity = try context.fetch(descriptor).first else { return }
            entity.serverRevision = revision
            if markSynced { entity.isSynced = true }
        case .category:
            let descriptor = FetchDescriptor<SumIt.Category>(predicate: #Predicate { $0.id == entityID })
            guard let entity = try context.fetch(descriptor).first else { return }
            entity.serverRevision = revision
        }
    }

    private func currentGeneration(for mutation: PendingMutation) throws -> Int64 {
        let entityID = mutation.entityID
        let owner = mutation.ownerID
        switch mutation.entityKind {
        case .transaction:
            let descriptor = FetchDescriptor<Transaction>(
                predicate: #Predicate { $0.id == entityID && $0.userId == owner })
            return try context.fetch(descriptor).first?.localGeneration ?? 0
        case .wallet:
            let descriptor = FetchDescriptor<Wallet>(
                predicate: #Predicate { $0.id == entityID && $0.userId == owner })
            return try context.fetch(descriptor).first?.localGeneration ?? 0
        case .category:
            let descriptor = FetchDescriptor<SumIt.Category>(predicate: #Predicate { $0.id == entityID })
            return try context.fetch(descriptor).first?.localGeneration ?? 0
        }
    }

    // MARK: — Failure handling

    /// Returns true when the loop may go on to another operation.
    private func handle(_ error: LedgerTransportError, mutation: PendingMutation) -> Bool {
        lastErrorCode = code(for: error)
        switch error {
        case .retryable(_, let retryAfter):
            schedule(mutation, after: retryAfter ?? backoffDelay(for: mutation), code: lastErrorCode)
            try? commit()
            return false          // stop this pass; the next trigger picks it up

        case .unreachable:
            schedule(mutation, after: backoffDelay(for: mutation), code: "unreachable")
            try? commit()
            return false

        case .unknownOutcome:
            // The server may have committed. The same operation is replayed and
            // the receipt resolves it; it is never abandoned.
            schedule(mutation, after: backoffDelay(for: mutation), code: "unknown_outcome")
            try? commit()
            return false

        case .notAuthenticated:
            schedule(mutation, after: nil, code: "not_authenticated")
            try? commit()
            return false

        case .scopeChanged:
            // The queue belongs to the previous account and stays for its own
            // session; nothing from it may touch the account now signed in.
            return false

        case .accessDenied, .validationRejected, .protocolMismatch, .configuration:
            block(mutation, code: code(for: error))
            try? blockDescendants(of: mutation)
            try? commit()
            return true           // other, independent entities may still sync
        }
    }

    private func schedule(_ mutation: PendingMutation, after delay: TimeInterval?, code: String?) {
        mutation.state = .queued
        mutation.lastErrorCode = code
        mutation.nextAttemptAt = delay.map { now().addingTimeInterval($0) }
        mutation.updatedAt = now()
    }

    private func block(_ mutation: PendingMutation, code: String) {
        mutation.state = .blocked
        mutation.lastErrorCode = code
        mutation.nextAttemptAt = nil
        mutation.updatedAt = now()
    }

    /// A blocked operation's successors for the same entity must not jump over
    /// it; ordering is what keeps the server's view of that entity coherent.
    func blockDescendants(of mutation: PendingMutation) throws {
        let owner = mutation.ownerID
        let entityID = mutation.entityID
        let completed = PendingMutationState.completed.rawValue
        let descriptor = FetchDescriptor<PendingMutation>(
            predicate: #Predicate { $0.ownerID == owner && $0.entityID == entityID && $0.stateRaw != completed },
            sortBy: [SortDescriptor(\.createdAt)])
        for successor in try context.fetch(descriptor)
        where successor.createdAt > mutation.createdAt {
            successor.state = .blocked
            successor.lastErrorCode = "blocked_by_predecessor"
            successor.updatedAt = now()
        }
    }

    /// Exponential-ish ladder with jitter. The attempt count only ever grows;
    /// there is no attempt at which an operation is discarded.
    private func backoffDelay(for mutation: PendingMutation) -> TimeInterval {
        let index = min(max(mutation.attemptCount - 1, 0), Self.backoff.count - 1)
        let base = Self.backoff[index]
        return base + Double.random(in: 0...(base * 0.25))
    }

    private func code(for error: LedgerTransportError) -> String {
        switch error {
        case .configuration:              return "configuration"
        case .notAuthenticated:           return "not_authenticated"
        case .accessDenied:               return "access_denied"
        case .validationRejected(let c):  return c
        case .retryable(let status, _):   return "retryable_\(status)"
        case .unreachable:                return "unreachable"
        case .unknownOutcome:             return "unknown_outcome"
        case .protocolMismatch:           return "protocol_mismatch"
        case .scopeChanged:               return "scope_changed"
        }
    }

    // MARK: — Helpers

    private func mutation(operationID: UUID, ownerID: String) throws -> PendingMutation? {
        let descriptor = FetchDescriptor<PendingMutation>(
            predicate: #Predicate { $0.operationID == operationID && $0.ownerID == ownerID })
        return try context.fetch(descriptor).first
    }

    private func commit() throws {
        do { try persist() }
        catch { throw LedgerWriteError.persistence(code: "sync_state_save_failed") }
    }

    /// Setter for the pull side, which lives in another file.
    func updatePullError(_ code: String?) { lastPullErrorCode = code }

    private func refreshCounts() {
        let completed = PendingMutationState.completed.rawValue
        let blocked = PendingMutationState.blocked.rawValue
        pendingCount = (try? context.fetchCount(FetchDescriptor<PendingMutation>(
            predicate: #Predicate { $0.stateRaw != completed && $0.stateRaw != blocked }))) ?? 0
        blockedCount = (try? context.fetchCount(FetchDescriptor<PendingMutation>(
            predicate: #Predicate { $0.stateRaw == blocked }))) ?? 0
    }
}
