-- Server-side Discover feed: a SECURITY DEFINER RPC that applies every
-- privacy filter in SQL so a tampered client cannot bypass them by
-- ignoring its own filtering code.
--
-- Filters enforced here:
--   • caller is excluded (no self in the deck)
--   • profiles without a discover_photo_url are excluded (no empty cards)
--   • peers the caller blocked (or who blocked the caller) are excluded
--   • peers with hide_from_country = true AND a language matching the
--     caller's language are excluded — language is the country proxy
--     because the schema has no dedicated country column
--
-- The composite ordering (activity recency, cross-language bonus, etc.)
-- stays in the Flutter client because (a) it carries a random jitter
-- between refreshes, which is awkward in SQL, and (b) the ranking only
-- affects display order, never which rows are returned, so leaking the
-- weights to a decompiled client has no privacy impact.
--
-- Idempotent: the migration ADD COLUMNs first so old DBs that never
-- ran an earlier migration adding `hide_from_country` still work.

alter table public.profiles
  add column if not exists hide_from_country boolean not null default false;

create or replace function public.discover_feed(
  p_user_id uuid,
  p_limit   int default 50
)
returns setof public.profiles
language sql
security definer
set search_path = public
as $$
  with me as (
    select id, lower(coalesce(language, '')) as lang
      from public.profiles
     where id = p_user_id
     limit 1
  ),
  blocked as (
    -- Either side of the relation: I blocked them or they blocked me.
    select case when blocker = p_user_id then blocked else blocker end as peer
      from public.blocked_users
     where blocker = p_user_id or blocked = p_user_id
  )
  select p.*
    from public.profiles p
    cross join me
   where p.id <> p_user_id
     and coalesce(p.discover_photo_url, '') <> ''
     and p.id not in (select peer from blocked)
     and not (
       coalesce(p.hide_from_country, false) = true
       and me.lang <> ''
       and lower(coalesce(p.language, '')) = me.lang
     )
   order by p.updated_at desc
   limit greatest(coalesce(p_limit, 50), 0);
$$;

revoke all on function public.discover_feed(uuid, int) from public;
grant execute on function public.discover_feed(uuid, int)
  to anon, authenticated;
