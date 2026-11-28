-- 0100_profile_view_settings.sql
--
-- Les réglages des vues de profil : « Historique des vues » (coupé, je
-- n'apparais plus chez les autres et mes visites passées sont retirées),
-- « Nouvelles visites » (une notification par jour au plus) et « Effacer
-- l'historique ».
--
-- Demande la 0099 (table profile_views). À appliquer dans l'éditeur SQL de
-- Supabase. Peut être rejoué sans risque.

create table if not exists public.profile_view_settings (
  user_id    uuid primary key references public.profiles(id) on delete cascade,
  history    boolean not null default true,
  notify     boolean not null default false,
  updated_at timestamptz not null default now()
);

alter table public.profile_view_settings enable row level security;

drop policy if exists "view settings own" on public.profile_view_settings;
create policy "view settings own"
  on public.profile_view_settings for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

revoke all on public.profile_view_settings from anon;
grant select, insert, update on public.profile_view_settings to authenticated;

-- L'heure et le jour viennent du serveur ; repasser le même jour met l'heure à
-- jour sans créer de ligne.
create or replace function public.profile_views_stamp()
returns trigger
language plpgsql
as $$
begin
  new.viewed_at := now();
  if tg_op = 'INSERT' then
    new.day := (now() at time zone 'utc')::date;
  else
    new.day := old.day;
    new.viewed_id := old.viewed_id;
    new.viewer_id := old.viewer_id;
  end if;
  return new;
end;
$$;

drop trigger if exists profile_views_stamp on public.profile_views;
create trigger profile_views_stamp
  before insert or update on public.profile_views
  for each row execute function public.profile_views_stamp();

-- Lire : mes propres passages, et les visites de mon profil seulement si mon
-- historique est actif.
drop policy if exists "profile views read" on public.profile_views;
create policy "profile views read"
  on public.profile_views for select to authenticated
  using (
    viewer_id = auth.uid()
    or (
      viewed_id = auth.uid()
      and not exists (
        select 1 from public.profile_view_settings s
        where s.user_id = auth.uid() and not s.history
      )
    )
  );

-- Écrire : en mon nom, et jamais quand mon historique est coupé.
drop policy if exists "profile views own insert" on public.profile_views;
create policy "profile views own insert"
  on public.profile_views for insert to authenticated
  with check (
    viewer_id = auth.uid()
    and not exists (
      select 1 from public.profile_view_settings s
      where s.user_id = auth.uid() and not s.history
    )
  );

drop policy if exists "profile views own update" on public.profile_views;
create policy "profile views own update"
  on public.profile_views for update to authenticated
  using (viewer_id = auth.uid())
  with check (
    viewer_id = auth.uid()
    and not exists (
      select 1 from public.profile_view_settings s
      where s.user_id = auth.uid() and not s.history
    )
  );

grant update on public.profile_views to authenticated;

-- Couper l'historique retire aussi mes visites passées chez les autres.
create or replace function public.profile_view_history_off()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not new.history then
    delete from public.profile_views where viewer_id = new.user_id;
  end if;
  return new;
end;
$$;

drop trigger if exists profile_view_history_off on public.profile_view_settings;
create trigger profile_view_history_off
  after insert or update on public.profile_view_settings
  for each row execute function public.profile_view_history_off();

-- « Effacer l'historique » : les visites de MON profil.
create or replace function public.clear_profile_views()
returns void
language sql
security definer
set search_path = public
as $$
  delete from public.profile_views where viewed_id = auth.uid();
$$;

revoke all on function public.clear_profile_views() from public, anon;
grant execute on function public.clear_profile_views() to authenticated;

notify pgrst, 'reload schema';
