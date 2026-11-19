-- 0086_groups_quiz_official.sql
--
-- Trois chantiers du dossier implementation_messages_groupes_quiz_v1 :
--   A. groupes de discussion (chat_groups + chat_group_members)
--   B. compte officiel Swayco, en lecture seule (official_posts)
--   C. quiz dans le chat (chat_quizzes + fonctions quiz_start / next / stop)
--
-- Idempotent : sur à rejouer.

-- Un message de GROUPE n'a pas de destinataire unique : `recipient` doit
-- pouvoir rester vide. (Sans effet si la colonne l'accepte déjà.)
alter table public.messages alter column recipient drop not null;

-- ─────────────────────────────────────────────────────────────────────────────
-- A. Groupes
-- ─────────────────────────────────────────────────────────────────────────────

create table if not exists public.chat_groups (
  id          uuid        primary key default gen_random_uuid(),
  name        text        not null check (char_length(name) between 1 and 60),
  created_by  uuid        not null,
  created_at  timestamptz not null default now()
);

create table if not exists public.chat_group_members (
  group_id   uuid        not null references public.chat_groups(id) on delete cascade,
  user_id    uuid        not null,
  role       text        not null default 'member'
             check (role in ('admin', 'member')),
  muted      boolean     not null default false,
  joined_at  timestamptz not null default now(),
  primary key (group_id, user_id)
);

create index if not exists chat_group_members_user_idx
  on public.chat_group_members (user_id);

-- Vrai si l'appelant est membre du groupe. SECURITY DEFINER pour que la
-- politique de lecture de la table des membres ne se rappelle pas elle-même.
create or replace function public.is_group_member(gid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.chat_group_members
    where group_id = gid and user_id = auth.uid()
  );
$$;

alter table public.chat_groups enable row level security;
alter table public.chat_group_members enable row level security;

drop policy if exists "chat_groups_select_member" on public.chat_groups;
create policy "chat_groups_select_member"
  on public.chat_groups for select
  using (public.is_group_member(id));

drop policy if exists "chat_group_members_select_member" on public.chat_group_members;
create policy "chat_group_members_select_member"
  on public.chat_group_members for select
  using (public.is_group_member(group_id));

-- Toute écriture passe par les fonctions ci-dessous (aucune politique
-- insert / update / delete : un client ne peut pas se nommer admin).

create or replace function public.create_group(p_name text, p_members uuid[])
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  gid uuid;
  uid uuid := auth.uid();
  m uuid;
begin
  if uid is null then raise exception 'not authenticated'; end if;
  if p_name is null or char_length(btrim(p_name)) = 0 then
    raise exception 'name required';
  end if;
  insert into public.chat_groups (name, created_by)
  values (left(btrim(p_name), 60), uid)
  returning id into gid;
  insert into public.chat_group_members (group_id, user_id, role)
  values (gid, uid, 'admin');
  foreach m in array coalesce(p_members, '{}'::uuid[]) loop
    if m is not null and m <> uid then
      insert into public.chat_group_members (group_id, user_id)
      values (gid, m)
      on conflict do nothing;
    end if;
  end loop;
  return gid;
end;
$$;

create or replace function public.group_add_members(p_group uuid, p_members uuid[])
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  m uuid;
begin
  if not public.is_group_member(p_group) then
    raise exception 'not a member';
  end if;
  foreach m in array coalesce(p_members, '{}'::uuid[]) loop
    if m is not null then
      insert into public.chat_group_members (group_id, user_id)
      values (p_group, m)
      on conflict do nothing;
    end if;
  end loop;
end;
$$;

-- Vrai si l'appelant est ADMIN du groupe.
create or replace function public._is_group_admin(gid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.chat_group_members
    where group_id = gid and user_id = auth.uid() and role = 'admin'
  );
$$;

create or replace function public.group_remove_member(p_group uuid, p_user uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public._is_group_admin(p_group) then
    raise exception 'admin only';
  end if;
  if p_user = auth.uid() then
    raise exception 'use group_leave';
  end if;
  delete from public.chat_group_members
  where group_id = p_group and user_id = p_user;
end;
$$;

create or replace function public.group_set_admin(p_group uuid, p_user uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public._is_group_admin(p_group) then
    raise exception 'admin only';
  end if;
  update public.chat_group_members
  set role = 'admin'
  where group_id = p_group and user_id = p_user;
end;
$$;

create or replace function public.group_leave(p_group uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
begin
  delete from public.chat_group_members
  where group_id = p_group and user_id = uid;
  -- Plus personne : le groupe disparaît.
  if not exists (
    select 1 from public.chat_group_members where group_id = p_group
  ) then
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
        order by joined_at asc
        limit 1
      );
  end if;
end;
$$;

create or replace function public.group_set_muted(p_group uuid, p_muted boolean)
returns void
language sql
security definer
set search_path = public
as $$
  update public.chat_group_members
  set muted = p_muted
  where group_id = p_group and user_id = auth.uid();
$$;

grant execute on function public.create_group(text, uuid[]) to authenticated;
grant execute on function public.group_add_members(uuid, uuid[]) to authenticated;
grant execute on function public.group_remove_member(uuid, uuid) to authenticated;
grant execute on function public.group_set_admin(uuid, uuid) to authenticated;
grant execute on function public.group_leave(uuid) to authenticated;
grant execute on function public.group_set_muted(uuid, boolean) to authenticated;

-- Les changements de membres arrivent en direct (infos du groupe, liste).
do $$
begin
  alter publication supabase_realtime add table public.chat_group_members;
exception when duplicate_object then null;
end$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B. Compte officiel Swayco (lecture seule)
-- ─────────────────────────────────────────────────────────────────────────────
-- Les messages de l'équipe s'insèrent depuis le back-office (clé service,
-- admin/scripts/post_official.mjs). Aucune politique d'écriture : l'app ne
-- peut que lire.

create table if not exists public.official_posts (
  id          uuid        primary key default gen_random_uuid(),
  title       text        not null default '',
  body        text        not null,
  created_at  timestamptz not null default now()
);

alter table public.official_posts enable row level security;

drop policy if exists "official_posts_read" on public.official_posts;
create policy "official_posts_read"
  on public.official_posts for select
  using (true);

-- ─────────────────────────────────────────────────────────────────────────────
-- C. Quiz dans le chat
-- ─────────────────────────────────────────────────────────────────────────────
-- L'état du quiz d'une conversation. Le SERVEUR avance l'index (quiz_next) :
-- le client ne choisit jamais la question suivante. Les cartes du fil sont des
-- messages ordinaires dont le corps est `quiz|<thème>|<n>` ; le texte de la
-- question est dans l'app, dans la langue de chacun.

create table if not exists public.chat_quizzes (
  conversation_id  text        primary key,
  theme            text        not null,
  q_index          int         not null default 1,
  total            int         not null default 5,
  status           text        not null default 'active'
                   check (status in ('active', 'stopped', 'done')),
  started_by       uuid        not null,
  stopped_by       uuid,
  updated_at       timestamptz not null default now()
);

alter table public.chat_quizzes enable row level security;

-- Les deux participants d'un fil `dm-<uuid>-<uuid>` le lisent.
drop policy if exists "chat_quizzes_select_participant" on public.chat_quizzes;
create policy "chat_quizzes_select_participant"
  on public.chat_quizzes for select
  using (position(auth.uid()::text in conversation_id) > 0);

do $$
begin
  alter publication supabase_realtime add table public.chat_quizzes;
exception when duplicate_object then null;
end$$;

create or replace function public._quiz_post(
  p_conv text, p_to uuid, p_name text, p_body text
) returns void
language sql
security definer
set search_path = public
as $$
  insert into public.messages
    (conversation_id, sender, recipient, sender_name, body, language)
  values
    (p_conv, auth.uid(), p_to, coalesce(p_name, ''), p_body, '');
$$;

create or replace function public.quiz_start(
  p_conv text, p_theme text, p_to uuid, p_name text
) returns public.chat_quizzes
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  themes text[] := array['food', 'travel', 'language', 'culture', 'fun', 'personal'];
  th text := lower(coalesce(p_theme, ''));
  q public.chat_quizzes;
begin
  if uid is null or position(uid::text in p_conv) = 0 then
    raise exception 'not a participant';
  end if;
  if not (th = any (themes)) then
    th := themes[1 + floor(random() * array_length(themes, 1))::int];
  end if;
  insert into public.chat_quizzes
    (conversation_id, theme, q_index, total, status, started_by, stopped_by, updated_at)
  values (p_conv, th, 1, 5, 'active', uid, null, now())
  on conflict (conversation_id) do update
    set theme = excluded.theme, q_index = 1, total = 5, status = 'active',
        started_by = uid, stopped_by = null, updated_at = now()
  returning * into q;
  perform public._quiz_post(p_conv, p_to, p_name, 'quiz|' || th || '|1');
  return q;
end;
$$;

-- Passe à la question suivante. [p_from] est la question que l'appelant vient
-- de voir : si l'autre a déjà avancé, on ne saute pas une question de plus.
create or replace function public.quiz_next(
  p_conv text, p_from int, p_to uuid, p_name text
) returns public.chat_quizzes
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  q public.chat_quizzes;
begin
  if uid is null or position(uid::text in p_conv) = 0 then
    raise exception 'not a participant';
  end if;
  select * into q from public.chat_quizzes
  where conversation_id = p_conv for update;
  if not found or q.status <> 'active' or q.q_index <> p_from then
    return q;
  end if;
  if q.q_index >= q.total then
    update public.chat_quizzes
    set status = 'done', updated_at = now()
    where conversation_id = p_conv
    returning * into q;
    perform public._quiz_post(p_conv, p_to, p_name, 'quiz_done');
  else
    update public.chat_quizzes
    set q_index = q_index + 1, updated_at = now()
    where conversation_id = p_conv
    returning * into q;
    perform public._quiz_post(
      p_conv, p_to, p_name, 'quiz|' || q.theme || '|' || q.q_index
    );
  end if;
  return q;
end;
$$;

create or replace function public.quiz_stop(
  p_conv text, p_to uuid, p_name text
) returns public.chat_quizzes
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  q public.chat_quizzes;
begin
  if uid is null or position(uid::text in p_conv) = 0 then
    raise exception 'not a participant';
  end if;
  update public.chat_quizzes
  set status = 'stopped', stopped_by = uid, updated_at = now()
  where conversation_id = p_conv and status = 'active'
  returning * into q;
  if found then
    perform public._quiz_post(p_conv, p_to, p_name, 'quiz_stop|' || uid::text);
  else
    select * into q from public.chat_quizzes where conversation_id = p_conv;
  end if;
  return q;
end;
$$;

grant execute on function public.quiz_start(text, text, uuid, text) to authenticated;
grant execute on function public.quiz_next(text, int, uuid, text) to authenticated;
grant execute on function public.quiz_stop(text, uuid, text) to authenticated;
