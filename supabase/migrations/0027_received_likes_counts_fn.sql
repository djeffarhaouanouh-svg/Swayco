-- Aggregate count of `received likes` for a batch of profile ids.
-- Needed because the table-level RLS on `likes` only lets a user read
-- the rows where they are the liker or the liked — counting likes on
-- *other* users from the client is therefore impossible without
-- bypassing RLS. This SECURITY DEFINER function returns only the
-- aggregate per id (no row data), so leaking is bounded to the
-- popularity metric the Discover deck already wants to highlight.
--
-- Idempotent: re-running drops + recreates.

create or replace function public.received_likes_counts(
  p_ids uuid[]
)
returns table(liked uuid, n bigint)
language sql
security definer
set search_path = public
as $$
  select l.liked, count(*)::bigint as n
    from public.likes l
   where l.liked = any(p_ids)
   group by l.liked;
$$;

revoke all on function public.received_likes_counts(uuid[]) from public;
grant execute on function public.received_likes_counts(uuid[])
  to anon, authenticated;
