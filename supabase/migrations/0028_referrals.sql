-- 0028_referrals.sql
--
-- "Invite 3 amis = +30 min de crédits" — referral wiring.
--
-- A new column `referral_code` lets every user share a personal link
-- (https://swayco.fr/?ref=<code>) that, when followed by someone who
-- creates an account, is attributed back via `attribute_referral`. The
-- RPC sets `referred_by` on the new user (idempotent — refuses to
-- overwrite an existing link, and refuses self-referrals), then walks
-- the referrer's pending-bonus count forward in tranches of 3: every
-- third filleul grants +1800 s (30 min) of translation credits.
--
-- `referral_credits_granted` stores how many filleuls have already been
-- folded into a bonus payout — so re-running the RPC for the same user
-- can never double-credit, and the bonus stays honest even if a
-- duplicate webhook / retry fires twice.

-- ─── columns ──────────────────────────────────────────────────────────────
alter table public.profiles
  add column if not exists referral_code text;

alter table public.profiles
  add column if not exists referred_by uuid references public.profiles(id) on delete set null;

alter table public.profiles
  add column if not exists referral_credits_granted int not null default 0;

-- Backfill existing rows with a short, URL-friendly code. 8 hex chars
-- of a v4 uuid gives 2^32 codes — plenty for a single project.
update public.profiles
   set referral_code = substr(replace(gen_random_uuid()::text, '-', ''), 1, 8)
 where referral_code is null;

alter table public.profiles
  alter column referral_code set not null;

do $$
begin
  alter table public.profiles
    add constraint profiles_referral_code_unique unique (referral_code);
exception when duplicate_object then null;
end$$;

create index if not exists profiles_referred_by_idx
  on public.profiles (referred_by);

-- ─── auto-assign referral_code on insert ─────────────────────────────────
create or replace function public.set_referral_code()
returns trigger
language plpgsql
as $$
begin
  if new.referral_code is null or length(new.referral_code) = 0 then
    new.referral_code := substr(replace(gen_random_uuid()::text, '-', ''), 1, 8);
  end if;
  return new;
end$$;

drop trigger if exists profiles_set_referral_code on public.profiles;
create trigger profiles_set_referral_code
  before insert on public.profiles
  for each row execute function public.set_referral_code();

-- ─── attribute_referral RPC ──────────────────────────────────────────────
-- Called by the freshly-signed-up user after they enter the app for
-- the first time with a pending ?ref=<code> from the deep link they
-- followed. Wires the relationship + grants the bonus to the referrer
-- in a single atomic step.
create or replace function public.attribute_referral(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_referrer_id uuid;
  v_existing_ref uuid;
  v_count int;
  v_granted int;
  v_bonus_added int := 0;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;
  if p_code is null or length(trim(p_code)) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'empty_code');
  end if;

  select id into v_referrer_id
    from public.profiles
   where referral_code = trim(p_code)
   limit 1;
  if v_referrer_id is null then
    return jsonb_build_object('ok', false, 'reason', 'unknown_code');
  end if;
  if v_referrer_id = v_uid then
    return jsonb_build_object('ok', false, 'reason', 'self_referral');
  end if;

  select referred_by into v_existing_ref
    from public.profiles where id = v_uid;
  if v_existing_ref is not null then
    return jsonb_build_object('ok', false, 'reason', 'already_referred');
  end if;

  update public.profiles set referred_by = v_referrer_id where id = v_uid;

  -- Count how many people the referrer has now signed up, and pay out
  -- in tranches of 3. The loop handles the (rare) case where multiple
  -- filleuls landed between two payout windows.
  select count(*) into v_count
    from public.profiles where referred_by = v_referrer_id;
  select referral_credits_granted into v_granted
    from public.profiles where id = v_referrer_id;

  while v_count >= v_granted + 3 loop
    v_granted := v_granted + 3;
    v_bonus_added := v_bonus_added + 1800;
  end loop;

  if v_bonus_added > 0 then
    update public.profiles
       set credits_seconds = coalesce(credits_seconds, 0) + v_bonus_added,
           referral_credits_granted = v_granted
     where id = v_referrer_id;
  end if;

  return jsonb_build_object(
    'ok', true,
    'referrer', v_referrer_id,
    'referrals_total', v_count,
    'bonus_added_seconds', v_bonus_added
  );
end$$;

revoke all on function public.attribute_referral(text) from public;
grant execute on function public.attribute_referral(text) to authenticated;
