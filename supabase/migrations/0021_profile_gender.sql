-- 0021_profile_gender.sql
--
-- Adds an optional `gender` field on profiles so the contextual chat
-- translator (backend `/translation/text`) can pick the correct
-- grammatical gender in gendered target languages (FR/ES/IT/AR/HE/…).
--
-- Not surfaced in the UI yet — the column exists so backend + Dart model
-- can already wire it. When the profile editor exposes it, no further
-- migration is required.
--
-- Values:
--   'm' — masculine
--   'f' — feminine
--   'x' — non-binary / unspecified
--   NULL — not provided (translator falls back to context-only inference)

alter table public.profiles
  add column if not exists gender text;

alter table public.profiles
  drop constraint if exists profiles_gender_chk;

alter table public.profiles
  add constraint profiles_gender_chk
    check (gender is null or gender in ('m', 'f', 'x'));
