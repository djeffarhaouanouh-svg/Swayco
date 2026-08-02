-- Share of members in a given country — powers the "RARE · 0,3 %" match card.
-- SECURITY DEFINER so the client can read the aggregate without scanning
-- every profile row under RLS.
create or replace function public.country_member_share(p_country text)
returns table(n integer, total integer)
language sql
security definer
set search_path = public
as $$
  with totals as (
    select count(*)::int as total from public.profiles
  ),
  country as (
    select count(*)::int as n
      from public.profiles
     where coalesce(country, '') = coalesce(nullif(trim(p_country), ''), '')
  )
  select country.n, totals.total from country, totals;
$$;

revoke all on function public.country_member_share(text) from public;
grant execute on function public.country_member_share(text) to authenticated, anon;
