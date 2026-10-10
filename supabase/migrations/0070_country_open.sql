-- Pays qui viennent d'ouvrir. Une ligne ici declenche la notification a la liste
-- d'attente du pays (backend/engagement.js, toutes les 10 min) :
--
--   insert into public.country_open (country_key, iso) values ('Peru', 'pe');
--
-- country_key = le `name` du GeoJSON du globe (comme country_waitlist.country_key),
-- iso = code ISO2 en minuscules (pour le nom du pays dans la langue de chacun).
-- A faire APRES la sortie de l'app qui ajoute le pays a kGlobeCountries.
create table if not exists public.country_open (
  country_key text primary key,
  iso         text not null,
  opened_at   timestamptz not null default now()
);

alter table public.country_open enable row level security;
-- Aucune policy : seul le serveur (cle de service) lit et ecrit.
