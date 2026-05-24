'use strict';

// Single source of truth for what each subscription tier unlocks.
//
// Server-side gating is the only thing that matters for billing —
// clients gate too (to hide / grey out CTAs), but every endpoint that
// debits credit or unlocks a paid feature must call featuresFor(tier)
// from THIS module to decide whether to proceed. Never trust a
// client-provided tier.
//
// Stripe pricing is wired separately in stripe.js (PRICE_BY_TIER /
// TIER_BY_PRICE) — keep the two files in sync when adding a new tier.

const TIERS = ['free', 'plus', 'pro', 'ultra'];

/**
 * @typedef {Object} TierFeatures
 * @property {number}  weeklySeconds       — translation / live-call seconds
 *                                            refilled every 7 days.
 * @property {'none'|'generic'|'cloned'} voiceDub
 *                                          — what the backend should
 *                                            produce when the bubble
 *                                            calls /voice/dub.
 * @property {number}  voiceDubsPerMonth   — rolling-30-day cap on TTS
 *                                            dubs the user may trigger.
 *                                            `Infinity` = no cap.
 * @property {boolean} voiceClone          — may enroll their voice
 *                                            (ElevenLabs IVC) and have
 *                                            outgoing dubs use it.
 */

/** @type {Object<string, TierFeatures>} */
const FEATURES = Object.freeze({
  free: Object.freeze({
    weeklySeconds: 15 * 60,           // 15 min
    voiceDub: 'none',
    voiceDubsPerMonth: 0,
    voiceClone: false,
  }),
  plus: Object.freeze({
    weeklySeconds: 60 * 60,           // 1 h
    voiceDub: 'generic',
    voiceDubsPerMonth: 60,            // cap matches the "60 vocaux/mois"
                                      // promise on the marketing card.
    voiceClone: false,
  }),
  pro: Object.freeze({
    weeklySeconds: 3 * 60 * 60,       // 3 h
    voiceDub: 'generic',
    voiceDubsPerMonth: Infinity,
    voiceClone: false,
  }),
  ultra: Object.freeze({
    weeklySeconds: 7 * 60 * 60,       // 7 h — bounded so an "appels
                                      // illimités" power user can't
                                      // run the realtime bill past the
                                      // subscription's gross margin.
    voiceDub: 'cloned',
    voiceDubsPerMonth: Infinity,
    voiceClone: true,
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

/** Convenience: weekly translation credit allotment in seconds. */
function weeklySecondsFor(tier) {
  return featuresFor(tier).weeklySeconds;
}

module.exports = {
  TIERS,
  FEATURES,
  normalizeTier,
  featuresFor,
  weeklySecondsFor,
};
