-- Discover: optional spoken-language filter, used by the globe country picker.
-- Selecting one or more countries on the globe filters the deck to profiles
-- whose `language` is one of those countries' languages (France -> fr,
-- Germany -> de).
--
-- Adds p_languages (NULL / empty array keeps the previous unfiltered
-- behaviour). The old 2-arg signature is dropped so PostgREST doesn't see an
-- ambiguous overload when the app calls with named params.

drop function if exists public.discover_feed(uuid, int);

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
   order by p.updated_at desc
   limit greatest(coalesce(p_limit, 50), 0);
$$;

revoke all on function public.discover_feed(uuid, int, text[]) from public;
grant execute on function public.discover_feed(uuid, int, text[])
  to anon, authenticated;
