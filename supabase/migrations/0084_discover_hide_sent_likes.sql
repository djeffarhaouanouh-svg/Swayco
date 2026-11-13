-- Discover : une personne à qui j'ai DÉJÀ envoyé une demande ne revient plus dans mon paquet.
--
-- Avant (0051) : seules les amitiés ACCEPTÉES étaient cachées ; les demandes en
-- attente restaient dans le paquet, parce qu'il y avait à peine 20 cartes et que
-- « Recommencer » aurait sinon laissé un paquet vide. Il y a maintenant des
-- milliers de profils : on cache aussi ce que j'ai déjà liké (en attente, ou
-- refusé : inutile de me le remontrer).
--
-- Inchangé : quelqu'un qui m'a liké et que je n'ai pas encore liké RESTE dans le
-- paquet (c'est ce qui permet de lui répondre et de créer le match). Une amitié
-- supprimée (« Retirer ») libère la personne : elle redevient éligible.
--
-- Tout le reste est repris tel quel de 0074_discover_daily_cap.sql.
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
    -- amitiés acceptées (dans les deux sens) + TOUT ce que j'ai moi-même envoyé
    select case
             when requester = p_user_id then addressee
             else requester
           end as peer
      from public.friendships
     where (status = 'accepted' and (requester = p_user_id or addressee = p_user_id))
        or requester = p_user_id
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
     case when (select unlimited from me) then 1000 else 200 end
   );
$$;

revoke all on function public.discover_feed(uuid, int, text[], text[]) from public;
grant execute on function public.discover_feed(uuid, int, text[], text[])
  to anon, authenticated;
