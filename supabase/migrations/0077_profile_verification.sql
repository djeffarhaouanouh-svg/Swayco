-- 0077_profile_verification.sql
--
-- Verification du profil : un selfie avec un GESTE IMPOSE, compare aux photos du
-- profil par l'equipe dans le panneau admin. Le resultat est profiles.is_verified,
-- qui commande la pastille « Verifie » (Discover, Messages, chat).
--
--   * profiles.is_verified est protege par un trigger : un client (anon /
--     authenticated) ne peut ni se declarer verifie, ni retirer le drapeau. Seul le
--     service role l'ecrit (meme principe que is_ai, 0064, et boosted_until, 0059).
--     profiles autorise l'update a tout le monde (0002) : sans ce trigger, n'importe
--     qui pourrait se donner la pastille.
--   * profile_verifications : une demande par selfie. L'utilisateur peut creer la
--     sienne (toujours 'pending') et la lire ; il ne peut ni la modifier ni la
--     supprimer. La decision (status, reviewed_at, reject_reason) vient de l'admin,
--     via le service role.
--   * Bucket PRIVE verification-selfies : l'utilisateur ne peut qu'y deposer, dans
--     son propre dossier {auth.uid()}/. Aucune lecture, aucune ecriture par dessus :
--     le panneau admin lit par URL signee (service role) et supprime le fichier
--     apres la decision. Le selfie ne devient JAMAIS une photo du profil.

alter table public.profiles
  add column if not exists is_verified boolean not null default false;

create or replace function public.protect_is_verified()
returns trigger
language plpgsql
as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    if tg_op = 'INSERT' then
      new.is_verified := false;
    else
      new.is_verified := old.is_verified;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_protect_is_verified on public.profiles;
create trigger trg_protect_is_verified
  before insert or update on public.profiles
  for each row
  execute function public.protect_is_verified();

create table if not exists public.profile_verifications (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references auth.users (id) on delete cascade,
  -- La cle du geste demande (gesture_thumb_left...) : le validateur doit la voir.
  gesture        text not null check (char_length(gesture) between 1 and 40),
  -- {user_id}/{timestamp}.jpg dans le bucket verification-selfies. Le dossier doit
  -- etre celui de l'utilisateur : on ne peut pas pointer vers le selfie d'un autre.
  selfie_path    text not null check (selfie_path like (user_id::text || '/%')),
  status         text not null default 'pending'
                 check (status in ('pending', 'approved', 'rejected')),
  reject_reason  text,
  created_at     timestamptz not null default now(),
  reviewed_at    timestamptz,
  -- Rempli quand le fichier a ete supprime du bucket (apres la decision).
  selfie_deleted_at timestamptz
);

-- Une seule demande en attente par utilisateur.
create unique index if not exists profile_verifications_one_pending
  on public.profile_verifications (user_id)
  where status = 'pending';

create index if not exists profile_verifications_status_created_idx
  on public.profile_verifications (status, created_at);

alter table public.profile_verifications enable row level security;

drop policy if exists "own insert" on public.profile_verifications;
create policy "own insert"
  on public.profile_verifications for insert
  with check (
    auth.uid() = user_id
    -- Une demande neuve est toujours en attente : un client ne s'insere pas une
    -- ligne deja « approved ».
    and status = 'pending'
    and reviewed_at is null
    and reject_reason is null
    and selfie_deleted_at is null
  );

drop policy if exists "own read" on public.profile_verifications;
create policy "own read"
  on public.profile_verifications for select
  using (auth.uid() = user_id);
-- Pas de policy update / delete : seule l'admin (service role) decide.

-- Bucket prive : ni lecture publique, ni lecture par l'utilisateur.
insert into storage.buckets (id, name, public)
values ('verification-selfies', 'verification-selfies', false)
on conflict (id) do update set public = false;

drop policy if exists "verification selfies own insert" on storage.objects;
create policy "verification selfies own insert"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'verification-selfies'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
-- Volontairement AUCUNE policy select / update / delete sur ce bucket.
