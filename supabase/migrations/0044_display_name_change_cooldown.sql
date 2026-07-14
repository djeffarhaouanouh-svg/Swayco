-- 0044_display_name_change_cooldown.sql
--
-- Rate-limits display-name ("prénom") changes to once every 14 days, the way
-- social networks do. The client enforces the same window for UX (it shows the
-- remaining days instead of letting the user tap Save), but the real guard
-- lives here so a tampered client can't spam-rename to impersonate people.
--
-- `display_name_changed_at` records the last time the name actually changed.
-- A BEFORE UPDATE trigger stamps it and rejects a change inside the window.
--
-- Notes on why this doesn't break existing flows:
--   * The guard only fires when display_name genuinely changes AND the row
--     already had a non-empty name — so the initial onboarding name-set and
--     legacy rows with an empty name are never blocked.
--   * The cold-launch `upsert` re-writes the SAME display_name, so
--     `is distinct from` is false and the guard is skipped.
--   * The FK self-heal upsert is insert-only (ON CONFLICT DO NOTHING) and
--     never reaches the UPDATE path.
--   * On the first change, `display_name_changed_at` is NULL, so every current
--     user is grandfathered one free change; the 14-day window starts after it.

alter table public.profiles
  add column if not exists display_name_changed_at timestamptz;

create or replace function public.enforce_display_name_cooldown()
returns trigger
language plpgsql
as $$
begin
  if new.display_name is distinct from old.display_name
     and coalesce(old.display_name, '') <> '' then
    if old.display_name_changed_at is not null
       and now() - old.display_name_changed_at < interval '14 days' then
      raise exception
        'display_name change is rate limited: 14 day cooldown not elapsed'
        using errcode = 'check_violation';
    end if;
    new.display_name_changed_at := now();
  end if;
  return new;
end;
$$;

drop trigger if exists trg_display_name_cooldown on public.profiles;
create trigger trg_display_name_cooldown
  before update on public.profiles
  for each row
  execute function public.enforce_display_name_cooldown();
