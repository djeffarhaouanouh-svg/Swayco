-- 0079_weekly_friend_limit.sql
--
-- Plafond d'amis (= matchs) par semaine pour un compte SANS Pro : 5 sur 7 jours
-- glissants. Appliqué dans la base, donc impossible à contourner depuis l'app
-- (le client écrit directement dans `friendships`).
--
-- Un « ami » = une ligne `friendships` qui passe à status = 'accepted'. Le
-- trigger vérifie chaque personne de la ligne :
--   * compte IA (profiles.is_ai) : jamais plafonné ;
--   * compte Pro (is_pro) ou abonné (subscription_tier <> 'free') : jamais plafonné ;
--   * sinon : au moins 5 amis déjà acceptés sur les 7 derniers jours → refus.
-- Les amitiés déjà existantes ne sont pas touchées.
--
-- Erreur renvoyée : message 'weekly_friend_limit' (SQLSTATE P0001). L'app l'affiche
-- pour l'instant comme une erreur générique ; un message dédié viendra avec un
-- prochain build.
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
  v_user uuid;
  v_count int;
begin
  if new.status is distinct from 'accepted' then
    return new;
  end if;
  -- Seul le passage à « accepted » compte (pas une mise à jour d'une ligne déjà acceptée).
  if tg_op = 'UPDATE' and old.status = 'accepted' then
    return new;
  end if;

  foreach v_user in array array[new.requester, new.addressee] loop
    -- Les IA et les comptes Pro / abonnés ne sont jamais plafonnés.
    if exists (
      select 1 from public.profiles p
      where p.id = v_user
        and (coalesce(p.is_ai, false)
             or coalesce(p.is_pro, false)
             or coalesce(nullif(p.subscription_tier, ''), 'free') <> 'free')
    ) then
      continue;
    end if;

    select count(*) into v_count
    from public.friendships f
    where f.status = 'accepted'
      and f.id is distinct from new.id
      and (f.requester = v_user or f.addressee = v_user)
      and coalesce(f.responded_at, f.created_at) >= now() - v_window;

    if v_count >= v_limit then
      raise exception 'weekly_friend_limit'
        using errcode = 'P0001',
              hint = format('user %s already has %s friends this week', v_user, v_count);
    end if;
  end loop;

  return new;
end;
$$;

drop trigger if exists friendships_weekly_limit on public.friendships;
create trigger friendships_weekly_limit
  before insert or update on public.friendships
  for each row execute function public.enforce_weekly_friend_limit();
