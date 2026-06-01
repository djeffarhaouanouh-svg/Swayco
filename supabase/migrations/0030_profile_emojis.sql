-- Profile "emojis" — a short, expressive list of emojis the user picks to
-- decorate their profile. Rendered as tiles in the "Emojis" section of the
-- profile screen (between the photo and the bio), mirroring the redesigned
-- layout. Capped client-side at 5; stored as a text[] so each element is one
-- grapheme/emoji.
--
-- Nullable-free with a default of the empty array so existing rows need no
-- backfill and the upsert path in ProfileApi.upsertMyProfile (which never
-- touches this column) is unaffected.

alter table public.profiles
  add column if not exists emojis text[] not null default '{}';
