// Shared tail of the text and photo routes: turns the model's answer into the
// response for the contract the client asked for.
//
// Both routes go through this one function, so a receipt photo cannot take a
// looser path to the client than typed text does.

import {
  CONTRACT_VERSION,
  TransactionContractError,
  validateParsedTransactionV2,
} from "./transaction-contract.js";

/// Returns `{ status, body, billable }`.
///
/// - A version-1 client gets the model's answer unchanged — the shape it
///   already reads.
/// - A version-2 client gets a validated body, or a 422 naming exactly what
///   was wrong. A malformed answer is never repaired into something plausible.
/// - "Not a transaction" is a normal answer, not a failure, and is not billed.
export function buildParseResponse(result, { contractVersion, segmentIndex = null }) {
  if (contractVersion !== CONTRACT_VERSION) {
    return { status: 200, body: result, billable: !result?.error };
  }

  const echo = segmentIndex === null ? {} : { segment_index: segmentIndex };

  if (result?.error === "not_a_transaction") {
    return {
      status: 200,
      body: { contract_version: CONTRACT_VERSION, error: "not_a_transaction", ...echo },
      billable: false,
    };
  }
  if (result?.error) {
    // `empty_response` / `invalid_json`: the model did not produce JSON.
    return {
      status: 422,
      body: { contract_version: CONTRACT_VERSION, error: "invalid_model_output", ...echo },
      billable: false,
    };
  }

  try {
    const body = validateParsedTransactionV2(result);
    return { status: 200, body: { ...body, ...echo }, billable: true };
  } catch (err) {
    if (!(err instanceof TransactionContractError)) throw err;
    return {
      status: 422,
      body: { contract_version: CONTRACT_VERSION, error: "invalid_model_output", reason: err.code, ...echo },
      billable: false,
    };
  }
}
