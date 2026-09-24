-- 0060_protect_subscription_columns.sql
--
-- Closes a gap found while wiring the RevenueCat entitlement webhook:
-- "anon_update_profiles" (0002_profiles_friendships.sql) allows ANY caller
-- (the anon/authenticated key shipped in the app) to update ANY row of
-- `profiles`, with no column restriction. Nothing stopped a client from
-- running `update profiles set is_pro = true, subscription_tier = 'plus'
-- where id = <self>` directly — bypassing both the Stripe and RevenueCat
-- webhooks and granting itself Pro for free.
--
-- Same shape as protect_boosted_until() (0059_boost.sql): a BEFORE
-- INSERT/UPDATE trigger resets these columns to their default unless the
-- writer is the service role (Stripe's and RevenueCat's webhooks both use
-- SUPABASE_SERVICE_ROLE_KEY, never shipped to the client).
--
-- Verified safe against every current write path:
--   * ProfileApi.upsertMyProfile / ensureMyProfileRow never include is_pro,
--     subscription_tier or pro_expires_at in their payload — grepped across
--     lib/, zero matches — so resetting them on a client-driven INSERT is a
--     no-op, not a behaviour change.
--   * The two webhooks are the only code that ever sets these columns
--     (backend/stripe.js, backend/revenuecat.js), both service-role.

create or replace function public.protect_subscription_columns()
returns trigger
language plpgsql
as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    if tg_op = 'INSERT' then
      new.is_pro := false;
      new.subscription_tier := 'free';
      new.pro_expires_at := null;
    else
      new.is_pro := old.is_pro;
      new.subscription_tier := old.subscription_tier;
      new.pro_expires_at := old.pro_expires_at;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_protect_subscription_columns on public.profiles;
create trigger trg_protect_subscription_columns
  before insert or update on public.profiles
  for each row
  execute function public.protect_subscription_columns();
