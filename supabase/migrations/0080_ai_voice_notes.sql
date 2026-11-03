-- 0080_ai_voice_notes.sql
--
-- Messages vocaux des comptes IA, fabriqués À LA MAIN (pas d'API de voix payante).
--
-- Le circuit :
--   1. Quelqu'un demande un vocal à une IA (ou l'admin en demande un) : le backend
--      écrit une ligne dans `ai_voice_requests` (status 'pending') avec le texte
--      que l'IA dirait à voix haute.
--   2. L'admin ouvre la page « Audios », génère la voix à la main (ElevenLabs, sur
--      leur site), envoie le fichier : status 'ready'.
--   3. Le backend voit 'ready' et l'IA envoie le message dans le chat (colonne
--      messages.audio_url) : status 'sent'.
--
-- `ai_voices` dit quelle voix utiliser pour chaque IA : une voix par IA, par groupe
-- (pays + genre) ou par défaut. Plusieurs IA peuvent partager le même identifiant
-- de voix ElevenLabs.
--
-- Tout est réservé au backend et à l'admin (service role) : RLS activée, aucune
-- policy. Le fichier audio est lisible par son adresse (bucket public, nom aléatoire).
--
-- À appliquer dans l'éditeur SQL de Supabase.

-- ─── messages : l'adresse de l'audio ───────────────────────────────────────
-- Vide pour un message normal. `body` garde le TEXTE dit à voix haute (la
-- transcription) : la traduction du chat fonctionne donc sans rien changer.
alter table public.messages
  add column if not exists audio_url text not null default '';

-- ─── file des demandes ─────────────────────────────────────────────────────
create table if not exists public.ai_voice_requests (
  id              uuid        primary key default gen_random_uuid(),
  created_at      timestamptz not null default now(),
  ai_id           uuid        not null references public.profiles (id) on delete cascade,
  target_id       uuid        not null references public.profiles (id) on delete cascade,
  conversation_id text        not null,
  -- Ce que l'IA dit (modifiable par l'admin avant de générer la voix).
  text            text        not null,
  status          text        not null default 'pending'
                  check (status in ('pending', 'ready', 'sent', 'cancelled')),
  -- 'user_ask' : la personne a demandé un vocal ; 'admin' : demande faite à la main.
  source          text        not null default 'user_ask'
                  check (source in ('user_ask', 'admin')),
  -- Chemin du fichier dans le bucket `ai-voice-notes` (rempli par l'admin).
  audio_path      text,
  ready_at        timestamptz,
  sent_at         timestamptz,
  -- Si l'envoi échoue : le backend réessaie 3 fois, puis annule et note la raison ici.
  attempts        int         not null default 0,
  detail          text,
  constraint ai_voice_requests_not_self check (ai_id <> target_id)
);

create index if not exists ai_voice_requests_status_idx
  on public.ai_voice_requests (status, created_at);
create index if not exists ai_voice_requests_conv_idx
  on public.ai_voice_requests (conversation_id, created_at desc);

-- ─── quelle voix pour quelle IA ────────────────────────────────────────────
-- scope : 'ai:<uuid de l'IA>'  une voix pour cette IA seule ;
--         'group:<pays>|<genre>'  partagée par toutes les IA de ce pays et genre
--                                  (genre : f ou m) ;
--         'default'  la voix de secours.
-- Ordre de recherche : IA, puis groupe, puis défaut.
create table if not exists public.ai_voices (
  scope      text        primary key,
  voice_id   text        not null default '',
  label      text        not null default '',
  updated_at timestamptz not null default now()
);

alter table public.ai_voice_requests enable row level security;
alter table public.ai_voices         enable row level security;

-- ─── stockage des fichiers audio ───────────────────────────────────────────
-- Bucket public en lecture (l'app lit le fichier par son adresse). L'écriture se
-- fait par l'admin avec la clé service : aucune policy d'écriture.
insert into storage.buckets (id, name, public, file_size_limit)
values ('ai-voice-notes', 'ai-voice-notes', true, 5242880)
on conflict (id) do update set public = true, file_size_limit = 5242880;
