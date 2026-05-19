// POST /api/storekit/notifications — App Store Server Notifications V2 webhook
// This endpoint receives signed notifications from Apple when subscriptions renew,
// expire, or get refunded. No auth header — verified via JWS signature.
//
// Configure the URL in App Store Connect → Subscriptions → Server URL:
//   https://sumit-backend-ten.vercel.app/api/storekit/notifications
//
// Stub for now — implement when paywall is live. Right now it just acknowledges
// so Apple doesn't keep retrying.

export default async function handler(req, res) {
  if (req.method !== "POST") {
    return res.status(405).json({ error: "method_not_allowed" });
  }

  try {
    const { signedPayload } = req.body || {};
    if (!signedPayload) {
      return res.status(400).json({ error: "missing_payload" });
    }

    // TODO: verify JWS signature against Apple root cert + decode + update profile.
    // For now, log and ack.
    console.log("App Store notification received (stub).");

    return res.status(200).json({ ok: true });
  } catch (err) {
    console.error("/api/storekit/notifications error:", err);
    return res.status(500).json({ error: "internal_error" });
  }
}
