// POST /api/parse-image — base64-encoded receipt → parsed transaction JSON
// Headers: Authorization: Bearer <supabase_jwt>
// Body: { image: "data:image/jpeg;base64,...", model?: "gpt-4o-mini"|"gpt-4o" }

import { requireUser, sendError, HttpError } from "./_lib/auth.js";
import { enforceRateLimit, incrementParseCount } from "./_lib/usage.js";
import { parseImage } from "./_lib/openai.js";

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
    await enforceRateLimit(userId);

    const { image, model } = req.body || {};
    if (typeof image !== "string" || !image.startsWith("data:image/")) {
      throw new HttpError(400, "missing_image", "`image` must be a data URL");
    }
    if (image.length > MAX_IMAGE_BASE64_LEN) {
      throw new HttpError(413, "image_too_large", "Receipt photo exceeds size limit");
    }

    const result = await parseImage({ dataUrl: image, model });

    if (!result?.error) {
      await incrementParseCount(userId);
    }
    return res.status(200).json(result);
  } catch (err) {
    console.error("/api/parse-image error:", err?.code || err?.message);
    return sendError(res, err);
  }
}
