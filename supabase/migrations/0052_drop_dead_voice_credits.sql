-- 0052_drop_dead_voice_credits.sql
--
-- Drop schema left behind after removing:
--   * translation credits / points
--   * ElevenLabs voice clone + dub
--   * chat voice messages (upload + playback)
--
-- Keeps referral_code / referred_by (invite attribution still runs).
-- Neutralises attribute_referral so it no longer writes credits.
--
-- One DROP per statement so the Supabase SQL editor can't split a
-- multi-action ALTER TABLE and leave a bare "drop column …" fragment.

-- ─── voice_dubs cache table ────────────────────────────────────────────────
drop table if exists public.voice_dubs;

-- ─── profiles: ElevenLabs + dub counters + credits ─────────────────────────
alter table public.profiles drop column if exists elevenlabs_voice_id;
alter table public.profiles drop column if exists voice_dubs_used_this_month;
alter table public.profiles drop column if exists voice_dubs_reset_at;
alter table public.profiles drop column if exists credits_seconds;
alter table public.profiles drop column if exists credits_reset_at;
alter table public.profiles drop column if exists lifetime_call_seconds;
alter table public.profiles drop column if exists referral_credits_granted;
alter table public.profiles drop constraint if exists profiles_voice_dubs_used_chk;

-- ─── messages: voice columns ───────────────────────────────────────────────
alter table public.messages drop constraint if exists messages_audio_duration_ms_chk;
alter table public.messages drop column if exists audio_url;
alter table public.messages drop column if exists audio_duration_ms;

-- ─── storage: voice-messages policy ────────────────────────────────────────
-- Supabase blocks direct DELETE on storage.objects / storage.buckets
-- (storage.protect_delete). Drop the public-read policy here; empty + delete
-- the `voice-messages` bucket from the Dashboard (Storage) or Storage API.
drop policy if exists "voice messages public read" on storage.objects;

-- ─── attribute_referral: keep the link, stop granting credits ──────────────
create or replace function public.attribute_referral(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_referrer_id uuid;
  v_existing_ref uuid;
  v_count int;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;
  if p_code is null or length(trim(p_code)) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'empty_code');
  end if;

  select id into v_referrer_id
    from public.profiles
   where referral_code = trim(p_code)
   limit 1;
  if v_referrer_id is null then
    return jsonb_build_object('ok', false, 'reason', 'unknown_code');
  end if;
  if v_referrer_id = v_uid then
    return jsonb_build_object('ok', false, 'reason', 'self_referral');
  end if;

  select referred_by into v_existing_ref
    from public.profiles where id = v_uid;
  if v_existing_ref is not null then
    return jsonb_build_object('ok', false, 'reason', 'already_referred');
  end if;

  update public.profiles set referred_by = v_referrer_id where id = v_uid;

  select count(*) into v_count
    from public.profiles where referred_by = v_referrer_id;

  return jsonb_build_object(
    'ok', true,
    'referrer', v_referrer_id,
    'referrals_total', v_count,
    'bonus_added_seconds', 0
  );
end$$;

revoke all on function public.attribute_referral(text) from public;
grant execute on function public.attribute_referral(text) to authenticated;
