-- Profile photo gallery — a small ordered list of photo URLs shown in the
-- "Tes photos" section of the redesigned profile screen. The FIRST element
-- is the PDP (avatar) used everywhere in the app and the Discover-card photo,
-- so `avatar_url` / `discover_photo_url` are kept in sync with photos[0] by
-- ProfileApi.addProfilePhoto / removeProfilePhoto.
--
-- Stored as text[] (one public URL per element). Not-null with a default of
-- the empty array so existing rows need no schema-time backfill and the
-- upsert path in ProfileApi.upsertMyProfile (which never touches this column)
-- is unaffected.
alter table public.profiles
  add column if not exists photos text[] not null default '{}';

-- Backfill: seed the gallery from the single Discover photo that legacy rows
-- already have, so users who uploaded a photo before this migration still see
-- it in the new gallery without re-uploading.
update public.profiles
   set photos = array[discover_photo_url]
 where discover_photo_url is not null
   and discover_photo_url <> ''
   and (photos is null or photos = '{}');
