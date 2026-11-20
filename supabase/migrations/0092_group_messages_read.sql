-- 0092_group_messages_read.sql
--
-- Les membres d'un groupe doivent pouvoir LIRE les messages du groupe.
--
-- Un message de groupe n'a pas de destinataire (`recipient` vide) : une règle de
-- lecture du type « je suis l'auteur OU le destinataire » ne le montre à
-- personne d'autre que son auteur (constaté : le message d'un membre n'apparaît
-- ni dans la conversation ni dans le flux temps réel des autres membres).
--
-- Cette règle s'AJOUTE aux règles existantes (elles se cumulent en « ou ») : un
-- membre du groupe `grp-<uuid>` lit les messages de cette conversation, et
-- personne d'autre. Le flux temps réel suit la même règle.

create or replace function public.is_group_conversation_member(conv text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select conv like 'grp-%'
    and exists (
      select 1
      from public.chat_group_members m
      where m.user_id = auth.uid()
        and ('grp-' || m.group_id::text) = conv
    );
$$;

grant execute on function public.is_group_conversation_member(text) to authenticated;

drop policy if exists "messages_select_group_member" on public.messages;
create policy "messages_select_group_member"
  on public.messages for select
  to authenticated
  using ( public.is_group_conversation_member(conversation_id) );
