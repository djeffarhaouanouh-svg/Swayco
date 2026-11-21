-- 0093_group_leave_message.sql
--
-- Quand un membre quitte un groupe, une LIGNE SYSTÈME s'ajoute dans la
-- conversation pour les autres (« Lucas a quitté le groupe ») : un message de
-- corps `group_left`, écrit au nom de celui qui part (son prénom reste dans
-- `sender_name`). Pas de notification : seulement la ligne.
--
-- Même règles qu'avant pour le reste : plus d'admin → le plus ancien membre le
-- devient ; plus personne → le groupe est supprimé (et, dans ce cas, aucune
-- ligne : il n'y a plus personne pour la lire).

create or replace function public.group_leave(p_group uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  first_name text;
  others int;
begin
  if uid is null then raise exception 'not authenticated'; end if;
  if not exists (
    select 1 from public.chat_group_members
    where group_id = p_group and user_id = uid
  ) then
    return;
  end if;

  select count(*) into others
  from public.chat_group_members
  where group_id = p_group and user_id <> uid;

  -- La ligne « X a quitté le groupe », AVANT de retirer la personne.
  if others > 0 then
    select split_part(coalesce(nullif(btrim(display_name), ''), ''), ' ', 1)
      into first_name
    from public.profiles where id = uid;
    insert into public.messages
      (conversation_id, sender, sender_name, body, language)
    values
      ('grp-' || p_group::text, uid, coalesce(first_name, ''), 'group_left', '');
  end if;

  delete from public.chat_group_members
  where group_id = p_group and user_id = uid;

  -- Plus personne : le groupe disparaît.
  if others = 0 then
    delete from public.chat_groups where id = p_group;
    return;
  end if;

  -- Plus d'admin : le plus ancien membre le devient.
  if not exists (
    select 1 from public.chat_group_members
    where group_id = p_group and role = 'admin'
  ) then
    update public.chat_group_members
    set role = 'admin'
    where group_id = p_group
      and user_id = (
        select user_id from public.chat_group_members
        where group_id = p_group
        order by joined_at asc, user_id asc
        limit 1
      );
  end if;
end;
$$;

grant execute on function public.group_leave(uuid) to authenticated;
