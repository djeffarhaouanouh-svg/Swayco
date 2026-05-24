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

const TIERS = ['free', 'plus', 'ultra_plus'];

/**
 * @typedef {Object} TierFeatures
 * @property {number}  monthlySeconds      — translation / live-call seconds
 *                                            refilled every 30 days. The
 *                                            user-facing label is "crédits"
 *                                            where 1 credit = 60s so the
 *                                            numbers feel abstract /
 *                                            generous instead of advertising
 *                                            a stopwatch.
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
    monthlySeconds: 75 * 60,          // 75 crédits / mois (1.25 h)
    voiceDub: 'none',
    voiceDubsPerMonth: 0,
    voiceClone: false,
  }),
  plus: Object.freeze({
    monthlySeconds: 360 * 60,         // 360 crédits / mois (6 h)
    voiceDub: 'generic',
    voiceDubsPerMonth: 60,            // cap matches the "60 vocaux/mois"
                                      // promise on the marketing card.
    voiceClone: false,
  }),
  ultra_plus: Object.freeze({
    monthlySeconds: 1300 * 60,        // 1300 crédits / mois ≈ 5 h / week
                                      // fair-use cap. Marketing copy
                                      // advertises Ultra Plus as
                                      // "Illimité"; the cap exists to
                                      // bound runaway OpenAI billing on
                                      // a compromised account, not to
                                      // ration honest power users.
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
