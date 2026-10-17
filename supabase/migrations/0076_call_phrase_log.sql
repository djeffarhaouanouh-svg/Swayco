-- Journal des phrases d'appel, pour les comptes de TEST uniquement.
--
-- Pourquoi : les événements d'analyse ne gardent ni ce qui a été dit ni ce qui a
-- été traduit, donc impossible de juger la précision d'une traduction d'appel
-- quand les deux interlocuteurs ne parlent pas la même langue. Ici, pour les
-- comptes listés dans `call_debug_users`, le backend (route /translation/fix)
-- note, phrase par phrase : ce que le micro a compris, la phrase réparée, et la
-- traduction envoyée.
--
-- Garde-fous :
--   * seuls les comptes de `call_debug_users` sont journalisés ; tout autre
--     compte n'écrit rien (le backend vérifie la liste, mise en cache 60 s) ;
--   * les lignes de plus de 7 jours sont supprimées par le backend ;
--   * les deux tables sont réservées au backend et à l'admin (service role) :
--     RLS activée, aucune policy, rien de lisible depuis l'app.
--
-- Ajouter / retirer un compte : insérer / supprimer sa ligne dans
-- call_debug_users (user_id = profiles.id).
--
-- À appliquer dans l'éditeur SQL de Supabase.

create table if not exists public.call_debug_users (
  user_id    uuid        primary key references public.profiles (id) on delete cascade,
  note       text,
  created_at timestamptz not null default now()
);

create table if not exists public.call_phrase_log (
  id         bigint      generated always as identity primary key,
  created_at timestamptz not null default now(),
  user_id    uuid        not null,
  from_lang  text,
  to_lang    text,
  -- Ce que la reconnaissance vocale a compris (brut).
  heard      text,
  -- La phrase réparée dans la langue source (vide si la route n'en produit pas).
  repaired   text,
  -- La traduction envoyée à l'autre personne (vide = illisible, rien n'est parti).
  translated text,
  route      text,
  engine     text,
  unclear    boolean     not null default false
);

create index if not exists call_phrase_log_user_time_idx
  on public.call_phrase_log (user_id, created_at desc);

alter table public.call_debug_users enable row level security;
alter table public.call_phrase_log  enable row level security;

-- Les comptes de test à journaliser au départ (à ajuster).
insert into public.call_debug_users (user_id, note)
select id, handle
  from public.profiles
 where handle in ('lely-b0253e', 'tochi-0f14a7', 'lou-2f80fb')
on conflict (user_id) do nothing;
