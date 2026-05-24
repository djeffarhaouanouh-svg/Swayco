-- 0024_rename_pro_to_ultra_plus.sql
--
-- The "Ultra" plan (€69.99) is being dropped, and the previous "Pro"
-- plan (€24.99 with 1000 crédits) is rebranded to "Ultra Plus" — which
-- inherits Ultra's signature features (cloned-voice dubbing, top
-- Discover placement, premium ElevenLabs voices) and the previous
-- Ultra fair-use cap (2000 crédits / mois).
--
-- Schema changes:
--   1. Migrate existing rows: any 'pro' or 'ultra' subscriber moves to
--      'ultra_plus'. Anyone who paid for Ultra gets the equivalent
--      tier under the new name (no functional downgrade); anyone on
--      Pro gets an upgrade in name + features at the same price.
--   2. Replace the CHECK constraint so only the three live tier
--      values ('free' | 'plus' | 'ultra_plus') are accepted going
--      forward.

-- 1) Migrate existing data. Run UPDATEs before the constraint is
--    rewritten so we never leave the table in a state that violates
--    its own check.
update public.profiles
   set subscription_tier = 'ultra_plus'
 where subscription_tier in ('pro', 'ultra');

-- 2) Tighten the CHECK to the new tier list.
alter table public.profiles
  drop constraint if exists profiles_subscription_tier_chk;
alter table public.profiles
  add constraint profiles_subscription_tier_chk
    check (subscription_tier in ('free', 'plus', 'ultra_plus'));

-- Reminder for the operator running this migration:
--   * Stripe side — keep both the old Pro price ID and the new
--     Ultra Plus price ID active for now so historical subscriptions
--     remain billable. The webhook handler maps both price IDs to
--     the 'ultra_plus' tier via TIER_BY_PRICE in backend/stripe.js
--     (STRIPE_PRICE_ULTRA_PLUS falls back to STRIPE_PRICE_PRO when
--     unset, so existing Railway deployments keep working).
--   * The dropped "Ultra" Stripe product / price (€69.99) should be
--     archived in the Stripe dashboard so it stops being purchasable
--     — existing Ultra subscriptions keep billing until cancelled.
