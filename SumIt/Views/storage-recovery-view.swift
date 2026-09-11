import SwiftUI
import UIKit

/// Shown when the persistent store could not be opened.
///
/// It deliberately receives **no** `ModelContext` and offers no way to record a
/// transaction: with the database unavailable, anything the user typed here
/// would be lost. The two actions are Retry and taking a copy of the files.
struct StorageRecoveryView: View {

    let failure: StorageFailure
    let onRetry: () -> Void
    /// Produces a copy of the store files and returns them for sharing.
    let makeCopy: () throws -> RecoveryCopy

    @State private var shareItems: [URL] = []
    @State private var isSharing = false
    @State private var copyErrorMessage: String?
    @State private var isRetrying = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.orange)

            VStack(spacing: 12) {
                Text(L("storage_error_title"))
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("storage-recovery-title")

                Text(L(failure.messageKey))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Text(L("storage_data_preserved"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 28)

            VStack(spacing: 12) {
                Button(action: retry) {
                    Text(L("storage_retry"))
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRetrying)
                .accessibilityIdentifier("storage-recovery-retry")

                Button(action: saveCopy) {
                    Text(L("storage_save_copy"))
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("storage-recovery-save-copy")
            }
            .padding(.horizontal, 28)

            if let copyErrorMessage {
                Text(copyErrorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }

            Spacer()

            Text(failure.diagnostic)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .sheet(isPresented: $isSharing) {
            ShareSheet(items: shareItems)
        }
    }

    private func retry() {
        isRetrying = true
        copyErrorMessage = nil
        onRetry()
        isRetrying = false
    }

    private func saveCopy() {
        copyErrorMessage = nil
        do {
            let copy = try makeCopy()
            shareItems = copy.files.map { copy.directory.appendingPathComponent($0.name) }
            guard !shareItems.isEmpty else {
                copyErrorMessage = L("storage_copy_failed")
                return
            }
            isSharing = true
        } catch {
            copyErrorMessage = L("storage_copy_failed")
        }
    }
}

/// Minimal share sheet bridge. The recovery screen must work without any of the
/// app's normal environment, so it does not reuse view-model-backed presentation.
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
