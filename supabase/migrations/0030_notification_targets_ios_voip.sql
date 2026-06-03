-- iOS CallKit needs a second device target per iPhone: the PushKit VoIP
-- token (distinct from the regular FCM/APNs token). Allow a new platform
-- value `ios_voip` so the app can store it and the backend can fan a VoIP
-- push to it for incoming calls.
--
-- The unique upsert key (user_id, fcm_token) is already covered by the
-- non-partial index added in 0029, so no new index is needed here — the
-- VoIP token is stored in the existing fcm_token column.

alter table public.notification_targets
  drop constraint if exists notification_targets_platform_check;

alter table public.notification_targets
  add constraint notification_targets_platform_check
  check (platform in ('web', 'ios', 'android', 'ios_voip'));
