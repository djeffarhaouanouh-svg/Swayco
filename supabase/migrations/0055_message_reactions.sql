-- 0055_message_reactions.sql
--
-- Emoji reactions on chat messages (WhatsApp-style). One emoji per person
-- per message: picking the same one again removes it, picking another
-- replaces it. Rows die with the parent message.
--
-- `conversation_id` is denormalised so the thread can stream this table the
-- same way it streams `messages` (Supabase realtime only accepts a single
-- equality filter). `message_author_id` lets the recipient's client watch
-- "reactions on MY messages" for in-app banners without joining.
--
-- Idempotent: sûr à rejouer.

create table if not exists public.message_reactions (
  id                 uuid        primary key default gen_random_uuid(),
  message_id         uuid        not null references public.messages(id) on delete cascade,
  conversation_id    text        not null,
  user_id            uuid        not null,
  user_name          text        not null default '',
  message_author_id  uuid        not null,
  emoji              text        not null,
  created_at         timestamptz not null default now(),
  constraint message_reactions_emoji_len
    check (char_length(emoji) between 1 and 16)
);

do $$
begin
  alter table public.message_reactions
    add constraint message_reactions_one_per_user
    unique (message_id, user_id);
exception when duplicate_object then null;
end$$;

create index if not exists message_reactions_conv_idx
  on public.message_reactions (conversation_id, created_at);

create index if not exists message_reactions_author_idx
  on public.message_reactions (message_author_id, created_at);

alter table public.message_reactions enable row level security;

-- Visible to both participants of the parent message.
drop policy if exists "reactions_select_participants" on public.message_reactions;
create policy "reactions_select_participants"
  on public.message_reactions
  for select
  to authenticated
  using (
    exists (
      select 1
        from public.messages m
       where m.id = message_id
         and (m.sender::text = auth.uid()::text
           or m.recipient::text = auth.uid()::text)
    )
  );

-- Write your own row, and only if you are in that conversation.
drop policy if exists "reactions_insert_own" on public.message_reactions;
create policy "reactions_insert_own"
  on public.message_reactions
  for insert
  to authenticated
  with check (
    user_id = auth.uid()
    and exists (
      select 1
        from public.messages m
       where m.id = message_id
         and (m.sender::text = auth.uid()::text
           or m.recipient::text = auth.uid()::text)
    )
  );

drop policy if exists "reactions_update_own" on public.message_reactions;
create policy "reactions_update_own"
  on public.message_reactions
  for update
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists "reactions_delete_own" on public.message_reactions;
create policy "reactions_delete_own"
  on public.message_reactions
  for delete
  to authenticated
  using (user_id = auth.uid());

do $$
begin
  alter publication supabase_realtime add table public.message_reactions;
exception
  when duplicate_object then null;
end$$;
