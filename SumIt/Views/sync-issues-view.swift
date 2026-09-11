import SwiftUI
import SwiftData

/// Everything waiting for the owner's decision.
///
/// Two devices editing the same record is not an error the app can settle on
/// its own: whichever version it picked silently would be the one it destroyed.
/// So both candidates are shown side by side, with exact amounts, and the owner
/// chooses a whole version. No money field is ever merged here, and nothing on
/// this screen resolves itself after a timeout.
struct SyncIssuesView: View {

    @ObservedObject var store: AppStore
    @ObservedObject var auth: AuthService = .shared
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \SyncIssue.createdAt, order: .reverse) private var storedIssues: [SyncIssue]
    @Query private var storedWallets: [Wallet]

    @State private var actionError: String?

    private var open: [SyncIssue] {
        storedIssues.filter { $0.ownerID == auth.userId && $0.resolvedAt == nil }
    }

    private var resolved: [SyncIssue] {
        storedIssues.filter { $0.ownerID == auth.userId && $0.resolvedAt != nil }
    }

    private var walletNames: [UUID: String] {
        Dictionary(storedWallets.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        NavigationView {
            List {
                if open.isEmpty && resolved.isEmpty {
                    Section {
                        Text(L("sync_issues_empty"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("sync-issues-empty")
                    }
                }

                if !open.isEmpty {
                    Section(L("sync_issues_open")) {
                        ForEach(open, id: \.id) { issue in
                            NavigationLink {
                                issueDetail(issue)
                            } label: {
                                issueRow(issue)
                            }
                        }
                    }
                }

                if !resolved.isEmpty {
                    Section {
                        ForEach(resolved, id: \.id) { issue in
                            VStack(alignment: .leading, spacing: 6) {
                                issueRow(issue)
                                Button(L("conflict_dismiss")) { dismissIssue(issue) }
                                    .font(.footnote)
                                    .accessibilityIdentifier("sync-issue-dismiss")
                            }
                        }
                    } header: {
                        Text(L("sync_issues_resolved"))
                    } footer: {
                        Text(L("conflict_resolved_note"))
                    }
                }

                if let actionError {
                    Section {
                        Text(actionError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("sync-issues-error")
                    }
                }
            }
            .navigationTitle(L("sync_issues_title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("close")) { dismiss() }
                }
            }
        }
    }

    // MARK: — Rows

    @ViewBuilder
    private func issueRow(_ issue: SyncIssue) -> some View {
        HStack(spacing: 12) {
            Image(systemName: issue.kind == .conflict ? "arrow.triangle.branch" : "exclamationmark.triangle")
                .foregroundStyle(issue.resolvedAt == nil ? .orange : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(SyncIssuePresentation.title(for: issue))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Text(SyncIssuePresentation.explanation(for: issue))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("sync-issue-row")
    }

    @ViewBuilder
    private func issueDetail(_ issue: SyncIssue) -> some View {
        if issue.kind == .conflict,
           let local = SyncIssuePresentation.localCandidate(issue),
           let remote = SyncIssuePresentation.remoteCandidate(issue) {
            ConflictResolutionView(issue: issue, local: local, remote: remote,
                                   walletNames: walletNames,
                                   resolve: { resolveIssue(issue, with: $0) })
        } else {
            InformationalIssueView(issue: issue)
        }
    }

    // MARK: — Actions

    private func resolveIssue(_ issue: SyncIssue, with resolution: ConflictResolution) {
        guard let coordinator = store.syncCoordinator else { return }
        do {
            actionError = nil
            try coordinator.resolve(issueID: issue.id, with: resolution, scope: auth.currentScope)
        } catch {
            actionError = L("conflict_action_failed")
        }
    }

    private func dismissIssue(_ issue: SyncIssue) {
        guard let coordinator = store.syncCoordinator else { return }
        do {
            actionError = nil
            try coordinator.dismiss(issueID: issue.id, scope: auth.currentScope)
        } catch {
            actionError = L("conflict_action_failed")
        }
    }
}

// MARK: — Conflict detail

/// Side-by-side comparison of two whole versions. Amounts are the exact stored
/// strings: a display formatter that rounded them would be showing the user a
/// number neither version actually contains.
struct ConflictResolutionView: View {

    let issue: SyncIssue
    let local: ConflictCandidate
    let remote: ConflictCandidate
    let walletNames: [UUID: String]
    let resolve: (ConflictResolution) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                Text(L("conflict_explain"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            candidateSection(L("conflict_your_version"), local, identifier: "conflict-local")
            candidateSection(L("conflict_server_version"), remote, identifier: "conflict-remote")

            Section {
                Button(L("conflict_use_server")) { choose(.useServer) }
                    .accessibilityIdentifier("conflict-use-server")
                Button(L("conflict_keep_local")) { choose(.keepLocal) }
                    .accessibilityIdentifier("conflict-keep-local")
                // Only offered where it means something: the server deleted the
                // record and the owner still wants their version of it.
                if remote.isDeleted && issue.entityKind == .transaction {
                    Button(L("conflict_save_as_new")) { choose(.saveAsNew) }
                        .accessibilityIdentifier("conflict-save-as-new")
                }
            } footer: {
                Text(L("conflict_no_merge_note"))
            }
        }
        .navigationTitle(L("conflict_title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func choose(_ resolution: ConflictResolution) {
        resolve(resolution)
        dismiss()
    }

    @ViewBuilder
    private func candidateSection(_ title: String, _ candidate: ConflictCandidate,
                                  identifier: String) -> some View {
        Section(title) {
            if candidate.isDeleted {
                Text(L("conflict_server_deleted"))
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
            if let name = candidate.name {
                field(L("conflict_field_name"), name)
            }
            if let amount = candidate.amount {
                field(L("conflict_field_amount"),
                      "\(amount) \(candidate.currency ?? "")".trimmingCharacters(in: .whitespaces))
                    .accessibilityIdentifier("\(identifier)-amount")
            }
            if let merchant = candidate.merchant, !merchant.isEmpty {
                field(L("conflict_field_merchant"), merchant)
            }
            if let walletID = candidate.walletID {
                field(L("conflict_field_wallet"),
                      walletNames[walletID] ?? L("conflict_unknown_wallet"))
            } else if candidate.amount != nil {
                field(L("conflict_field_wallet"), L("conflict_no_wallet"))
            }
            if let occurredAt = candidate.occurredAt {
                field(L("conflict_field_date"),
                      occurredAt.formatted(date: .abbreviated, time: .shortened))
            }
            if let revision = candidate.revision {
                field(L("conflict_field_revision"), "\(revision)")
            } else {
                field(L("conflict_field_revision"), L("conflict_unsent"))
            }
        }
    }

    @ViewBuilder
    private func field(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

// MARK: — Issues that are not a two-version conflict

/// A missing reference or an unimportable legacy dataset has no "pick a side"
/// answer, so this screen explains the situation instead of offering a button
/// that would not do what it says.
struct InformationalIssueView: View {
    let issue: SyncIssue

    var body: some View {
        Form {
            Section {
                Text(SyncIssuePresentation.title(for: issue))
                    .font(.headline)
                Text(SyncIssuePresentation.explanation(for: issue))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Text(L("conflict_field_recorded")).foregroundStyle(.secondary)
                    Spacer()
                    Text(issue.createdAt.formatted(date: .abbreviated, time: .shortened))
                }
                .font(.subheadline)
                Text(issue.reason)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(L("sync_issues_title"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: — What each side of a conflict looks like

/// One whole version of an entity, flattened for display only.
struct ConflictCandidate: Equatable {
    var amount: String?
    var currency: String?
    var walletID: UUID?
    var merchant: String?
    var name: String?
    var occurredAt: Date?
    var revision: Int64?
    var isDeleted: Bool = false
}

/// Decoding and wording, kept out of the view so both can be exercised directly.
enum SyncIssuePresentation {

    static func title(for issue: SyncIssue) -> String {
        switch issue.kind {
        case .conflict:        return L("conflict_title")
        case .legacyAmbiguity: return L("sync_issue_legacy_title")
        case .invalidRemoteRow: return L("sync_issue_invalid_title")
        }
    }

    /// Keyed on the machine reason so the copy stays specific. An unrecognised
    /// reason falls back to the generic sentence rather than showing the raw
    /// token as if it were a sentence.
    static func explanation(for issue: SyncIssue) -> String {
        switch issue.reason {
        case "remote_edit_meets_local_candidate": return L("conflict_explain")
        case "missing_wallet_reference":          return L("sync_issue_missing_wallet")
        case "local_data_awaiting_import":        return L("sync_issue_awaiting_import")
        default:
            return issue.kind == .conflict ? L("conflict_explain") : L("sync_issue_generic")
        }
    }

    /// The local candidate is stored as the bare record payload.
    static func localCandidate(_ issue: SyncIssue) -> ConflictCandidate? {
        guard let data = issue.localSnapshotJSON else { return nil }
        let decoder = JSONDecoder()
        switch issue.entityKind {
        case .transaction:
            guard let record = try? decoder.decode(TransactionRecordV1.self, from: data) else { return nil }
            return ConflictCandidate(amount: record.originalAmount,
                                     currency: record.originalCurrency,
                                     walletID: record.walletID,
                                     merchant: record.merchant,
                                     occurredAt: record.occurredAt,
                                     revision: nil)
        case .wallet:
            guard let record = try? decoder.decode(WalletRecordV1.self, from: data) else { return nil }
            return ConflictCandidate(amount: record.openingBalance,
                                     currency: record.currency,
                                     name: record.name,
                                     revision: nil)
        case .category:
            guard let record = try? decoder.decode(CategoryRecordV1.self, from: data) else { return nil }
            return ConflictCandidate(name: record.name, revision: nil)
        }
    }

    /// The remote candidate is a full snapshot: it carries the revision and the
    /// tombstone as well as the record.
    static func remoteCandidate(_ issue: SyncIssue) -> ConflictCandidate? {
        guard let data = issue.remoteSnapshotJSON,
              let snapshot = try? JSONDecoder().decode(LedgerSnapshot.self, from: data) else { return nil }
        let header = snapshot.header
        switch snapshot {
        case .transaction(let value):
            return ConflictCandidate(amount: value.record.originalAmount,
                                     currency: value.record.originalCurrency,
                                     walletID: value.record.walletID,
                                     merchant: value.record.merchant,
                                     occurredAt: value.record.occurredAt,
                                     revision: header.ledgerRevision.value,
                                     isDeleted: header.isDeleted)
        case .wallet(let value):
            return ConflictCandidate(amount: value.record.openingBalance,
                                     currency: value.record.currency,
                                     name: value.record.name,
                                     revision: header.ledgerRevision.value,
                                     isDeleted: header.isDeleted)
        case .category(let value):
            return ConflictCandidate(name: value.record.name,
                                     revision: header.ledgerRevision.value,
                                     isDeleted: header.isDeleted)
        }
    }
}
