-- Fix native push registration silently dropping every FCM token.
--
-- NotificationApi.registerFcm upserts with ON CONFLICT (user_id, fcm_token),
-- but 0011 only created a PARTIAL unique index on those columns
-- (`… where platform in ('ios','android')`). Postgres cannot use a partial
-- index as an ON CONFLICT arbiter unless the INSERT carries the same
-- predicate — which PostgREST's upsert does not — so the statement raised
-- "no unique or exclusion constraint matching the ON CONFLICT specification".
-- registerFcm swallowed that error and returned false, so the device token
-- was never stored: the backend had no target row and no native push was
-- ever sent, even with every env var configured.
--
-- Replace the partial index with a plain (non-partial) unique index on
-- (user_id, fcm_token). Web rows keep fcm_token NULL and NULLs are distinct,
-- so this does not constrain them; the web upsert keys on (user_id, endpoint)
-- via its own index, untouched here.

drop index if exists public.notification_targets_native_unique;

create unique index if not exists notification_targets_fcm_unique
  on public.notification_targets (user_id, fcm_token);
