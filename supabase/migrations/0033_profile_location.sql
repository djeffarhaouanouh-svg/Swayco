-- Profile location — free-text country + city the user enters in the profile
-- editor (between Bio and the spoken-language picker). Shown in small text
-- under the name on the Discover card (e.g. "Paris, France").
--
-- Two plain text columns, not-null with empty-string defaults so existing
-- rows need no backfill and the upsert path in ProfileApi.upsertMyProfile
-- (which never touches these columns) is unaffected.
alter table public.profiles
  add column if not exists country text not null default '';

alter table public.profiles
  add column if not exists city text not null default '';
