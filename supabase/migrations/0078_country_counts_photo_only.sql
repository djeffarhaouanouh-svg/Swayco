-- 0078_country_counts_photo_only.sql
--
-- Les bulles pays du Discover ne doivent compter que des comptes AVEC photo :
-- un profil sans photo n'apparait jamais dans le fil, donc le compter dans la
-- bulle promet une rencontre qui n'existe pas.
--
-- Meme definition de « a une photo » que l'app (globe_places.dart) : photo de
-- Discover, galerie, ou avatar. Meme colonnes qu'en 0072 (country | total |
-- humans | ai), donc aucun changement cote app.

create or replace view public.country_counts as
select
  trim(country)                                        as country,
  count(*)::int                                        as total,
  (count(*) filter (where not coalesce(is_ai, false)))::int as humans,
  (count(*) filter (where coalesce(is_ai, false)))::int     as ai
from public.profiles
where coalesce(trim(country), '') <> ''
  and (
    coalesce(trim(discover_photo_url), '') <> ''
    or coalesce(array_length(photos, 1), 0) > 0
    or coalesce(trim(avatar_url), '') <> ''
  )
group by trim(country);
