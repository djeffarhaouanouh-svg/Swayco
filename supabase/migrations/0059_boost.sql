-- 0059_boost.sql
--
-- Boost: a paid consumable (store product Boost_1 / boost_1 through the
-- RevenueCat package "Boost") that ranks the buyer higher in Discover for 24 h.
--
-- Credited ONLY by the backend's RevenueCat webhook, through grant_boost():
--   * profiles.boosted_until is protected by a trigger — a client (anon /
--     authenticated key) can never set it, only the service role can.
--   * boost_purchases records each store transaction once, so a webhook
--     redelivery never grants a second boost.
--
-- discover_feed() is re-created (same 3-arg signature as 0058) to put boosted
-- profiles first in the candidate window, so they always reach the client-side
-- scorer, which adds the actual ranking bonus.

alter table public.profiles
  add column if not exists boosted_until timestamptz;

create or replace function public.protect_boosted_until()
returns trigger
language plpgsql
as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    if tg_op = 'INSERT' then
      new.boosted_until := null;
    else
      new.boosted_until := old.boosted_until;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_protect_boosted_until on public.profiles;
create trigger trg_protect_boosted_until
  before insert or update on public.profiles
  for each row
  execute function public.protect_boosted_until();

create table if not exists public.boost_purchases (
  transaction_id text primary key,
  user_id        uuid not null references public.profiles (id) on delete cascade,
  product_id     text not null,
  created_at     timestamptz not null default now()
);

-- RLS on, no policy: only the service role (backend) reads or writes it.
alter table public.boost_purchases enable row level security;

create or replace function public.grant_boost(
  p_user_id        uuid,
  p_transaction_id text,
  p_product_id     text,
  p_hours          int default 24
)
returns timestamptz
language plpgsql
security definer
set search_path = public
as $$
declare
  v_until timestamptz;
begin
  insert into public.boost_purchases (transaction_id, user_id, product_id)
  values (p_transaction_id, p_user_id, p_product_id)
  on conflict (transaction_id) do nothing;

  if not found then
    select boosted_until into v_until from public.profiles where id = p_user_id;
    return v_until;
  end if;

  -- A boost bought while one is running extends it instead of overlapping.
  update public.profiles
     set boosted_until = greatest(coalesce(boosted_until, now()), now())
                         + make_interval(hours => p_hours)
   where id = p_user_id
  returning boosted_until into v_until;
  return v_until;
end;
$$;

revoke all on function public.grant_boost(uuid, text, text, int) from public;
revoke all on function public.grant_boost(uuid, text, text, int) from anon, authenticated;
grant execute on function public.grant_boost(uuid, text, text, int) to service_role;

drop function if exists public.discover_feed(uuid, int);
drop function if exists public.discover_feed(uuid, int, text);

create or replace function public.discover_feed(
  p_user_id   uuid,
  p_limit     int    default 50,
  p_languages text[] default null
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
    select case when blocker = p_user_id then blocked else blocker end as peer
      from public.blocked_users
     where blocker = p_user_id or blocked = p_user_id
  ),
  matched as (
    select case
             when requester = p_user_id then addressee
             else requester
           end as peer
      from public.friendships
     where status = 'accepted'
       and (requester = p_user_id or addressee = p_user_id)
  ),
  langs as (
    select array(
             select lower(x)
               from unnest(coalesce(p_languages, '{}'::text[])) as x
              where coalesce(x, '') <> ''
           ) as list
  )
  select p.*
    from public.profiles p
    cross join me
    cross join langs
   where p.id <> p_user_id
     and coalesce(p.discover_photo_url, '') <> ''
     and p.id not in (select peer from blocked)
     and p.id not in (select peer from matched)
     and (
       cardinality(langs.list) = 0
       or lower(coalesce(p.language, '')) = any (langs.list)
     )
     and not (
       coalesce(p.hide_from_country, false) = true
       and me.lang <> ''
       and lower(coalesce(p.language, '')) = me.lang
     )
   order by (coalesce(p.boosted_until, '-infinity') > now()) desc,
            p.updated_at desc
   limit greatest(coalesce(p_limit, 50), 0);
$$;

revoke all on function public.discover_feed(uuid, int, text[]) from public;
grant execute on function public.discover_feed(uuid, int, text[])
  to anon, authenticated;
