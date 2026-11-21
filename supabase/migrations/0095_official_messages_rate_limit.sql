-- 0095_official_messages_rate_limit.sql
--
-- Limite d'envoi vers la team Swayco : 5 messages par personne sur 24 h glissantes.
-- Posée en base (déclencheur) : l'app ne peut pas la contourner. Au-delà, l'insertion
-- échoue avec le message `official_rate_limited`, que l'app traduit pour la personne.

create or replace function public.official_messages_rate_limit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if (
    select count(*)
      from public.official_messages
     where user_id = new.user_id
       and created_at > now() - interval '24 hours'
  ) >= 5 then
    raise exception 'official_rate_limited' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

drop trigger if exists official_messages_rate_limit_trg on public.official_messages;
create trigger official_messages_rate_limit_trg
  before insert on public.official_messages
  for each row execute function public.official_messages_rate_limit();