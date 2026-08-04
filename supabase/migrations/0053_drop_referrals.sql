-- 0053_drop_referrals.sql
--
-- Remove the invite / parrainage system entirely:
--   * profiles.referral_code / referred_by
--   * set_referral_code trigger + function
--   * attribute_referral RPC
--
-- Historical migration 0028 stays in the tree for chronology; this drops
-- what it added (credits column already went away in 0052).

drop trigger if exists profiles_set_referral_code on public.profiles;
drop function if exists public.set_referral_code();
drop function if exists public.attribute_referral(text);

drop index if exists public.profiles_referred_by_idx;

alter table public.profiles
  drop constraint if exists profiles_referral_code_unique;

alter table public.profiles drop column if exists referral_code;
alter table public.profiles drop column if exists referred_by;
