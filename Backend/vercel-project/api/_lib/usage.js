// Server-side parse counter and tier gating.
// Source of truth lives in profiles.subscription_tier / monthly_parse_count.
// Client cannot bypass this — it has no way to write those columns (column-level revoke).

import { supabaseAdmin } from "./supabase.js";
import { HttpError } from "./auth.js";

const LIMITS = {
  none: 0,
  basic: parseInt(process.env.PARSE_LIMIT_BASIC || "100", 10),
  pro: Infinity,
};

// Set to true when paywall is live in iOS. While false, we still log usage but skip limits.
const PAYWALL_ENABLED = process.env.PAYWALL_ENABLED === "true";

/// Reads tier + count, throws if over limit or no subscription.
/// Returns { tier, used } so the caller can include them in response.
export async function enforceRateLimit(userId) {
  if (!userId) {
    // Anonymous mode (dev) — no limits.
    return { tier: "anon", used: 0 };
  }
  const sb = supabaseAdmin();
  const { data: profile, error } = await sb
    .from("profiles")
    .select("subscription_tier, monthly_parse_count, parse_count_reset_at")
    .eq("id", userId)
    .single();

  if (error) {
    throw new HttpError(500, "profile_fetch_failed", error.message);
  }
  const tier = profile?.subscription_tier || "none";

  if (!PAYWALL_ENABLED) {
    return { tier, used: profile?.monthly_parse_count || 0 };
  }
  if (tier === "none") {
    throw new HttpError(403, "subscription_required", "Active subscription required");
  }
  const used = currentMonthCount(profile);
  const limit = LIMITS[tier] ?? 0;
  if (used >= limit) {
    throw new HttpError(429, "monthly_limit_reached", `Monthly limit of ${limit} reached`);
  }
  return { tier, used };
}

export async function incrementParseCount(userId) {
  if (!userId) return;
  const sb = supabaseAdmin();
  const { error } = await sb.rpc("increment_parse_count", { uid: userId });
  if (error) {
    console.warn("increment_parse_count failed:", error.message);
  }
}

function currentMonthCount(profile) {
  if (!profile) return 0;
  const resetAt = profile.parse_count_reset_at ? new Date(profile.parse_count_reset_at) : null;
  if (!resetAt) return 0;
  const now = new Date();
  const sameMonth =
    resetAt.getUTCFullYear() === now.getUTCFullYear() &&
    resetAt.getUTCMonth() === now.getUTCMonth();
  if (!sameMonth) return 0;
  return profile.monthly_parse_count || 0;
}
