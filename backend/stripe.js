'use strict';

// Stripe subscription wiring for Swayco. Three jobs:
//   1. createCheckoutSession(userId, tier) — builds a Stripe Checkout
//      URL the client redirects to (web-only paywall, ignored on native
//      where the app links to the website instead).
//   2. createPortalSession(userId) — Customer Portal URL so the user
//      can cancel, change payment method, upgrade / downgrade.
//   3. verifyWebhook + handleEvent — entry point Stripe calls when a
//      subscription state changes (signature-verified, idempotent).
//
// Env vars (all required for this module to actually do anything):
//   STRIPE_SECRET_KEY        — sk_live_… (NEVER ship to client)
//   STRIPE_WEBHOOK_SECRET    — whsec_… (signature verification)
//   STRIPE_PRICE_PRO         — price_… for the Pro €29/mo plan
//   STRIPE_PRICE_ULTRA       — price_… for the Ultra €59/mo plan
//   STRIPE_SUCCESS_URL       — optional, defaults to https://swayco.fr/?subscribed=1
//   STRIPE_CANCEL_URL        — optional, defaults to https://swayco.fr/
//   STRIPE_PORTAL_RETURN_URL — optional, defaults to https://swayco.fr/
// Plus the SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY pair from notify.js
// is reused here for JWT verification + DB writes.

const SUPABASE_URL = process.env.SUPABASE_URL?.trim();
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY?.trim();
const STRIPE_SECRET_KEY = process.env.STRIPE_SECRET_KEY?.trim();
const STRIPE_WEBHOOK_SECRET = process.env.STRIPE_WEBHOOK_SECRET?.trim();
const STRIPE_PRICE_PRO = process.env.STRIPE_PRICE_PRO?.trim();
const STRIPE_PRICE_PLUS = process.env.STRIPE_PRICE_PLUS?.trim();
const STRIPE_PRICE_ULTRA = process.env.STRIPE_PRICE_ULTRA?.trim();
const SUCCESS_URL =
  process.env.STRIPE_SUCCESS_URL?.trim() || 'https://swayco.fr/?subscribed=1';
const CANCEL_URL =
  process.env.STRIPE_CANCEL_URL?.trim() || 'https://swayco.fr/';
const PORTAL_RETURN_URL =
  process.env.STRIPE_PORTAL_RETURN_URL?.trim() || 'https://swayco.fr/';

const PRICE_BY_TIER = {
  plus: STRIPE_PRICE_PLUS,
  pro: STRIPE_PRICE_PRO,
  ultra: STRIPE_PRICE_ULTRA,
};
const TIER_BY_PRICE = {
  [STRIPE_PRICE_PLUS]: 'plus',
  [STRIPE_PRICE_PRO]: 'pro',
  [STRIPE_PRICE_ULTRA]: 'ultra',
};

let _stripe = null;
function stripe() {
  if (_stripe) return _stripe;
  if (!STRIPE_SECRET_KEY) return null;
  const Stripe = require('stripe');
  _stripe = new Stripe(STRIPE_SECRET_KEY);
  return _stripe;
}

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

// Per-tier weekly credit allotment (seconds) the webhook refills after
// every successful payment. The numbers live in `./tiers.js` so backend
// gating endpoints (e.g. /voice/dub) and the credit refill share one
// source of truth — never duplicate them here.
const { weeklySecondsFor } = require('./tiers');

function creditsForTier(tier) {
  return weeklySecondsFor(tier);
}

// 7-day rolling refill window, same cadence as the auto-refill in
// ProfileApi.dart. Pinned here so the webhook and the in-app refill
// land on the same date.
function nextRefillDate() {
  const d = new Date();
  d.setDate(d.getDate() + 7);
  return d.toISOString();
}

/**
 * Resolve a Supabase user id from a Bearer JWT in the request. Returns
 * `null` for missing / invalid / expired tokens — caller must
 * respond with 401 in that case.
 */
async function authUserId(req) {
  const auth = req.headers.authorization;
  const m =
    typeof auth === 'string' ? /^Bearer\s+(.+)$/i.exec(auth.trim()) : null;
  const token = m ? m[1] : '';
  if (!token) return null;
  const sb = supabase();
  if (!sb) return null;
  try {
    const { data, error } = await sb.auth.getUser(token);
    if (error || !data?.user) return null;
    return data.user.id;
  } catch (_) {
    return null;
  }
}

/**
 * Find or create the Stripe customer linked to a Supabase user.
 * Cached on `profiles.stripe_customer_id` so we don't re-create one
 * per checkout.
 */
async function getOrCreateCustomer(userId) {
  const sb = supabase();
  const s = stripe();
  if (!sb || !s) return null;
  const { data: row, error } = await sb
    .from('profiles')
    .select('stripe_customer_id, display_name')
    .eq('id', userId)
    .maybeSingle();
  if (error || !row) return null;
  if (row.stripe_customer_id) return row.stripe_customer_id;
  let email;
  try {
    const { data } = await sb.auth.admin.getUserById(userId);
    email = data?.user?.email;
  } catch (_) {}
  const customer = await s.customers.create({
    email,
    name: row.display_name || undefined,
    metadata: { user_id: userId },
  });
  await sb
    .from('profiles')
    .update({ stripe_customer_id: customer.id })
    .eq('id', userId);
  return customer.id;
}

