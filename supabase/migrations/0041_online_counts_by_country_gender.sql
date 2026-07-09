-- 0041_online_counts_by_country_gender.sql
--
-- Powers the "5 Japonaises en ligne" pull notification. Counts the profiles
-- that are currently online, grouped by country + gender, so the backend
-- broadcast engine (backend/server.js → runOnlineBroadcast) can pick, for each
-- recipient, the country with the most opposite-sex users online right now.
--
-- "Online" mirrors the presence heartbeat: profiles.last_seen is refreshed
-- every ~90s while the app is foregrounded (see lib/services/presence_service
-- .dart), so a 5-minute window catches everyone currently active without
-- false positives from a single missed beat. Profiles that opted out of online
-- visibility (hide_online_status) are excluded, same as the rest of the app.
--
-- Only 'm' / 'f' rows are meaningful to the engine — 'x' and NULL genders can't
-- be labelled "Japonais"/"Japonaise", so they fall into their own bucket and
-- the engine ignores them.
--
-- SECURITY DEFINER + a tight grant: the backend calls this with the service
-- role (which already bypasses RLS), but defining it this way keeps the
-- aggregate server-side and never exposes individual rows.

create or replace function public.online_counts_by_country_gender(
  p_window_seconds integer default 300
)
returns table(country text, gender text, n integer)
language sql
security definer
set search_path = public
as $$
  select p.country,
         coalesce(nullif(p.gender, ''), 'x') as gender,
         count(*)::int                       as n
    from public.profiles p
   where p.last_seen > now() - make_interval(secs => greatest(p_window_seconds, 30))
     and coalesce(p.hide_online_status, false) = false
     and coalesce(p.country, '') <> ''
   group by p.country, coalesce(nullif(p.gender, ''), 'x');
$$;

revoke all on function public.online_counts_by_country_gender(integer) from public;
grant execute on function public.online_counts_by_country_gender(integer) to service_role;
