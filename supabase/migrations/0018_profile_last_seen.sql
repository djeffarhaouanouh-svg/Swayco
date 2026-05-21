-- 0018_profile_last_seen.sql
--
-- Presence: a `last_seen` timestamp on profiles so other clients can
-- show an "online" indicator. The app refreshes it every ~90s while it
-- is foregrounded (see lib/services/presence_service.dart). Whether the
-- indicator is actually shown is gated client-side by the existing
-- `hide_online_status` flag.
--
-- No new RLS policy is needed: updating one's own profile row is already
-- permitted (same path as hide_online_status).

alter table public.profiles
  add column if not exists last_seen timestamptz;
