-- 0088_official_inbox.sql
--
-- Les gens peuvent écrire à l'équipe Swayco (compte officiel). Leurs messages
-- arrivent dans cette table ; l'équipe les lit depuis le back-office
-- (admin/scripts/post_official.mjs --inbox). Chacun ne voit que SES messages.

create table if not exists public.official_messages (
  id          uuid        primary key default gen_random_uuid(),
  user_id     uuid        not null,
  user_name   text        not null default '',
  body        text        not null check (char_length(body) between 1 and 4000),
  created_at  timestamptz not null default now()
);

create index if not exists official_messages_user_idx
  on public.official_messages (user_id, created_at);

alter table public.official_messages enable row level security;

drop policy if exists "official_messages_insert_own" on public.official_messages;
create policy "official_messages_insert_own"
  on public.official_messages for insert
  with check (user_id = auth.uid());

drop policy if exists "official_messages_select_own" on public.official_messages;
create policy "official_messages_select_own"
  on public.official_messages for select
  using (user_id = auth.uid());
