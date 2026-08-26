-- 0057_waves.sql
--
-- « Faire signe » (👋) — le geste de Houseparty. Un ping, rien d'autre :
-- pas de message écrit dans le fil, pas de sonnerie. La personne reçoit une
-- notification « X te fait signe » et vient si elle veut.
--
-- Le plafond est LA raison d'être de ce fichier. Un geste sans coût devient
-- du spam en une semaine, donc il ne s'écrit pas côté client — la table n'a
-- AUCUNE policy d'insertion. Le seul chemin d'écriture est `send_wave()`,
-- security definer, qui compte avant d'insérer :
--
--   * 3 d'affilée au maximum vers la même personne, tant qu'elle n'a pas
--     répondu. Répondre = un message d'elle vers moi, un signe d'elle vers
--     moi, ou simplement avoir vu mon signe (`seen_at`). N'importe lequel
--     des trois remet le compteur à zéro.
--   * 5 par 24 h vers la même personne, même si elle répond entre chaque.
--   * Rien ne limite le NOMBRE de personnes : on peut saluer toute sa liste.
--
-- Fenêtre glissante de 24 h et pas « depuis minuit » : les deux bouts d'un
-- appel traduit ne sont presque jamais dans le même fuseau, et un plafond
-- qui se rouvre à une heure différente pour chacun ne s'explique pas.
--
-- `messages` a bien les colonnes `sender` / `recipient` (cf. 0055 et
-- `ChatApi.sendMessage`) — pas le `sender_id` du croquis 0001, que la table
-- de production a laissé derrière elle.
--
-- Idempotent : sûr à rejouer.

create table if not exists public.waves (
  id         uuid        primary key default gen_random_uuid(),
  sender     uuid        not null,
  recipient  uuid        not null,
  created_at timestamptz not null default now(),
  -- Posé par le client du destinataire quand le signe lui est apparu. Sert
  -- à deux choses : ne plus l'afficher, et rouvrir le compteur d'affilée.
  seen_at    timestamptz,
  constraint waves_not_self check (sender <> recipient)
);

-- « Les signes qu'on m'a faits, les plus récents d'abord » — la requête de
-- l'écran Messages à chaque ouverture.
create index if not exists waves_recipient_idx
  on public.waves (recipient, created_at desc);

-- « Combien de fois ai-je fait signe à cette personne » — les deux comptages
-- du plafond, et le préchargement de l'état des boutons.
create index if not exists waves_pair_idx
  on public.waves (sender, recipient, created_at desc);

alter table public.waves enable row level security;

-- Visible des deux personnes concernées, de personne d'autre.
drop policy if exists "waves_select_involved" on public.waves;
create policy "waves_select_involved"
  on public.waves
  for select
  to authenticated
  using (sender = auth.uid() or recipient = auth.uid());

