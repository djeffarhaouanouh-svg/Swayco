-- Discover intro messages — when a user sends a one-off message straight from
-- a Discover card, we stamp the message with the PHOTO it was sent about. The
-- Discover deck is one card per photo, so the "one intro message per person"
-- rule is actually "one per photo": a person with several photos can be
-- messaged once from each of their cards.
--
-- Empty for every other message (normal chat, voice, emoji reactions). Used by
-- ChatApi.fetchMyMessagedPhotos to collapse a card's message field to its
-- "sent" state, persisted across restarts.
alter table public.messages
  add column if not exists discover_photo text not null default '';
