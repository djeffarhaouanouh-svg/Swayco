-- 0068_ai_actions.sql
--
-- File d'actions des comptes IA (profiles.is_ai, migration 0064).
--
-- Une ligne = une chose qu'un compte IA fait ou fera : liker quelqu'un (=
-- une ligne `friendships` en attente, ou un match si l'autre avait deja
-- like), ecrire un message, ou repondre a un message recu.
--
-- Qui ecrit ici :
--   * le panneau admin (source 'admin') : « 2 comptes du Royaume-Uni likent X » ;
--   * le planificateur autonome du backend (source 'auto') ;
--   * le repondeur du backend (source 'reply', kind 'reply').
-- Qui execute : le backend (backend/ai_agents.js), avec la cle service role.
-- Aucun client n'y touche : RLS active, aucune policy.
--
-- `ref` rend les actions idempotentes : pour une reponse c'est l'id du
-- message auquel on repond, pour une acceptation automatique l'id de la ligne
-- friendships. L'index unique fait qu'un redemarrage ou deux ticks qui se
-- chevauchent ne repondent jamais deux fois au meme message.
--
-- Les quotas (2 reponses par jour et par conversation, 2 ajouts par jour et
-- par compte) se comptent ici, sur les lignes deja ecrites.

create table if not exists public.ai_actions (
  id         uuid        primary key default gen_random_uuid(),
  ai_id      uuid        not null references public.profiles (id) on delete cascade,
  kind       text        not null check (kind in ('like', 'message', 'reply')),
  target_id  uuid        not null references public.profiles (id) on delete cascade,
  -- Texte du message (kind 'message'). Null = le compte l'ecrit lui-meme.
  body       text,
  ref        text,
  source     text        not null default 'admin'
             check (source in ('admin', 'auto', 'reply')),
  status     text        not null default 'pending'
             check (status in ('pending', 'running', 'done', 'failed', 'skipped')),
  detail     text,
  run_at     timestamptz not null default now(),
  created_by uuid,
  created_at timestamptz not null default now(),
  done_at    timestamptz,
  constraint ai_actions_not_self check (ai_id <> target_id)
);

-- « Ce qui est du » : la requete du backend a chaque tick.
create index if not exists ai_actions_due_idx
  on public.ai_actions (run_at) where status = 'pending';

-- Les quotas du jour : par compte, par type, par cible.
create index if not exists ai_actions_ai_idx
  on public.ai_actions (ai_id, kind, created_at desc);
create index if not exists ai_actions_target_idx
  on public.ai_actions (target_id, kind, created_at desc);

create unique index if not exists ai_actions_ref_uniq
  on public.ai_actions (ref) where ref is not null;

alter table public.ai_actions enable row level security;
-- Aucune policy : table reservee au backend et a l'admin (service role).
