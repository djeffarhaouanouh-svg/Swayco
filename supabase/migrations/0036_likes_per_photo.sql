-- Per-photo likes & reactions.
--
-- Until now a "like" was keyed by (liker, liked) — one row per person, for
-- the whole profile — so posting new photos inherited the old like count.
-- A photo reaction (🔥✨😍, stored as a chat message) was keyed by
-- (sender, recipient, emoji), same problem.
--
-- This migration makes a like belong to a specific PHOTO (its public URL):
--   • likes PK becomes (liker, liked, photo_url)
--   • reactions stamp the photo URL into the existing messages.discover_photo
--     column (handled app-side; no schema change needed there)
-- Deleting a photo drops that photo's received likes; reposting a photo gets
-- a brand-new URL, hence zero likes/reactions. Each photo is independent.
--
-- Existing profile-level likes have no photo association, so they are wiped
-- (a one-time reset) — the app counts likes per photo_url from now on.

-- 1) Add the photo column and re-key the table.
alter table public.likes
  add column if not exists photo_url text not null default '';

-- Wipe legacy profile-level likes (no photo) — a clean reset.
delete from public.likes where photo_url = '';

alter table public.likes drop constraint if exists likes_pkey;
alter table public.likes add primary key (liker, liked, photo_url);

-- 2) received_likes_counts: popularity = number of DISTINCT people who liked
--    any of the user's photos (a person liking three photos still counts once).
create or replace function public.received_likes_counts(
  p_ids uuid[]
)
returns table(liked uuid, n bigint)
language sql
security definer
set search_path = public
as $$
  select l.liked, count(distinct l.liker)::bigint as n
    from public.likes l
   where l.liked = any(p_ids)
   group by l.liked;
$$;

revoke all on function public.received_likes_counts(uuid[]) from public;
grant execute on function public.received_likes_counts(uuid[])
  to anon, authenticated;

-- 3) Per-photo wipe of received likes — called when the owner deletes a photo.
--    SECURITY DEFINER + derives the owner from auth.uid() so a caller can only
--    ever wipe likes on their OWN photos (table RLS only lets the liker delete).
create or replace function public.delete_my_received_likes_for_photo(
  p_photo text
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_count integer := 0;
begin
  if v_uid is null or coalesce(p_photo, '') = '' then
    return 0;
  end if;
  with deleted as (
    delete from public.likes
      where liked = v_uid and photo_url = p_photo
      returning 1
  )
  select count(*) into v_count from deleted;
  return v_count;
end;
$$;

revoke all on function public.delete_my_received_likes_for_photo(text) from public;
grant execute on function public.delete_my_received_likes_for_photo(text)
  to authenticated;
