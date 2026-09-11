// POST /api/parse-image — base64-encoded receipt → parsed transaction JSON
// Headers: Authorization: Bearer <supabase_jwt>
// Body (v1): { image: "data:image/jpeg;base64,...", model?: "gpt-4o-mini"|"gpt-4o" }
// Body (v2): v1 fields plus { contract_version: 2, local_date, timezone, locale }

import { requireUser, sendError, HttpError } from "./_lib/auth.js";
import { enforceRateLimit, incrementParseCount } from "./_lib/usage.js";
import { parseImage, parseImageV2 } from "./_lib/openai.js";
import {
  TransactionContractError,
  readContractVersion,
  validateParseContext,
} from "./_lib/transaction-contract.js";
import { buildParseResponse } from "./_lib/parse-response.js";

// Tighten per-call payload size so we can't be flooded.
// The iOS client already downscales and caps at ~2MB (≈2.7MB base64).
const MAX_IMAGE_BASE64_LEN = 3_500_000;

export const config = {
  api: {
    bodyParser: { sizeLimit: "4mb" },
  },
};

export default async function handler(req, res) {
  if (req.method !== "POST") {
    return res.status(405).json({ error: "method_not_allowed" });
  }

  try {
    const { userId } = await requireUser(req);

    const body = req.body || {};
    const { image, model } = body;
    if (typeof image !== "string" || !image.startsWith("data:image/")) {
      throw new HttpError(400, "missing_image", "`image` must be a data URL");
    }
    if (image.length > MAX_IMAGE_BASE64_LEN) {
      throw new HttpError(413, "image_too_large", "Receipt photo exceeds size limit");
    }

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
      ? await parseImageV2({ dataUrl: image, model, context })
      : await parseImage({ dataUrl: image, model });

    const response = buildParseResponse(result, { contractVersion });

    if (response.billable) {
      await incrementParseCount(userId);
    }
    return res.status(response.status).json(response.body);
  } catch (err) {
    console.error("/api/parse-image error:", err?.code || err?.message);
    return sendError(res, err);
  }
}
