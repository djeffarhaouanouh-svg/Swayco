-- A push token identifies a DEVICE, not an account — so it must belong to
-- exactly one user at a time.
--
-- 0011/0029 key notification_targets on (user_id, fcm_token), which lets the
-- same physical device sit in the table under several user_ids at once, and
-- nothing ever removed the stale owner: signing out purges nothing, and the
-- backend only deletes a token when APNs answers 410/Unregistered (a token
-- belonging to a signed-out account stays perfectly valid).
--
-- Symptom that surfaced this: an iPhone signed into account A rang ITSELF with
-- CallKit, showing A's own first name, whenever A called B. That phone had once
-- been signed in as B, so B's target list still held its VoIP token; notify.js
-- fans out to every target of the callee, so the caller's own phone got the
-- VoIP push and AppDelegate rang it.
--
-- Fix: (1) purge the stale duplicates, (2) enforce single ownership on write.

-- 1. Existing duplicates: for every token owned by more than one account, keep
--    the most recently refreshed row (that is the device's current account) and
--    drop the rest.
delete from public.notification_targets t
using public.notification_targets keep
where t.fcm_token is not null
  and keep.fcm_token = t.fcm_token
  and keep.user_id <> t.user_id
  and (
    keep.updated_at > t.updated_at
    or (keep.updated_at = t.updated_at and keep.id > t.id)
  );

delete from public.notification_targets t
using public.notification_targets keep
where t.endpoint is not null
  and keep.endpoint = t.endpoint
  and keep.user_id <> t.user_id
  and (
    keep.updated_at > t.updated_at
    or (keep.updated_at = t.updated_at and keep.id > t.id)
  );

-- 2. On every insert/upsert, the incoming (user_id, token) pair becomes the sole
--    owner of that token: any row holding the same token under a different
--    account is a device that has since been re-signed-in elsewhere.
--
--    SECURITY DEFINER so the delete can reach rows owned by the OTHER user —
--    the caller's RLS policy (auth.uid() = user_id) could never do that itself.
create or replace function public.notification_targets_claim_token()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.fcm_token is not null then
    delete from public.notification_targets
     where fcm_token = new.fcm_token
       and user_id <> new.user_id;
  end if;

  if new.endpoint is not null then
    delete from public.notification_targets
     where endpoint = new.endpoint
       and user_id <> new.user_id;
  end if;

  return new;
end;
$$;

drop trigger if exists notification_targets_claim_token_trg
  on public.notification_targets;

create trigger notification_targets_claim_token_trg
  before insert or update on public.notification_targets
  for each row execute function public.notification_targets_claim_token();
