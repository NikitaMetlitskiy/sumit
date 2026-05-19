// POST /api/parse — text → parsed transaction JSON
// Headers: Authorization: Bearer <supabase_jwt>
// Body: { text: string, model?: "gpt-4o-mini"|"gpt-4o", wallets?: string }

import { requireUser, sendError, HttpError } from "./_lib/auth.js";
import { enforceRateLimit, incrementParseCount } from "./_lib/usage.js";
import { parseText } from "./_lib/openai.js";

const MAX_TEXT_LEN = 500;

export default async function handler(req, res) {
  if (req.method !== "POST") {
    return res.status(405).json({ error: "method_not_allowed" });
  }

  try {
    const { userId } = await requireUser(req);
    await enforceRateLimit(userId);

    const { text, model, wallets } = req.body || {};
    if (typeof text !== "string" || text.trim().length === 0) {
      throw new HttpError(400, "missing_text", "`text` is required");
    }
    if (text.length > MAX_TEXT_LEN) {
      throw new HttpError(400, "text_too_long", `Max ${MAX_TEXT_LEN} chars`);
    }

    const result = await parseText({ text, model, walletNames: wallets });

    // Only count successful parses against the user's quota.
    if (!result?.error) {
      await incrementParseCount(userId);
    }

    return res.status(200).json(result);
  } catch (err) {
    console.error("/api/parse error:", err?.code || err?.message);
    return sendError(res, err);
  }
}
