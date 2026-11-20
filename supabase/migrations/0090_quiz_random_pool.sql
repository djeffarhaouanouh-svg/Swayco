-- 0090_quiz_random_pool.sql
--
-- Chaque thème du quiz a maintenant 20 questions. Un quiz en pose 5, tirées au
-- hasard par le SERVEUR parmi les 20 (jamais deux fois la même dans un quiz).
-- Les 5 numéros tirés sont gardés dans `question_ids` ; la carte du fil porte
-- `quiz|<thème>|<position>|<numéro de question>`.

alter table public.chat_quizzes
  add column if not exists question_ids int[] not null default '{}';

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
  ids int[];
  q public.chat_quizzes;
begin
  if uid is null or position(uid::text in p_conv) = 0 then
    raise exception 'not a participant';
  end if;
  if not (th = any (themes)) then
    th := themes[1 + floor(random() * array_length(themes, 1))::int];
  end if;
  -- 5 questions distinctes parmi les 20 du thème.
  select array_agg(i) into ids
  from (select i from generate_series(1, 20) as i order by random() limit 5) s;
  insert into public.chat_quizzes
    (conversation_id, theme, q_index, total, status, started_by, stopped_by,
     updated_at, question_ids)
  values (p_conv, th, 1, 5, 'active', uid, null, now(), ids)
  on conflict (conversation_id) do update
    set theme = excluded.theme, q_index = 1, total = 5, status = 'active',
        started_by = uid, stopped_by = null, updated_at = now(),
        question_ids = excluded.question_ids
  returning * into q;
  perform public._quiz_post(
    p_conv, p_to, p_name, 'quiz|' || th || '|1|' || ids[1]
  );
  return q;
end;
$$;

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
      p_conv, p_to, p_name,
      'quiz|' || q.theme || '|' || q.q_index || '|'
        || coalesce(q.question_ids[q.q_index], q.q_index)
    );
  end if;
  return q;
end;
$$;

grant execute on function public.quiz_start(text, text, uuid, text) to authenticated;
grant execute on function public.quiz_next(text, int, uuid, text) to authenticated;
