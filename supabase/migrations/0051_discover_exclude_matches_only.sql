-- Discover: only hide accepted matches. Pending outgoing likes stay in the
-- deck so "Recommencer" still has people after a pass through the feed.
-- Unmatch deletes the accepted row → they become eligible again.

create or replace function public.discover_feed(
  p_user_id uuid,
  p_limit   int default 50
)
returns setof public.profiles
language sql
security definer
set search_path = public
as $$
  with me as (
    select id, lower(coalesce(language, '')) as lang
      from public.profiles
     where id = p_user_id
     limit 1
  ),
  blocked as (
    select case when blocker = p_user_id then blocked else blocker end as peer
      from public.blocked_users
     where blocker = p_user_id or blocked = p_user_id
  ),
  matched as (
    select case
             when requester = p_user_id then addressee
             else requester
           end as peer
      from public.friendships
     where status = 'accepted'
       and (requester = p_user_id or addressee = p_user_id)
  )
  select p.*
    from public.profiles p
    cross join me
   where p.id <> p_user_id
     and coalesce(p.discover_photo_url, '') <> ''
     and p.id not in (select peer from blocked)
     and p.id not in (select peer from matched)
     and not (
       coalesce(p.hide_from_country, false) = true
       and me.lang <> ''
       and lower(coalesce(p.language, '')) = me.lang
     )
   order by p.updated_at desc
   limit greatest(coalesce(p_limit, 50), 0);
$$;

revoke all on function public.discover_feed(uuid, int) from public;
grant execute on function public.discover_feed(uuid, int)
  to anon, authenticated;
