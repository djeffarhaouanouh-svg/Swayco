-- Image messages — a public URL of a photo sent in a chat thread, shown as
-- an image bubble. Empty for text / voice messages. The file itself lives in
-- the existing `avatars` storage bucket under a `chat/<conversation>/` prefix
-- (reuses that bucket's RLS instead of provisioning a new one).
--
-- Not-null with an empty-string default so existing rows need no backfill and
-- ChatApi.sendMessage / the voice pipeline (which never set it) are unaffected.
alter table public.messages
  add column if not exists image_url text not null default '';
