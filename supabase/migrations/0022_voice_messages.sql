-- 0022_voice_messages.sql
--
-- Voice messages: a chat message that was recorded as audio. The audio
-- file lives in Supabase Storage (bucket `voice-messages`) and the
-- transcription produced by the backend (ElevenLabs Scribe) is written
-- into the existing `body` column so foreign-message text translation
-- (see chat_thread_screen.dart) works unchanged.
--
-- Columns:
--   audio_url        — public URL of the original recording. NULL for
--                      regular text messages.
--   audio_duration_ms — recording length in milliseconds. Used by the
--                      bubble UI to render the duration label without
--                      having to decode the file first.
--
-- The `language` column already exists (chat_api.dart's `sendMessage`
-- writes it). The STT pipeline fills it with the detected source
-- language so the translator knows what to convert FROM.

alter table public.messages
  add column if not exists audio_url text;

alter table public.messages
  add column if not exists audio_duration_ms integer;

-- Sanity bounds. Frontend caps to 60s (60000ms); the upper bound here
-- is intentionally a little higher so a 60s recording with a tiny
-- overshoot doesn't get rejected by the DB.
alter table public.messages
  drop constraint if exists messages_audio_duration_ms_chk;
alter table public.messages
  add constraint messages_audio_duration_ms_chk
    check (
      audio_duration_ms is null
      or (audio_duration_ms > 0 and audio_duration_ms <= 120000)
    );

-- Storage bucket — created idempotently. Public read so the chat bubble
-- can stream the audio without a presigned URL handshake; private write
-- (the backend uses the service-role key to upload). If you prefer
-- private reads, drop the `public => true` and add a signed-URL flow.
insert into storage.buckets (id, name, public)
values ('voice-messages', 'voice-messages', true)
on conflict (id) do nothing;

-- Public read policy on the bucket so anyone with the URL can play the
-- clip (URLs are random-UUID paths — security through obscurity for the
-- MVP; tighten with RLS keyed on conversation participation later).
drop policy if exists "voice messages public read" on storage.objects;
create policy "voice messages public read"
  on storage.objects for select
  using (bucket_id = 'voice-messages');
