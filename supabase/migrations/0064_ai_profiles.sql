-- 0064_ai_profiles.sql
--
-- Comptes IA : des profils pilotes par le backend (jamais par un humain dans
-- l'app), affiches avec un badge « IA » pour ne tromper personne.
--
--   * profiles.is_ai est protege par un trigger : un client (anon /
--     authenticated) ne peut ni se declarer IA, ni retirer le drapeau a un
--     compte IA. Seul le service role l'ecrit (meme principe que boosted_until,
--     0059).
--   * ai_personas : le prompt de personnage, dans une table a part. discover_feed
--     renvoie `p.*` : une colonne sur profiles partirait chez tous les clients.
--     Ici RLS est active sans aucune policy, donc seul le service role la lit.
--
-- Les comptes IA restent visibles de TOUS dans Discover (app + web).

alter table public.profiles
  add column if not exists is_ai boolean not null default false;

create or replace function public.protect_is_ai()
returns trigger
language plpgsql
as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    if tg_op = 'INSERT' then
      new.is_ai := false;
    else
      new.is_ai := old.is_ai;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_protect_is_ai on public.profiles;
create trigger trg_protect_is_ai
  before insert or update on public.profiles
  for each row
  execute function public.protect_is_ai();

create table if not exists public.ai_personas (
  user_id    uuid primary key references public.profiles (id) on delete cascade,
  persona    text not null,
  updated_at timestamptz not null default now()
);

alter table public.ai_personas enable row level security;
-- Aucune policy : table reservee au backend (service role).

create index if not exists profiles_is_ai_idx
  on public.profiles (id) where is_ai;
