-- 0020_messages_delete_policy.sql
--
-- Lets a user delete their own messages — backs the "long-press a message
-- you sent → delete" feature. The `messages.sender` column holds the
-- Supabase auth user id (see lib/services/device_id.dart), so it equals
-- auth.uid().
--
-- This migration only ADDS a DELETE policy. It deliberately does NOT run
-- `enable row level security`: if RLS is currently OFF on this table,
-- turning it on here would also start gating SELECT / INSERT and could
-- break reading / sending messages. The policy is harmless while RLS is
-- off (dormant) and takes effect once RLS is on.

drop policy if exists "messages_delete_own" on public.messages;

create policy "messages_delete_own"
  on public.messages
  for delete
  using ( sender = auth.uid() );
