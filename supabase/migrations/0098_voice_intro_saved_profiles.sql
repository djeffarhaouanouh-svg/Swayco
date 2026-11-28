-- 0098_voice_intro_saved_profiles.sql
--
--   * Présentation vocale du profil : quatre colonnes sur `profiles` et un
--     bucket public `voice-intros` ({auth.uid()}/{horodatage}.m4a). La bio, elle,
--     existe déjà (profiles.bio).
--   * Profils enregistrés (marque-page) : table `saved_profiles`, privée — on ne
--     voit que ses propres enregistrements.
--
-- À appliquer dans l'éditeur SQL de Supabase. Peut être rejoué sans risque.

-- ─── Présentation vocale ────────────────────────────────────────────────────
alter table public.profiles
  add column if not exists voice_intro_url text not null default '';
alter table public.profiles
  add column if not exists voice_intro_duration_ms integer;
-- Ce qui est dit (pour la traduction affichée sous l'audio) et sa langue.
alter table public.profiles
  add column if not exists voice_intro_transcript text not null default '';
alter table public.profiles
  add column if not exists voice_intro_lang text not null default '';

alter table public.profiles
  drop constraint if exists profiles_voice_intro_duration_chk;
alter table public.profiles
  add constraint profiles_voice_intro_duration_chk
    check (
      voice_intro_duration_ms is null
      or (voice_intro_duration_ms > 0 and voice_intro_duration_ms <= 65000)
    );

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('voice-intros', 'voice-intros', true, 2097152, array['audio/*'])
on conflict (id) do update
  set public = true,
      file_size_limit = 2097152,
      allowed_mime_types = array['audio/*'];

-- Chacun écrit, relit et efface seulement dans son propre dossier.
drop policy if exists "voice intros own insert" on storage.objects;
create policy "voice intros own insert"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'voice-intros'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "voice intros own select" on storage.objects;
create policy "voice intros own select"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'voice-intros'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "voice intros own delete" on storage.objects;
create policy "voice intros own delete"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'voice-intros'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- ─── Profils enregistrés ────────────────────────────────────────────────────
create table if not exists public.saved_profiles (
  owner_id   uuid not null references public.profiles(id) on delete cascade,
  saved_id   uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (owner_id, saved_id),
  check (owner_id <> saved_id)
);

create index if not exists saved_profiles_owner_idx
  on public.saved_profiles (owner_id, created_at desc);

alter table public.saved_profiles enable row level security;

drop policy if exists "saved profiles own select" on public.saved_profiles;
create policy "saved profiles own select"
  on public.saved_profiles for select to authenticated
  using (owner_id = auth.uid());

drop policy if exists "saved profiles own insert" on public.saved_profiles;
create policy "saved profiles own insert"
  on public.saved_profiles for insert to authenticated
  with check (owner_id = auth.uid());

drop policy if exists "saved profiles own delete" on public.saved_profiles;
create policy "saved profiles own delete"
  on public.saved_profiles for delete to authenticated
  using (owner_id = auth.uid());

revoke all on public.saved_profiles from anon;
grant select, insert, delete on public.saved_profiles to authenticated;

-- L'API voit tout de suite les nouvelles colonnes et la nouvelle table.
notify pgrst, 'reload schema';