async function createCheckoutSession(userId, tier) {
  const s = stripe();
  if (!s) throw new Error('stripe_not_configured');
  const price = PRICE_BY_TIER[tier];
  if (!price) throw new Error('invalid_tier');
  const customerId = await getOrCreateCustomer(userId);
  if (!customerId) throw new Error('customer_failed');
  const session = await s.checkout.sessions.create({
    mode: 'subscription',
    customer: customerId,
    line_items: [{ price, quantity: 1 }],
    success_url: SUCCESS_URL,
    cancel_url: CANCEL_URL,
    allow_promotion_codes: true,
    metadata: { user_id: userId, tier },
    subscription_data: {
      metadata: { user_id: userId, tier },
    },
  });
  return session.url;
}

async function createPortalSession(userId) {
  const s = stripe();
  if (!s) throw new Error('stripe_not_configured');
  const customerId = await getOrCreateCustomer(userId);
  if (!customerId) throw new Error('customer_failed');
  const portal = await s.billingPortal.sessions.create({
    customer: customerId,
    return_url: PORTAL_RETURN_URL,
  });
  return portal.url;
}

/**
 * Verify a webhook payload (`rawBody` is the un-parsed Buffer Express
 * gives us when the route uses express.raw). Throws if the signature
 * fails or the secret isn't configured.
 */
function verifyWebhook(rawBody, signature) {
  const s = stripe();
  if (!s || !STRIPE_WEBHOOK_SECRET) {
    throw new Error('stripe_not_configured');
  }
  return s.webhooks.constructEvent(rawBody, signature, STRIPE_WEBHOOK_SECRET);
}

/**
 * Apply the Stripe event to our `profiles` table. Idempotent: every
 * branch is a plain UPDATE that converges to the same end state if
 * Stripe re-delivers the event.
 */
async function handleEvent(event) {
  const sb = supabase();
  if (!sb) return;
  switch (event.type) {
    case 'checkout.session.completed': {
      const session = event.data.object;
      const userId = session.metadata?.user_id;
      const tier = session.metadata?.tier;
      if (!userId || !tier) return;
      const subscriptionId = session.subscription;
      await sb
        .from('profiles')
        .update({
          is_pro: true,
          subscription_tier: tier,
          stripe_subscription_id: subscriptionId,
          pro_expires_at: nextRefillDate(),
          credits_seconds: creditsForTier(tier),
          credits_reset_at: nextRefillDate(),
        })
        .eq('id', userId);
      // eslint-disable-next-line no-console
      console.log(`[stripe] checkout.completed user=${userId} tier=${tier}`);
      break;
    }

    case 'customer.subscription.updated': {
      const sub = event.data.object;
      let userId = sub.metadata?.user_id;
      if (!userId) {
        const { data } = await sb
          .from('profiles')
          .select('id')
          .eq('stripe_subscription_id', sub.id)
          .maybeSingle();
        userId = data?.id;
      }
      if (!userId) return;
      const priceId = sub.items?.data?.[0]?.price?.id;
      const tier = TIER_BY_PRICE[priceId] || sub.metadata?.tier || 'pro';
      const isActive = ['active', 'trialing'].includes(sub.status);
      await sb
        .from('profiles')
        .update({
          is_pro: isActive,
          subscription_tier: isActive ? tier : 'free',
          credits_seconds: isActive ? creditsForTier(tier) : 0,
          pro_expires_at: sub.current_period_end
            ? new Date(sub.current_period_end * 1000).toISOString()
            : null,
        })
        .eq('id', userId);
      // eslint-disable-next-line no-console
      console.log(
        `[stripe] subscription.updated user=${userId} tier=${tier} active=${isActive}`,
      );
      break;
    }

    case 'customer.subscription.deleted': {
      const sub = event.data.object;
      let userId = sub.metadata?.user_id;
      if (!userId) {
        const { data } = await sb
          .from('profiles')
          .select('id')
          .eq('stripe_subscription_id', sub.id)
          .maybeSingle();
        userId = data?.id;
      }
      if (!userId) return;
      await sb
        .from('profiles')
        .update({
          is_pro: false,
          subscription_tier: 'free',
          stripe_subscription_id: null,
        })
        .eq('id', userId);
      // eslint-disable-next-line no-console
      console.log(`[stripe] subscription.deleted user=${userId}`);
      break;
    }

    case 'invoice.payment_succeeded': {
      // Renewal — refill weekly credit allotment.
      const invoice = event.data.object;
      const subscriptionId = invoice.subscription;
      if (!subscriptionId) return;
      const { data: row } = await sb
        .from('profiles')
        .select('id, subscription_tier')
        .eq('stripe_subscription_id', subscriptionId)
        .maybeSingle();
      if (!row?.id) return;
      const tier = row.subscription_tier || 'pro';
      await sb
        .from('profiles')
        .update({
          credits_seconds: creditsForTier(tier),
          credits_reset_at: nextRefillDate(),
        })
        .eq('id', row.id);
      // eslint-disable-next-line no-console
      console.log(`[stripe] invoice.payment_succeeded refill user=${row.id}`);
      break;
    }

    case 'invoice.payment_failed': {
      // Soft signal. Stripe will retry per dunning settings; we'll
      // get a customer.subscription.deleted if it ultimately gives up.
      // eslint-disable-next-line no-console
      console.log(
        `[stripe] invoice.payment_failed sub=${event.data.object.subscription}`,
      );
      break;
    }

    default:
      // Many event types we don't care about — keep the log quiet but
      // visible for debugging.
      // eslint-disable-next-line no-console
      console.log(`[stripe] unhandled event ${event.type}`);
  }
}

module.exports = {
  authUserId,
  createCheckoutSession,
  createPortalSession,
  verifyWebhook,
  handleEvent,
};
