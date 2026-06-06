-- Onboarding "missions" rewards.
--
-- Six one-off missions (send a friend request, post a photo, like someone,
-- send a first message, fill the bio, add 3 interests) each grant the user a
-- few minutes of call time. The minutes are added to `credits_seconds`; this
-- array records which mission keys have ALREADY been credited so the reward is
-- paid exactly once, no matter how many times the client re-checks.
--
-- Detection itself is derived live from existing data (friendships, likes,
-- messages, profile photos/bio/interests) — nothing to store for that. Only
-- the "already paid" bookkeeping lives here.
alter table public.profiles
  add column if not exists missions_rewarded text[] not null default '{}';
