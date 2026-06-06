-- Block-proof relationship management.
--
-- When a peer blocks me, the (restrictive) deployed RLS on `friendships` can
-- hide our edge from a direct client SELECT (`FriendshipApi.fetchMine`). That
-- left the profile screen unable to tell I still follow them, so the
-- "Se désabonner" button vanished AND the peer dropped out of my
-- abonnements / abonnés — leaving me stuck, following someone with no way to
-- clean it up.
--
-- These SECURITY DEFINER helpers bypass RLS (exactly like friendship_counts
-- in 0003 and friendship_accepted_peers in 0005 already do) so the
-- relationship always resolves and the unfollow always lands, block or no
-- block. They only ever expose / act on the single (me, peer) pair, so no
-- extra data leaks.

-- Resolve how I (`p_me`) stand with `p_peer`, ignoring RLS.
create or replace function public.friendship_directional(
  p_me   uuid,
  p_peer uuid
)
returns table(
  peer_follows_me  boolean,
  i_follow_peer    boolean,
  i_requested_peer boolean
)
language sql
security definer
set search_path = public
as $$
  select
    coalesce(bool_or(requester = p_peer and addressee = p_me   and status = 'accepted'), false),
    coalesce(bool_or(requester = p_me   and addressee = p_peer and status = 'accepted'), false),
    coalesce(bool_or(requester = p_me   and addressee = p_peer and status = 'pending'),  false)
  from public.friendships
  where (requester = p_me   and addressee = p_peer)
     or (requester = p_peer and addressee = p_me);
$$;

revoke all on function public.friendship_directional(uuid, uuid) from public;
grant execute on function public.friendship_directional(uuid, uuid)
  to anon, authenticated;

-- Delete my outgoing follow edge to a peer, bypassing RLS so it lands even
-- when the peer has blocked me. Idempotent (deleting nothing is fine).
create or replace function public.friendship_unfollow(
  p_me   uuid,
  p_peer uuid
)
returns void
language sql
security definer
set search_path = public
as $$
  delete from public.friendships
   where requester = p_me and addressee = p_peer;
$$;

revoke all on function public.friendship_unfollow(uuid, uuid) from public;
grant execute on function public.friendship_unfollow(uuid, uuid)
  to anon, authenticated;

-- Re-assert the accepted-peers + counts helpers WITHOUT any block filter, in
-- case the deployed copies drifted into hiding blockers (which is what made
-- the peer disappear from my abonnements / abonnés). Same bodies as
-- migrations 0005 / 0003.
create or replace function public.friendship_accepted_peers(
  p_user_id   uuid,
  p_direction text
)
returns table(peer_id uuid)
language sql
security definer
set search_path = public
as $$
  select case
           when p_direction = 'followers' then requester
           else addressee
         end as peer_id
    from public.friendships
   where status = 'accepted'
     and (
       (p_direction = 'followers' and addressee = p_user_id)
       or
       (p_direction = 'following' and requester = p_user_id)
     );
$$;

revoke all on function public.friendship_accepted_peers(uuid, text) from public;
grant execute on function public.friendship_accepted_peers(uuid, text)
  to anon, authenticated;

create or replace function public.friendship_counts(p_user_id uuid)
returns table(followers int, following int)
language sql
security definer
set search_path = public
as $$
  select
    (select count(*)::int
       from public.friendships
       where addressee = p_user_id and status = 'accepted') as followers,
    (select count(*)::int
       from public.friendships
       where requester = p_user_id and status = 'accepted') as following;
$$;

revoke all on function public.friendship_counts(uuid) from public;
grant execute on function public.friendship_counts(uuid) to anon, authenticated;
