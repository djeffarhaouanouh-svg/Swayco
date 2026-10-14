-- Chat messages backing the in-app Chat tab.
-- No auth yet: we identify devices via a locally generated UUID stored in
-- SharedPreferences (DeviceId), and display the user's first name as
-- `sender_name`. RLS is enabled with permissive policies to keep the
-- publishable key working — tighten when proper auth is added.

create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id text not null,
  sender_id uuid not null,
  sender_name text not null,
  body text not null,
  created_at timestamptz not null default now()
);

create index if not exists messages_conv_created_idx
  on public.messages (conversation_id, created_at);

alter table public.messages enable row level security;

-- Permissive policies: anyone with the publishable key may read/insert.
-- TODO: scope by auth.uid() once Supabase Auth is wired in.
drop policy if exists "anon_read_messages" on public.messages;
create policy "anon_read_messages"
  on public.messages for select
  using (true);

drop policy if exists "anon_insert_messages" on public.messages;
create policy "anon_insert_messages"
  on public.messages for insert
  with check (true);

-- Surface row changes over the realtime channel so clients can subscribe()
-- and see new messages without polling.
alter publication supabase_realtime add table public.messages;
