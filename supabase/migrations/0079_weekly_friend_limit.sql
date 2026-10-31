-- 0079_weekly_friend_limit.sql
--
-- Plafond d'amis IA par semaine pour un compte SANS Pro : 5 amis IA sur 7 jours
-- glissants. Les amis HUMAINS ne sont jamais limités. Appliqué dans la base, donc
-- impossible à contourner depuis l'app (le client écrit directement dans
-- `friendships`).
--
-- Un « ami » = une ligne `friendships` qui passe à status = 'accepted'. Le
-- trigger ne s'intéresse qu'aux lignes entre un humain et une IA :
--   * deux humains (ou deux IA) : jamais plafonné ;
--   * l'humain est Pro (is_pro) ou abonné (subscription_tier <> 'free') : jamais plafonné ;
--   * sinon : s'il a déjà 5 amis IA acceptés sur les 7 derniers jours, la 6e IA
--     ne devient pas son amie (la demande reste en attente, l'IA ne répond pas).
-- Les amitiés déjà existantes ne sont pas touchées.
--
-- Erreur renvoyée : message 'weekly_friend_limit' (SQLSTATE P0001). Côté backend,
-- l'acceptation automatique de l'IA échoue simplement ; l'app affiche une erreur
-- générique si l'humain essaie d'accepter lui-même une IA.
--
-- Pour changer le plafond : modifier la valeur de v_limit ci-dessous et relancer.
-- À appliquer dans l'éditeur SQL de Supabase.

create or replace function public.enforce_weekly_friend_limit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_limit constant int := 5;
  v_window constant interval := interval '7 days';
  v_requester_ai boolean;
  v_addressee_ai boolean;
  v_human uuid;
  v_count int;
begin
  if new.status is distinct from 'accepted' then
    return new;
  end if;
  -- Seul le passage à « accepted » compte (pas une mise à jour d'une ligne déjà acceptée).
  if tg_op = 'UPDATE' and old.status = 'accepted' then
    return new;
  end if;

  select coalesce(is_ai, false) into v_requester_ai from public.profiles where id = new.requester;
  select coalesce(is_ai, false) into v_addressee_ai from public.profiles where id = new.addressee;

  -- Seule une amitié humain <-> IA est plafonnée.
  if coalesce(v_requester_ai, false) = coalesce(v_addressee_ai, false) then
    return new;
  end if;
  v_human := case when coalesce(v_requester_ai, false) then new.addressee else new.requester end;

  -- Les comptes Pro / abonnés ne sont jamais plafonnés.
  if exists (
    select 1 from public.profiles p
    where p.id = v_human
      and (coalesce(p.is_pro, false)
           or coalesce(nullif(p.subscription_tier, ''), 'free') <> 'free')
  ) then
    return new;
  end if;

  -- Amis IA déjà acceptés sur la fenêtre.
  select count(*) into v_count
  from public.friendships f
  join public.profiles o
    on o.id = case when f.requester = v_human then f.addressee else f.requester end
  where f.status = 'accepted'
    and f.id is distinct from new.id
    and (f.requester = v_human or f.addressee = v_human)
    and coalesce(o.is_ai, false)
    and coalesce(f.responded_at, f.created_at) >= now() - v_window;

  if v_count >= v_limit then
    raise exception 'weekly_friend_limit'
      using errcode = 'P0001',
            hint = format('user %s already has %s AI friends this week', v_human, v_count);
  end if;

  return new;
end;
$$;

drop trigger if exists friendships_weekly_limit on public.friendships;
create trigger friendships_weekly_limit
  before insert or update on public.friendships
  for each row execute function public.enforce_weekly_friend_limit();
