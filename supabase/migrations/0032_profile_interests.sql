-- Profile "interests" (centres d'intérêt) — a short list of predefined tags
-- the user picks from category groups (Musique / Sport / Films & Séries /
-- Gaming / Lifestyle …), rendered as chips in the "Centres d'intérêt" section
-- of the profile (replacing the old free-emoji section). Capped client-side
-- at 8; stored as a text[] of the tag labels.
--
-- Not-null with a default of the empty array so existing rows need no
-- backfill and the upsert path in ProfileApi.upsertMyProfile (which never
-- touches this column) is unaffected. The legacy `emojis` column is left in
-- place (no longer surfaced in the UI) rather than dropped, to avoid a
-- destructive change.
alter table public.profiles
  add column if not exists interests text[] not null default '{}';
