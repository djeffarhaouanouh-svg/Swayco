-- Call mute, server-side. A device-local mute (SharedPreferences) can silence
-- the in-app / Android ring, but iOS CallKit rings straight from the VoIP push
-- fired by the backend — so the backend has to know who muted whom to skip it.
--
-- `muted_call_peers` on the callee's row lists the caller ids whose calls must
-- not ring this account. notify.js reads it before dispatching an
-- `incoming_call` push and drops the whole thing when the caller is in the set.
alter table public.profiles
  add column if not exists muted_call_peers uuid[] not null default '{}';
