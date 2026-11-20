-- 0089_group_photo.sql
--
-- La photo d'un groupe peut être changée (jusque-là : mosaïque automatique).
-- Vide = la mosaïque des photos des membres.
alter table public.chat_groups
  add column if not exists photo_url text not null default '';

-- Tout membre peut changer la photo du groupe.
create or replace function public.group_set_photo(p_group uuid, p_url text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_group_member(p_group) then
    raise exception 'not a member';
  end if;
  update public.chat_groups set photo_url = coalesce(p_url, '') where id = p_group;
end;
$$;

grant execute on function public.group_set_photo(uuid, text) to authenticated;
