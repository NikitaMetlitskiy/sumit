// POST /api/parse — text → parsed transaction JSON
// Headers: Authorization: Bearer <supabase_jwt>
// Body (v1): { text: string, model?: "gpt-4o-mini"|"gpt-4o", wallets?: string }
// Body (v2): v1 fields plus { contract_version: 2, local_date: "YYYY-MM-DD",
//            timezone: IANA id, locale: BCP-47, segment_index?: 0…19 }

import { requireUser, sendError, HttpError } from "./_lib/auth.js";
import { enforceRateLimit, incrementParseCount } from "./_lib/usage.js";
import { parseText, parseTextV2 } from "./_lib/openai.js";
import {
  TransactionContractError,
  readContractVersion,
  validateParseContext,
} from "./_lib/transaction-contract.js";
import { buildParseResponse } from "./_lib/parse-response.js";

const MAX_TEXT_LEN = 500;

export default async function handler(req, res) {
  if (req.method !== "POST") {
    return res.status(405).json({ error: "method_not_allowed" });
  }

  try {
    const { userId } = await requireUser(req);

    const body = req.body || {};
    const { text, model, wallets } = body;
    if (typeof text !== "string" || text.trim().length === 0) {
      throw new HttpError(400, "missing_text", "`text` is required");
    }
    if (text.length > MAX_TEXT_LEN) {
      throw new HttpError(400, "text_too_long", `Max ${MAX_TEXT_LEN} chars`);
    }

    // The contract and its context are checked before the rate limit and
    // before any paid call: a malformed request costs the user nothing.
    let contractVersion;
    let context = null;
    try {
      contractVersion = readContractVersion(body);
      if (contractVersion === 2) context = validateParseContext(body);
    } catch (err) {
      if (err instanceof TransactionContractError) throw new HttpError(400, err.code, err.code);
      throw err;
    }

    await enforceRateLimit(userId);

    const result = contractVersion === 2
      ? await parseTextV2({ text, model, walletNames: wallets, context })
      : await parseText({ text, model, walletNames: wallets });

    const response = buildParseResponse(result, {
      contractVersion,
      segmentIndex: context?.segmentIndex ?? null,
    });

    // Only a usable answer counts against the user's quota.
    if (response.billable) {
      await incrementParseCount(userId);
    }

    return res.status(response.status).json(response.body);
  } catch (err) {
    console.error("/api/parse error:", err?.code || err?.message);
    return sendError(res, err);
  }
}
