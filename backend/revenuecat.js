'use strict';

// RevenueCat webhook — credits consumable Boosts server-side.
//
// RevenueCat (dashboard → Integrations → Webhooks) POSTs every store event
// here with the Authorization header value configured there. On a
// NON_RENEWING_PURCHASE of a Boost product, grant_boost() (migration 0059)
// records the transaction once and pushes profiles.boosted_until 24 h out.
// The app never writes boosted_until itself: a DB trigger rejects it.
//
// Env vars:
//   REVENUECAT_WEBHOOK_AUTH — the exact Authorization header value set on the
//                             RevenueCat webhook (unset → route answers 503)
//   BOOST_PRODUCT_IDS       — optional, default "Boost_1,boost_1"
//   BOOST_HOURS             — optional, default 24
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

/** Returns a short status string for the log / response. Throws → retry. */
async function handleEvent(body) {
  const event = body?.event;
  if (!event || event.type !== 'NON_RENEWING_PURCHASE') return 'ignored';
  if (!BOOST_PRODUCT_IDS.has(event.product_id)) return 'ignored_product';

  const userId = supabaseUserId(event);
  const transactionId = event.transaction_id || event.id;
  if (!userId || !transactionId) {
    // eslint-disable-next-line no-console
    console.error('[revenuecat] boost without user/transaction', event.id);
    return 'unresolved';
  }

  const sb = supabase();
  if (!sb) throw new Error('supabase_not_configured');
  const { data, error } = await sb.rpc('grant_boost', {
    p_user_id: userId,
    p_transaction_id: String(transactionId),
    p_product_id: event.product_id,
    p_hours: BOOST_HOURS,
  });
  if (error) throw new Error(error.message);
  // eslint-disable-next-line no-console
  console.log(
    `[revenuecat] boost user=${userId} tx=${transactionId} ` +
      `env=${event.environment} until=${data}`,
  );
  return 'boosted';
}

module.exports = { isConfigured, isAuthorized, handleEvent };
