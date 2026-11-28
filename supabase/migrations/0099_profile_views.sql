-- 0099_profile_views.sql
--
-- Les vues de profil : qui a ouvert mon profil. Une ligne par personne et par
-- jour. Chacun ne lit que les vues de SON profil (et ses propres passages), et
-- n'écrit qu'en son nom.
--
-- À appliquer dans l'éditeur SQL de Supabase. Peut être rejoué sans risque.

create table if not exists public.profile_views (
  viewed_id uuid not null references public.profiles(id) on delete cascade,
  viewer_id uuid not null references public.profiles(id) on delete cascade,
  day       date not null default ((now() at time zone 'utc')::date),
  viewed_at timestamptz not null default now(),
  primary key (viewed_id, viewer_id, day),
  check (viewer_id <> viewed_id)
);

create index if not exists profile_views_recent_idx
  on public.profile_views (viewed_id, viewed_at desc);

alter table public.profile_views enable row level security;

drop policy if exists "profile views read" on public.profile_views;
create policy "profile views read"
  on public.profile_views for select to authenticated
  using (viewed_id = auth.uid() or viewer_id = auth.uid());

drop policy if exists "profile views own insert" on public.profile_views;
create policy "profile views own insert"
  on public.profile_views for insert to authenticated
  with check (viewer_id = auth.uid());

revoke all on public.profile_views from anon;
grant select, insert on public.profile_views to authenticated;

notify pgrst, 'reload schema';
