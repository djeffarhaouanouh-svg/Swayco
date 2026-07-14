-- Onboarding missions are gone: the ring, the card and the 15-min reward were
-- removed from the profile screen, so the two bookkeeping columns added by
-- migrations 0037 (missions_rewarded) and 0038 (missions_done) have no reader
-- left. Credits already granted stay in `credits_seconds` — only the "which
-- missions were done / paid" state is dropped.
alter table public.profiles
  drop column if exists missions_done,
  drop column if exists missions_rewarded;