-- Le destinataire marque qu'il a vu. C'est la SEULE écriture directe permise,
-- et elle ne touche que `seen_at` (les autres colonnes restent celles de
-- l'insertion : le `with check` interdit de se réattribuer la ligne).
drop policy if exists "waves_update_seen" on public.waves;
create policy "waves_update_seen"
  on public.waves
  for update
  to authenticated
  using (recipient = auth.uid())
  with check (recipient = auth.uid());

-- Pas de policy d'insertion, volontairement : voir l'en-tête. Une policy
-- `with check (sender = auth.uid())` suffirait à contourner tout le plafond
-- depuis n'importe quel client.
drop policy if exists "waves_insert_own" on public.waves;

-- Les deux plafonds, en un seul endroit pour que le client et le serveur ne
-- puissent pas diverger.
create or replace function public.wave_streak_max() returns int
  language sql immutable as $$ select 3 $$;

create or replace function public.wave_daily_max() returns int
  language sql immutable as $$ select 5 $$;

-- Faire signe à quelqu'un. Renvoie toujours un jsonb, jamais une exception
-- pour un refus : un plafond atteint est un état normal de l'interface, pas
-- une panne. `ok` false + `reason` parmi auth / self / streak / daily.
--
-- `remaining_streak` et `remaining_daily` sont ce qu'il RESTE après ce
-- signe-ci, pour que le bouton se grise sans re-interroger le serveur.
create or replace function public.send_wave(p_recipient uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me       uuid := auth.uid();
  v_answered timestamptz;
  v_streak   int;
  v_daily    int;
  v_id       uuid;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'reason', 'auth');
  end if;
  if p_recipient is null or p_recipient = v_me then
    return jsonb_build_object('ok', false, 'reason', 'self');
  end if;

  -- Le dernier signe de vie DANS L'AUTRE SENS. Trois formes valent réponse ;
  -- on garde la plus récente des trois.
  select greatest(
    coalesce((select max(m.created_at) from public.messages m
               where m.sender = p_recipient and m.recipient = v_me),
             '-infinity'::timestamptz),
    coalesce((select max(w.created_at) from public.waves w
               where w.sender = p_recipient and w.recipient = v_me),
             '-infinity'::timestamptz),
    coalesce((select max(w.seen_at) from public.waves w
               where w.sender = v_me and w.recipient = p_recipient),
             '-infinity'::timestamptz)
  ) into v_answered;

  select count(*) into v_streak
    from public.waves w
   where w.sender = v_me
     and w.recipient = p_recipient
     and w.created_at > v_answered;

  if v_streak >= public.wave_streak_max() then
    return jsonb_build_object(
      'ok', false, 'reason', 'streak',
      'remaining_streak', 0,
      'remaining_daily', greatest(public.wave_daily_max() - (
        select count(*) from public.waves w
         where w.sender = v_me and w.recipient = p_recipient
           and w.created_at > now() - interval '24 hours'), 0)
    );
  end if;

  select count(*) into v_daily
    from public.waves w
   where w.sender = v_me
     and w.recipient = p_recipient
     and w.created_at > now() - interval '24 hours';

  if v_daily >= public.wave_daily_max() then
    return jsonb_build_object(
      'ok', false, 'reason', 'daily',
      'remaining_streak', greatest(public.wave_streak_max() - v_streak, 0),
      'remaining_daily', 0
    );
  end if;

  insert into public.waves (sender, recipient)
       values (v_me, p_recipient)
    returning id into v_id;

  return jsonb_build_object(
    'ok', true,
    'id', v_id,
    'remaining_streak', public.wave_streak_max() - (v_streak + 1),
    'remaining_daily', public.wave_daily_max() - (v_daily + 1)
  );
end;
$$;

revoke all on function public.send_wave(uuid) from public;
grant execute on function public.send_wave(uuid) to authenticated;

-- Combien de signes il me reste vers CHAQUE personne, en une requête. L'écran
-- Messages l'appelle à l'ouverture pour griser les boutons d'entrée de jeu,
-- au lieu de laisser l'utilisateur découvrir le plafond en tapant dessus.
create or replace function public.my_wave_quota()
returns table (peer uuid, remaining_streak int, remaining_daily int)
language sql
security definer
set search_path = public
as $$
  with mine as (
    -- Les 24 h pour le plafond journalier, ET tout signe resté sans réponse
    -- quelle que soit son ancienneté : trois signes ignorés il y a une
    -- semaine bloquent toujours, et le bouton doit le montrer AVANT le clic
    -- plutôt que de laisser le serveur refuser sous le doigt. Borné à trois
    -- lignes par personne, donc la requête ne gonfle pas.
    select distinct recipient as peer
      from public.waves
     where sender = auth.uid()
       and (created_at > now() - interval '24 hours' or seen_at is null)
  ),
  answered as (
    select m.peer,
           greatest(
             coalesce((select max(x.created_at) from public.messages x
                        where x.sender = m.peer and x.recipient = auth.uid()),
                      '-infinity'::timestamptz),
             coalesce((select max(w.created_at) from public.waves w
                        where w.sender = m.peer and w.recipient = auth.uid()),
                      '-infinity'::timestamptz),
             coalesce((select max(w.seen_at) from public.waves w
                        where w.sender = auth.uid() and w.recipient = m.peer),
                      '-infinity'::timestamptz)
           ) as at
      from mine m
  )
  select a.peer,
         greatest(public.wave_streak_max() - (
           select count(*)::int from public.waves w
            where w.sender = auth.uid() and w.recipient = a.peer
              and w.created_at > a.at), 0) as remaining_streak,
         greatest(public.wave_daily_max() - (
           select count(*)::int from public.waves w
            where w.sender = auth.uid() and w.recipient = a.peer
              and w.created_at > now() - interval '24 hours'), 0) as remaining_daily
    from answered a;
$$;

revoke all on function public.my_wave_quota() from public;
grant execute on function public.my_wave_quota() to authenticated;

-- Le destinataire voit le signe arriver sans recharger la liste.
do $$
begin
  alter publication supabase_realtime add table public.waves;
exception
  when duplicate_object then null;
end$$;
