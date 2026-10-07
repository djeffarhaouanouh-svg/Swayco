-- Journal des notifications d'engagement (backend/engagement.js) : une ligne par
-- (personne, genre, reference) pour ne jamais envoyer deux fois la meme chose,
-- et pour compter combien on en a envoye a quelqu'un dans les dernieres 24 h.
create table if not exists public.notif_log (
  id bigserial primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null,
  ref text not null,
  sent_at timestamptz not null default now(),
  unique (user_id, kind, ref)
);

create index if not exists notif_log_user_sent_idx
  on public.notif_log (user_id, sent_at desc);

alter table public.notif_log enable row level security;
-- Aucune policy : seul le serveur (cle de service) y ecrit et y lit.
