-- Liste d'attente des pays pas encore ouverts (globe : cadenas "Me prevenir").
-- Une ligne par (personne, pays). La cle = le nom du pays dans le GeoJSON du
-- globe ('India', 'South Korea'...), comme kLockedCountries dans l'app.
create table if not exists public.country_waitlist (
  user_id    uuid not null references auth.users(id) on delete cascade,
  country_key text not null,
  created_at timestamptz not null default now(),
  primary key (user_id, country_key)
);

alter table public.country_waitlist enable row level security;

-- Chacun lit / ajoute / retire SES lignes.
create policy country_waitlist_select_own on public.country_waitlist
  for select using (auth.uid() = user_id);
create policy country_waitlist_insert_own on public.country_waitlist
  for insert with check (auth.uid() = user_id);
create policy country_waitlist_delete_own on public.country_waitlist
  for delete using (auth.uid() = user_id);

-- Combien de personnes attendent chaque pays (visible par tous, sans qui).
create or replace function public.country_waitlist_counts()
returns table (country_key text, n int)
language sql
security definer
set search_path = public
stable
as $$
  select w.country_key, count(*)::int
  from public.country_waitlist w
  group by w.country_key;
$$;

revoke all on function public.country_waitlist_counts() from public;
grant execute on function public.country_waitlist_counts() to authenticated;

-- Pour le tableau de bord (cle de service uniquement) : la demande par pays,
-- a mettre en face des profils actifs de ce pays pour decider ou investir.
create or replace view public.country_demand as
  select country_key, count(*)::int as demand, max(created_at) as last_request
  from public.country_waitlist
  group by country_key;
revoke all on public.country_demand from anon, authenticated;