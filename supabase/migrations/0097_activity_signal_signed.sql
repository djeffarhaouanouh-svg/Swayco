-- 0097_activity_signal_signed.sql
--
-- « En appel » / « écrit » : plus personne ne peut se faire passer pour un autre.
--
-- Avant : chaque téléphone publiait lui-même son identifiant sur un canal public.
-- Maintenant : il appelle `publish_activity(appel, écrit)` ; le SERVEUR met
-- l'identifiant d'après la session (auth.uid()) et diffuse sur le canal PRIVÉ
-- `activity-v2`. Les clients connectés peuvent l'écouter, aucun ne peut y écrire
-- (pas de règle d'insertion sur ce canal).

create or replace function public.publish_activity(p_call boolean, p_typing boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  hidden boolean;
begin
  if uid is null then raise exception 'not authenticated'; end if;
  select coalesce(hide_online_status, false) into hidden
    from public.profiles where id = uid;
  -- Statut masqué : rien d'autre que « je ne fais rien ».
  perform realtime.send(
    jsonb_build_object(
      'user', uid,
      'call', coalesce(p_call, false) and not coalesce(hidden, false),
      'typing', coalesce(p_typing, false) and not coalesce(hidden, false)
    ),
    'act',
    'activity-v2',
    true
  );
end;
$$;

revoke all on function public.publish_activity(boolean, boolean) from public, anon;
grant execute on function public.publish_activity(boolean, boolean) to authenticated;

drop policy if exists "activity_v2_receive" on realtime.messages;
create policy "activity_v2_receive"
  on realtime.messages for select
  to authenticated
  using (
    realtime.topic() = 'activity-v2'
    and realtime.messages.extension = 'broadcast'
  );