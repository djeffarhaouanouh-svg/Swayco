-- 0097_engaged_user.sql
--
-- Événement AppsFlyer `engaged_user` : UNE seule fois par compte, quand la
-- personne a (1) au moins une amitié CONFIRMÉE et (2) envoyé au moins un message
-- à d'autres utilisateurs (conversation 1-à-1 OU groupe).
--
-- Ne comptent PAS : les appels, les demandes d'ami en attente, les messages à la
-- team Swayco (autre table : official_messages), la ligne système `group_left`.
--
-- L'événement part du SDK AppsFlyer côté app (c'est lui qui porte l'attribution
-- campagne / OneLink) ; la base décide SI et QUAND, de façon atomique :
--
--   engaged_claimed_at : un appareil a « réservé » l'envoi (bail de 10 min).
--   engaged_sent_at    : l'app a confirmé l'envoi → plus jamais d'événement.
--
-- Si l'app est tuée entre la réservation et la confirmation, le bail expire et
-- le prochain démarrage retente : pas de perte. Deux appareils / deux requêtes
-- simultanées : l'UPDATE conditionnel n'en laisse passer qu'une.

alter table public.profiles
  add column if not exists engaged_claimed_at timestamptz,
  add column if not exists engaged_sent_at timestamptz;

-- Réserve l'envoi. Rend true UNIQUEMENT à l'appelant qui doit envoyer
-- `engaged_user` maintenant.
create or replace function public.claim_engaged_user()
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  claimed int;
begin
  if uid is null then return false; end if;

  -- Déjà envoyé (ou en cours de réservation par un autre appel) : rien à faire.
  if exists (
    select 1 from public.profiles
    where id = uid and engaged_sent_at is not null
  ) then
    return false;
  end if;

  -- Condition 1 : au moins une amitié confirmée.
  if not exists (
    select 1 from public.friendships
    where status = 'accepted' and (requester = uid or addressee = uid)
  ) then
    return false;
  end if;

  -- Condition 2 : au moins un VRAI message écrit par la personne (DM ou groupe).
  -- Exclus, car générés automatiquement :
  --   · 'group_left'          ligne système « X a quitté le groupe » (0093)
  --   · 'quiz|…' 'quiz_done' 'quiz_stop|…'  messages posés par les quiz (0086/0090)
  --   · '👋'                  salutation automatique (Greetings.sendIntroMessage)
  -- Un message spécial (Discover) ou une photo / vidéo / voix / GIF envoyés
  -- par la personne comptent.
  if not exists (
    select 1 from public.messages
    where sender = uid
      and body <> 'group_left'
      and body <> 'quiz_done'
      and body <> '👋'
      and starts_with(body, 'quiz|') = false
      and starts_with(body, 'quiz_stop|') = false
  ) then
    return false;
  end if;

  -- Réservation atomique avec bail de 10 minutes.
  update public.profiles
     set engaged_claimed_at = now()
   where id = uid
     and engaged_sent_at is null
     and (engaged_claimed_at is null
          or engaged_claimed_at < now() - interval '10 minutes');
  get diagnostics claimed = row_count;
  return claimed = 1;
end;
$$;

-- L'app confirme que l'événement est parti : définitif.
create or replace function public.confirm_engaged_user_sent()
returns void
language sql
security definer
set search_path = public
as $$
  update public.profiles
     set engaged_sent_at = now()
   where id = auth.uid() and engaged_sent_at is null;
$$;

grant execute on function public.claim_engaged_user() to authenticated;
grant execute on function public.confirm_engaged_user_sent() to authenticated;
