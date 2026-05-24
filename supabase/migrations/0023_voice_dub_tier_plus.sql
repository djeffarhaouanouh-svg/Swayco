-- 0023_voice_dub_tier_plus.sql
--
-- Adds the "Plus" tier and the per-user counters the backend uses to
-- gate voice-dub TTS calls.
--
-- Changes:
--   * subscription_tier check now allows 'plus' alongside the existing
--     'free' / 'pro' / 'ultra' values.
--   * voice_dubs_used_this_month / voice_dubs_reset_at — rolling
--     30-day budget for /voice/dub. Plus is capped at 60/month; Pro
--     and Ultra are uncapped (`Infinity` in backend/tiers.js) so the
--     counter still increments but no refusal is issued.
--   * elevenlabs_voice_id — populated once an Ultra user enrols their
--     voice via the (forthcoming) /voice/enroll endpoint. Outgoing
--     dubs from that user then use this voice_id instead of the
--     generic per-language fallback.

-- 1) Tier values allowed on the profiles row.
alter table public.profiles
  drop constraint if exists profiles_subscription_tier_chk;
alter table public.profiles
  add constraint profiles_subscription_tier_chk
    check (subscription_tier in ('free', 'plus', 'pro', 'ultra'));

-- 2) Monthly voice-dub counter. Default 0 / now() so existing rows
--    behave as fresh-budget users on first /voice/dub call.
alter table public.profiles
  add column if not exists voice_dubs_used_this_month integer not null default 0;

alter table public.profiles
  add column if not exists voice_dubs_reset_at timestamptz not null default now();

-- Sanity bound: the counter is always non-negative. The backend resets
-- it whenever now() >= voice_dubs_reset_at, so it should never grow
-- past the per-tier cap (60 on plus, unbounded otherwise).
alter table public.profiles
  drop constraint if exists profiles_voice_dubs_used_chk;
alter table public.profiles
  add constraint profiles_voice_dubs_used_chk
    check (voice_dubs_used_this_month >= 0);

-- 3) ElevenLabs Instant Voice Clone id for Ultra users. NULL until
--    enrolled. No FK — the lifetime of the voice is managed by
--    ElevenLabs, not the DB.
alter table public.profiles
  add column if not exists elevenlabs_voice_id text;

-- 4) Cache the generated dub audio so we never bill ElevenLabs twice
--    for the same (message, target_language) pair. Keyed by the
--    composite primary key so concurrent requests don't blow up on
--    duplicate inserts.
-- NB: messages.id is a bigint on this schema (auto-increment), not
-- uuid — match the type exactly or the FK creation fails with
-- "key columns are of incompatible types".
create table if not exists public.voice_dubs (
  message_id bigint not null references public.messages(id) on delete cascade,
  target_language text not null,
  audio_url text not null,
  -- Track which model + voice produced the dub so we can clear /
  -- regenerate stale entries when we switch defaults.
  tts_model text,
  voice_id text,
  created_at timestamptz not null default now(),
  primary key (message_id, target_language)
);

-- Service-role only — the dub generator inserts here, and the chat
-- bubble reads via the backend (never directly from RLS-gated client
-- code). No public select policy is set up, which means the table is
-- locked down by default (Supabase enables RLS for any table without
-- explicit policies in the `public` schema if you've enabled the
-- service-side defaults).
alter table public.voice_dubs enable row level security;
