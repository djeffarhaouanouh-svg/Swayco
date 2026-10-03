-- Messages speciaux (Discover, bouton dore) : 3 par mois et par compte.
-- Compteur cote serveur, remis a zero chaque mois (UTC). Les fonctions lisent
-- auth.uid() : on ne peut ni lire ni entamer le quota de quelqu'un d'autre.

create table if not exists public.special_message_usage (
  user_id uuid not null references auth.users(id) on delete cascade,
  month   date not null,
  used    int  not null default 0,
  primary key (user_id, month)
);

alter table public.special_message_usage enable row level security;
-- Aucune policy : la table n'est accessible que par les fonctions ci-dessous.

-- Combien il en reste ce mois-ci (3 -> 0).
create or replace function public.special_messages_remaining()
returns int
language sql
security definer
set search_path = public
stable
as $$
  select greatest(
    3 - coalesce((
      select used from public.special_message_usage
      where user_id = auth.uid()
        and month = date_trunc('month', now() at time zone 'utc')::date
    ), 0),
    0
  );
$$;

-- En consomme un et rend ce qu'il reste. Leve 'no_special_left' a 0.
create or replace function public.consume_special_message()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_month date := date_trunc('month', now() at time zone 'utc')::date;
  v_used int;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  insert into public.special_message_usage (user_id, month, used)
  values (v_uid, v_month, 0)
  on conflict (user_id, month) do nothing;

  update public.special_message_usage
     set used = used + 1
   where user_id = v_uid and month = v_month and used < 3
  returning used into v_used;

  if v_used is null then
    raise exception 'no_special_left';
  end if;
  return 3 - v_used;
end;
$$;

revoke all on function public.special_messages_remaining() from public;
revoke all on function public.consume_special_message() from public;
grant execute on function public.special_messages_remaining() to authenticated;
grant execute on function public.consume_special_message() to authenticated;
