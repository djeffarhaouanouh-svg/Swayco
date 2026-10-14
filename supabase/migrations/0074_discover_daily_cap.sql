-- Discover : 150 swipes par jour pour un compte gratuit, illimité pour le Pro,
-- quel que soit le pays.
--
-- Le paquet du jour = les cartes que la base renvoie. L'app demande un lot de 300
-- (le double du paquet de 150, pour pouvoir équilibrer hommes / continents) ; la
-- base plafonne ce lot elle-même, pour qu'une app modifiée ne puisse pas en
-- demander davantage :
--
--   * compte gratuit      : au plus 300 lignes (soit 150 cartes après équilibrage)
--   * Pro / Plus / Ultra  : au plus 1 000 lignes (paquet de 400 cartes, illimité en pratique)
--
-- « Pro » = is_pro vrai OU subscription_tier différent de 'free' (le balayage
-- d'expiration remet les deux à zéro à la fin de l'abonnement).
--
-- Tout le reste est repris tel quel de 0073_discover_humans_first.sql.
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
    select id,
           lower(coalesce(language, '')) as lang,
           (coalesce(is_pro, false)
              or coalesce(subscription_tier, 'free') <> 'free') as unlimited
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
   limit least(
     greatest(coalesce(p_limit, 50), 0),
     case when (select unlimited from me) then 1000 else 300 end
   );
$$;

revoke all on function public.discover_feed(uuid, int, text[], text[]) from public;
grant execute on function public.discover_feed(uuid, int, text[], text[])
  to anon, authenticated;
