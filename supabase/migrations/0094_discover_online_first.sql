-- 0094_discover_online_first.sql
--
-- Discover : les personnes EN LIGNE d'abord dans le lot (après les boostés), puis
-- les vrais comptes, puis les comptes IA. « En ligne » = la règle de l'app :
-- vu il y a moins de 3 minutes et statut non masqué. Reste repris de 0073.

create or replace function public.discover_feed(
  p_user_id   uuid,
  p_limit     int    default 50,
  p_languages text[] default null,
  p_countries text[] default null
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
  ),
  countries as (
    select array(
             select lower(x)
               from unnest(coalesce(p_countries, '{}'::text[])) as x
              where coalesce(x, '') <> ''
           ) as list
  )
  select p.*
    from public.profiles p
    cross join me
    cross join langs
    cross join countries
   where p.id <> p_user_id
     and coalesce(p.discover_photo_url, '') <> ''
     and p.id not in (select peer from blocked)
     and p.id not in (select peer from matched)
     and (
       cardinality(langs.list) = 0
       or lower(coalesce(p.language, '')) = any (langs.list)
     )
     and (
       cardinality(countries.list) = 0
       or lower(coalesce(p.country, '')) = any (countries.list)
     )
     and not (
       coalesce(p.hide_from_country, false) = true
       and me.lang <> ''
       and lower(coalesce(p.language, '')) = me.lang
     )
   order by (coalesce(p.boosted_until, '-infinity') > now()) desc,
            (coalesce(p.hide_online_status, false) = false
             and p.last_seen is not null
             and p.last_seen > now() - interval '3 minutes') desc,
            coalesce(p.is_ai, false) asc,
            md5(p.id::text || p_user_id::text || current_date::text)
   limit greatest(coalesce(p_limit, 50), 0);
$$;

revoke all on function public.discover_feed(uuid, int, text[], text[]) from public;
grant execute on function public.discover_feed(uuid, int, text[], text[])
  to anon, authenticated;
