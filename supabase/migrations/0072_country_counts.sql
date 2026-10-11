-- 0072_country_counts.sql
--
-- Combien de personnes par pays, lisible directement par le globe 3D.
--
--   select * from public.country_counts;
--   -> country | total | humans | ai
--
-- `country` est exactement la valeur de profiles.country (« France »,
-- « Allemagne »…) : c'est le `dbName` de kGlobeCountries cote app.
--   total  = tous les comptes du pays
--   humans = les vrais utilisateurs (is_ai = false)
--   ai     = les comptes IA (is_ai = true)
-- L'app choisit la colonne qu'elle affiche.
--
-- C'est une vue, donc toujours a jour : pas de table a rafraichir. Elle
-- s'execute avec les droits de son proprietaire (c'est le defaut Postgres),
-- ce qui permet a anon / authenticated de lire ces COMPTAGES sans jamais lire
-- les lignes de profiles. Elle ne renvoie que des totaux par pays.
--
-- Sans index, le groupement lit toute la table ; a quelques milliers de
-- profils c'est instantane, l'index garde ca vrai quand la base grossira.

create index if not exists profiles_country_idx
  on public.profiles (country);

create or replace view public.country_counts as
select
  trim(country)                                        as country,
  count(*)::int                                        as total,
  (count(*) filter (where not coalesce(is_ai, false)))::int as humans,
  (count(*) filter (where coalesce(is_ai, false)))::int     as ai
from public.profiles
where coalesce(trim(country), '') <> ''
group by trim(country);

revoke all on public.country_counts from public;
grant select on public.country_counts to anon, authenticated;
