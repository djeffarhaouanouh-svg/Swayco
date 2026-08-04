'use strict';

// Single source of truth for what each subscription tier unlocks.
//
// Server-side gating is the only thing that matters for billing —
// clients gate too (to hide / grey out CTAs), but every endpoint that
// unlocks a paid feature must call featuresFor(tier) from THIS module
// to decide whether to proceed. Never trust a client-provided tier.
//
// Stripe pricing is wired separately in stripe.js (PRICE_BY_TIER /
// TIER_BY_PRICE) — keep the two files in sync when adding a new tier.

const TIERS = ['free', 'plus', 'ultra_plus'];

/**
 * @typedef {Object} TierFeatures
 * @property {number}  monthlySeconds      — translation / live-call seconds
 *                                            refilled every 30 days. The
 *                                            user-facing label is "crédits"
 *                                            where 1 credit = 60s so the
 *                                            numbers feel abstract /
 *                                            generous instead of advertising
 *                                            a stopwatch. Kept for Stripe /
 *                                            profile compatibility; the
 *                                            realtime session no longer
 *                                            gates on this balance.
 */

/** @type {Object<string, TierFeatures>} */
const FEATURES = Object.freeze({
  free: Object.freeze({
    // Free refills weekly, not monthly — `monthlySeconds` here is the
    // *weekly* allotment for the free tier (the field name is kept to
    // avoid churning every callsite; paid tiers still refill monthly).
    monthlySeconds: 15 * 60,          // 15 crédits / semaine
  }),
  plus: Object.freeze({
    monthlySeconds: 180 * 60,         // 180 crédits / mois (3 h)
  }),
  ultra_plus: Object.freeze({
    monthlySeconds: 360 * 60,         // 360 crédits / mois (6 h)
  }),
});

/** Resolve a tier string. Unknown / falsy → free. */
function normalizeTier(tier) {
  const t = (typeof tier === 'string' ? tier.trim().toLowerCase() : '');
  return TIERS.includes(t) ? t : 'free';
}

/** Looks up the features object for a tier (always returns one). */
function featuresFor(tier) {
  return FEATURES[normalizeTier(tier)];
}

/** Convenience: monthly translation credit allotment in seconds.
 *  1 credit (UI-side) = 60 seconds (storage-side). */
function monthlySecondsFor(tier) {
  return featuresFor(tier).monthlySeconds;
}

module.exports = {
  TIERS,
  FEATURES,
  normalizeTier,
  featuresFor,
  monthlySecondsFor,
};
