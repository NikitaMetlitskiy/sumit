import Foundation

/// Turns a machine error code into a sentence a person can act on.
///
/// Every write path already reports a stable code. This is the only place that
/// decides what the user reads, so an unrecognised code can never reach the
/// screen as a raw token — and adding a new code without wording it here shows
/// up as a generic message, not as `same_currency_effect_mismatch`.
enum LedgerErrorCopy {

    /// Codes with their own wording. Anything outside this set falls back to a
    /// generic sentence that still says the entry was not saved.
    static let knownCodes: Set<String> = [
        "invalid_amount", "non_finite_amount", "amount_out_of_range", "excess_precision",
        "arithmetic_failure", "unsupported_currency", "unknown_wallet", "archived_wallet",
        "transfer_to_same_wallet", "incomplete_transfer", "non_positive_amount",
        "destination_on_non_transfer", "wallet_amount_mismatch", "same_currency_effect_mismatch",
        "unequal_same_currency_legs", "transfer_currency_mismatch", "wrong_scope",
        "storage_unavailable", "save_failed", "missing_entity", "duplicate_entity",
        "invalid_wallet_name", "invalid_category_name", "wallet_currency_is_locked",
        "valuation_decision_required", "invalid_rate", "base_amount_rounds_to_zero",
    ]

    static func text(for code: String?) -> String? {
        guard let code, !code.isEmpty else { return nil }
        guard knownCodes.contains(code) else { return L("err_generic") }
        return L("err_\(code)")
    }
}
