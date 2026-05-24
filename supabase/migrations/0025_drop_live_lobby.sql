-- 0025_drop_live_lobby.sql
--
-- The Random Call lobby was removed from the app (the 🌍 "Live" tab,
-- LiveCallScreen, PushDispatcher.broadcastLiveCall and the backend's
-- POST /api/notify-live are all gone). Drop the now-orphan Supabase
-- objects so the schema matches what the app actually uses.
--
-- Affected objects:
--   * trigger / function enqueue_live_call() — wrote to live_lobby
--   * table live_lobby                       — queue of users waiting
--   * table live_notify_log                  — 24h fan-out throttle
--
-- All drops are guarded with `if exists` so re-running this migration
-- (or applying it on a deployment that already lost the lobby) is a
-- no-op. CASCADE on the function so any leftover triggers go with it.

drop function if exists public.enqueue_live_call() cascade;

drop table if exists public.live_notify_log;
drop table if exists public.live_lobby;
