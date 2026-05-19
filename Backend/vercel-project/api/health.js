// GET /api/health — liveness probe. No auth, no secrets returned.

export default function handler(req, res) {
  res.status(200).json({
    ok: true,
    service: "sumit-backend",
    time: new Date().toISOString(),
    env: {
      supabase: Boolean(process.env.SUPABASE_URL && process.env.SUPABASE_SERVICE_ROLE_KEY),
      openai: Boolean(process.env.OPENAI_API_KEY),
      storekit: Boolean(
        process.env.APPSTORE_ISSUER_ID &&
        process.env.APPSTORE_KEY_ID &&
        process.env.APPSTORE_PRIVATE_KEY
      ),
    },
  });
}
