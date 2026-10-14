-- Discover : les VRAIS comptes d'abord dans le lot.
--
-- Avant (0071) : après les profils boostés, le lot de 100 était tiré au hasard
-- parmi TOUS les profils. Avec ~3 300 comptes IA pour une poignée de vrais
-- comptes, un vrai compte n'avait qu'environ 3 % de chances d'être dans le lot
-- d'une personne donnée : l'app ne pouvait pas le favoriser puisqu'elle ne le
-- recevait pas.
--
-- Maintenant : boostés d'abord, puis les vrais comptes (is_ai = false), puis les
-- comptes IA, dans un ordre pseudo-aléatoire propre à chaque personne et à chaque
-- jour (comme avant). Quand il y a peu de vrais comptes ils sont tous dans le
-- lot ; quand il y en aura plus de 100, le lot n'est fait que de vrais comptes.
-- Le classement fin (langue, pays, intérêts…) et l'équilibrage hommes /
-- continents restent côté app, sur ce lot.
--
-- Tout le reste est repris tel quel de 0071_discover_feed_shuffle.sql.
--
-- À appliquer dans l'éditeur SQL de Supabase (rien d'autre à changer).

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
            coalesce(p.is_ai, false) asc,
            md5(p.id::text || p_user_id::text || current_date::text)
   limit greatest(coalesce(p_limit, 50), 0);
$$;

revoke all on function public.discover_feed(uuid, int, text[], text[]) from public;
grant execute on function public.discover_feed(uuid, int, text[], text[])
  to anon, authenticated;
