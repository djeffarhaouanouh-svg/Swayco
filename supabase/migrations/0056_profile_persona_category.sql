-- Profile "persona category" — a single-choice "what defines you most"
-- identity picked once at onboarding (see `lib/services/persona_categories.dart`
-- for the 18-option taxonomy), distinct from the multi-select `interests`
-- tags. Drives the one chip shown on the Discover card and a same-category
-- bonus in the client-side Discover scoring.
--
-- Not-null with a default of '' so existing rows need no backfill and the
-- upsert path in ProfileApi.upsertMyProfile (which never touches this
-- column) is unaffected.
alter table public.profiles
  add column if not exists persona_category text not null default '';
