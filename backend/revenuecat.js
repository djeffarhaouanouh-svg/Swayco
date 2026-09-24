'use strict';

// RevenueCat webhook. Two independent jobs, same endpoint:
//   1. Boost — a consumable, credited additively (see handleBoost).
//   2. Pro entitlement sync — keeps profiles.is_pro / subscription_tier /
//      pro_expires_at in step with the "pro" entitlement, for
//      INITIAL_PURCHASE / RENEWAL / EXPIRATION (see handlePro).
//
// RevenueCat (dashboard → Integrations → Webhooks) POSTs every store event
// here with the Authorization header value configured there.
//
// Env vars:
//   REVENUECAT_WEBHOOK_AUTH — the exact Authorization header value set on the
//                             RevenueCat webhook (unset → route answers 503)
//   BOOST_PRODUCT_IDS       — optional, default "Boost_1,boost_1"
//   BOOST_HOURS             — optional, default 24
//   PRO_ENTITLEMENT_ID      — optional, default "pro"
// Plus SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY (shared with stripe.js).

const crypto = require('crypto');

const SUPABASE_URL = process.env.SUPABASE_URL?.trim();
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY?.trim();
const WEBHOOK_AUTH = process.env.REVENUECAT_WEBHOOK_AUTH?.trim();
const BOOST_PRODUCT_IDS = new Set(
  (process.env.BOOST_PRODUCT_IDS || 'Boost_1,boost_1')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean),
);
const BOOST_HOURS = Number(process.env.BOOST_HOURS) || 24;
const PRO_ENTITLEMENT_ID = process.env.PRO_ENTITLEMENT_ID?.trim() || 'pro';
const PRO_EVENT_TYPES = new Set(['INITIAL_PURCHASE', 'RENEWAL', 'EXPIRATION']);

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

let _supabase = null;
function supabase() {
  if (_supabase) return _supabase;
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) return null;
  const { createClient } = require('@supabase/supabase-js');
  _supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return _supabase;
}

function isConfigured() {
  return Boolean(WEBHOOK_AUTH);
}

function isAuthorized(req) {
  const got = Buffer.from(String(req.headers.authorization || ''));
  const want = Buffer.from(WEBHOOK_AUTH || '');
  return (
    want.length > 0 &&
    got.length === want.length &&
    crypto.timingSafeEqual(got, want)
  );
}

// The Supabase uid the purchase belongs to. The app calls Purchases.logIn(uid)
// at sign-in, so app_user_id is normally the uid; an anonymous id
// ($RCAnonymousID:…) falls back to the aliases.
function supabaseUserId(event) {
  const ids = [
    event.app_user_id,
    event.original_app_user_id,
    ...(Array.isArray(event.aliases) ? event.aliases : []),
  ];
  return ids.find((id) => typeof id === 'string' && UUID_RE.test(id)) || null;
}

// RevenueCat sends `entitlement_ids` (array) on current webhook versions;
// `entitlement_id` (singular) is the older, deprecated field. Returns null
// when the event carries neither — distinct from an empty/non-matching list.
function entitlementIds(event) {
  if (Array.isArray(event.entitlement_ids)) return event.entitlement_ids;
  if (typeof event.entitlement_id === 'string') return [event.entitlement_id];
  return null;
}

function environmentTag(event) {
  return event.environment === 'SANDBOX' ? 'SANDBOX' : 'PRODUCTION';
}

/**
 * Consumable Boost purchase → grant_boost() (migration 0059_boost.sql).
 * `db` defaults to the real client; tests inject a fake one.
 */
async function handleBoost(event, db, env) {
  if (!BOOST_PRODUCT_IDS.has(event.product_id)) return 'ignored_product';

  const userId = supabaseUserId(event);
  const transactionId = event.transaction_id || event.id;
  if (!userId || !transactionId) {
    // eslint-disable-next-line no-console
    console.error(`[revenuecat][${env}] boost without user/transaction`, event.id);
    return 'unresolved';
  }

  if (!db) throw new Error('supabase_not_configured');
  const { data, error } = await db.rpc('grant_boost', {
    p_user_id: userId,
    p_transaction_id: String(transactionId),
    p_product_id: event.product_id,
    p_hours: BOOST_HOURS,
  });
  if (error) throw new Error(error.message);
  // eslint-disable-next-line no-console
  console.log(
    `[revenuecat][${env}] boost user=${userId} tx=${transactionId} until=${data}`,
  );
  return 'boosted';
}

/**
 * Pro entitlement sync → a plain, declarative UPDATE on `profiles`, exactly
 * like backend/stripe.js's handleEvent(): every branch converges to the same
 * end state no matter how many times the event is redelivered, so no
 * dedup ledger is needed (unlike the additive Boost credit above).
 *
 * SANDBOX events (TestFlight / debug purchases) are processed exactly like
 * PRODUCTION ones — RevenueCat's own `expiration_at_ms` on the event is
 * always used verbatim, never a hardcoded interval, so a short sandbox
 * renewal cycle can never be mistaken for a real month and inflate a
 * production expiry. The environment is tagged on every log line so
 * SANDBOX activity stays visually distinct from real purchases.
 */
async function handlePro(event, db, env) {
  const entitlements = entitlementIds(event);
  if (entitlements === null) {
    // eslint-disable-next-line no-console
    console.error(
      `[revenuecat][${env}] ${event.type} without entitlement info`,
      event.id,
    );
    return 'ignored_no_entitlement';
  }
  if (!entitlements.includes(PRO_ENTITLEMENT_ID)) return 'ignored_entitlement';

  const userId = supabaseUserId(event);
  if (!userId) {
    // eslint-disable-next-line no-console
    console.error(
      `[revenuecat][${env}] ${event.type} without a resolvable user`,
      event.id,
    );
    return 'unresolved';
  }

  const patch =
    event.type === 'EXPIRATION'
      ? { is_pro: false, subscription_tier: 'free' }
      : {
          is_pro: true,
          subscription_tier: 'plus',
          pro_expires_at: event.expiration_at_ms
            ? new Date(event.expiration_at_ms).toISOString()
            : null,
        };

  if (!db) throw new Error('supabase_not_configured');
  const { error } = await db.from('profiles').update(patch).eq('id', userId);
  if (error) throw new Error(error.message);
  // eslint-disable-next-line no-console
  console.log(
    `[revenuecat][${env}] pro ${event.type} user=${userId} ` +
      `tier=${patch.subscription_tier} expires=${patch.pro_expires_at ?? 'n/a'}`,
  );
  return 'pro_synced';
}

/**
 * Returns a short status string for the log / response. Throws → RevenueCat
 * retries. `db` is injectable for tests; production callers omit it and get
 * the lazily-created real Supabase client.
 */
async function handleEvent(body, db = supabase()) {
  const event = body?.event;
  if (!event) return 'ignored';
  const env = environmentTag(event);

  if (event.type === 'NON_RENEWING_PURCHASE') return handleBoost(event, db, env);
  if (PRO_EVENT_TYPES.has(event.type)) return handlePro(event, db, env);
  return 'ignored';
}

module.exports = {
  isConfigured,
  isAuthorized,
  handleEvent,
  // Exported for tests only.
  supabaseUserId,
  entitlementIds,
};
