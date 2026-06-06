-- Missions are STICKY: once a mission is completed it stays completed even if
-- the user later undoes the action (deletes the photo, clears the bio, …).
-- This is the monotonic set of mission keys ever completed — the live
-- detection only ever ADDS to it, never removes.
--
-- The reward model also changed: instead of a few minutes per mission, the
-- user earns a single 15-minute bonus once ALL missions are done. That payout
-- is recorded with a '__complete__' sentinel in the existing
-- `missions_rewarded` array (migration 0037) so it's granted exactly once.
alter table public.profiles
  add column if not exists missions_done text[] not null default '{}';
