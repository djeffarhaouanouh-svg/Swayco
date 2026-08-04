'use strict';

// Subscription tier labels used by Stripe webhooks / profile updates.
//
// Translation credits and ElevenLabs voice features were removed — this
// module only normalises tier strings now. Keep the list in sync with
// stripe.js (PRICE_BY_TIER / TIER_BY_PRICE).

const TIERS = ['free', 'plus', 'ultra_plus'];

/** Resolve a tier string. Unknown / falsy → free. */
function normalizeTier(tier) {
  const t = (typeof tier === 'string' ? tier.trim().toLowerCase() : '');
  return TIERS.includes(t) ? t : 'free';
}

module.exports = {
  TIERS,
  normalizeTier,
};
