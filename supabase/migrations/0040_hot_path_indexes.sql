-- 0040_hot_path_indexes.sql
-- Indexes for the highest-traffic query paths (chat threads, unread counts,
-- received likes, pending friend requests). Everything is `if not exists`, so
-- re-running is a no-op and applying it where an index of the SAME NAME already
-- exists does nothing.
--
-- IMPORTANT — read before applying:
--   * `messages` and `likes` were created BEFORE this migration series (there
--     is no `create table` for them under supabase/migrations), so their
--     current indexes are not visible in the repo. Run the diagnostic at the
--     bottom of this file FIRST; if an equivalent index already covers the same
--     leading columns, drop the matching statement below so you don't create a
--     duplicate (duplicates cost write throughput + storage for nothing).
--   * A plain `create index` takes a write lock for the whole build. That's
--     fine while these tables are small. If a table is ALREADY large, build the
--     index by hand with `create index concurrently if not exists ...` OUTSIDE
--     a transaction instead (CONCURRENTLY can't run inside the migration's
--     transaction block), then skip that statement here.

-- ── messages ────────────────────────────────────────────────────────────────
-- Thread fetch + per-thread realtime stream:
--   where conversation_id = ? order by created_at
create index if not exists messages_conversation_created_idx
  on public.messages (conversation_id, created_at);

-- Everything addressed TO a user: unread counts, the photo-reaction feed, and
-- the "received activity since X" poll:
--   where recipient = ? [and created_at > ?] order by created_at desc
create index if not exists messages_recipient_created_idx
  on public.messages (recipient, created_at);

-- Everything a user SENT: their Discover reactions / intro messages, used to
-- paint the rail state:
--   where sender = ? [and recipient = ? and body = ? and discover_photo = ?]
create index if not exists messages_sender_created_idx
  on public.messages (sender, created_at);

-- ── likes ─────────────────────────────────────────────────────────────────
-- The composite primary key is (liker, liked, photo_url) — leading column is
-- `liker`, so "likes received by me" queries (where liked = ?) cannot use it.
-- Index the receiving side + time for the received-likes feed,
-- received_likes_counts() and the 15s activity poll:
--   where liked = ? [and created_at > ?]
create index if not exists likes_liked_created_idx
  on public.likes (liked, created_at);

-- ── friendships ─────────────────────────────────────────────────────────────
-- Pending-requests-to-me (the Demandes badge + its realtime subscription):
--   where addressee = ? and status = 'pending'
-- Narrows the existing addressee-only index so the status filter is covered.
create index if not exists friendships_addressee_status_idx
  on public.friendships (addressee, status);

-- ── Diagnostic ───────────────────────────────────────────────────────────────
-- Run this in the Supabase SQL editor BEFORE applying, to see what already
-- exists and avoid creating duplicates:
--
--   select tablename, indexname, indexdef
--     from pg_indexes
--    where schemaname = 'public'
--      and tablename in ('messages', 'likes', 'friendships')
--    order by tablename, indexname;
