-- Friend Quiz: Supabase database schema
-- Run this entire file once in Supabase > SQL Editor.
-- Safe for the public browser client: correct answers are returned only by server-side scoring.

create extension if not exists pgcrypto;

create table if not exists public.quizzes (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  title text not null check (char_length(trim(title)) between 1 and 120),
  questions jsonb not null check (
    jsonb_typeof(questions) = 'array'
    and jsonb_array_length(questions) between 1 and 50
  ),
  created_at timestamptz not null default now()
);

create table if not exists public.submissions (
  id uuid primary key default gen_random_uuid(),
  quiz_id uuid not null references public.quizzes(id) on delete cascade,
  participant_name text not null check (char_length(trim(participant_name)) between 1 and 50),
  answers jsonb not null check (jsonb_typeof(answers) = 'array'),
  score integer not null check (score >= 0),
  total_questions integer not null check (total_questions > 0 and score <= total_questions),
  created_at timestamptz not null default now()
);

create index if not exists quizzes_owner_created_idx
  on public.quizzes(owner_id, created_at desc);
create index if not exists submissions_quiz_created_idx
  on public.submissions(quiz_id, created_at desc);

alter table public.quizzes enable row level security;
alter table public.submissions enable row level security;

-- Owners can see their own quiz records. Public visitors use get_public_quiz().
drop policy if exists "Owners can read their quizzes" on public.quizzes;
create policy "Owners can read their quizzes"
  on public.quizzes for select
  to authenticated
  using (owner_id = (select auth.uid()));

-- Owners can create quizzes only for themselves.
drop policy if exists "Owners can create their quizzes" on public.quizzes;
create policy "Owners can create their quizzes"
  on public.quizzes for insert
  to authenticated
  with check (owner_id = (select auth.uid()));

-- No direct client policies are created for submissions.
-- All submissions and result reads go through the checked RPC functions.

create or replace function public.get_public_quiz(p_quiz_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'id', q.id,
    'title', q.title,
    'questions', (
      select coalesce(
        jsonb_agg(
          jsonb_build_object(
            'text', item.value -> 'text',
            'options', item.value -> 'options',
            'multi', coalesce((item.value ->> 'multi')::boolean, false)
          )
          order by item.ordinality
        ),
        '[]'::jsonb
      )
      from jsonb_array_elements(q.questions) with ordinality as item(value, ordinality)
    )
  )
  from public.quizzes q
  where q.id = p_quiz_id;
$$;

create or replace function public.submit_quiz(
  p_quiz_id uuid,
  p_name text,
  p_answers jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_questions jsonb;
  v_question jsonb;
  v_options jsonb;
  v_correct jsonb;
  v_answer jsonb;
  v_correct_arr integer[];
  v_answer_arr integer[];
  v_score integer := 0;
  v_total integer;
  v_i integer;
  v_n integer;
  v_value integer;
begin
  if p_name is null or char_length(trim(p_name)) not between 1 and 50 then
    raise exception 'Name must be between 1 and 50 characters';
  end if;

  if p_answers is null or jsonb_typeof(p_answers) <> 'array' then
    raise exception 'Answers must be an array';
  end if;

  select q.questions into v_questions
  from public.quizzes q
  where q.id = p_quiz_id;

  if v_questions is null then
    raise exception 'Quiz not found';
  end if;

  v_total := jsonb_array_length(v_questions);
  if jsonb_array_length(p_answers) <> v_total then
    raise exception 'Answer count does not match quiz';
  end if;

  for v_i in 0..(v_total - 1) loop
    v_question := v_questions -> v_i;
    v_options := v_question -> 'options';
    v_correct := v_question -> 'correct_indices';
    v_answer := p_answers -> v_i;

    if jsonb_typeof(v_options) <> 'array'
       or jsonb_array_length(v_options) < 2
       or jsonb_typeof(v_correct) <> 'array'
       or jsonb_array_length(v_correct) < 1
       or jsonb_typeof(v_answer) <> 'array' then
      raise exception 'Invalid quiz question or answer format';
    end if;

    select array_agg(x::integer order by x::integer)
      into v_correct_arr
    from jsonb_array_elements_text(v_correct) as t(x);

    select array_agg(x::integer order by x::integer)
      into v_answer_arr
    from jsonb_array_elements_text(v_answer) as t(x);

    if v_answer_arr is null or cardinality(v_answer_arr) = 0 then
      raise exception 'Every question must be answered';
    end if;

    -- Reject duplicate choices and indices outside the available options.
    if cardinality(v_answer_arr) <> (
      select count(distinct x) from unnest(v_answer_arr) as a(x)
    ) then
      raise exception 'Duplicate answer choice';
    end if;

    foreach v_value in array v_answer_arr loop
      if v_value < 0 or v_value >= jsonb_array_length(v_options) then
        raise exception 'Answer choice is out of range';
      end if;
    end loop;

    foreach v_value in array v_correct_arr loop
      if v_value < 0 or v_value >= jsonb_array_length(v_options) then
        raise exception 'Quiz contains an invalid correct answer';
      end if;
    end loop;

    if coalesce((v_question ->> 'multi')::boolean, false) = false
       and cardinality(v_answer_arr) <> 1 then
      raise exception 'Only one choice is allowed for this question';
    end if;

    if v_answer_arr = v_correct_arr then
      v_score := v_score + 1;
    end if;
  end loop;

  insert into public.submissions (
    quiz_id, participant_name, answers, score, total_questions
  ) values (
    p_quiz_id, trim(p_name), p_answers, v_score, v_total
  );

  return jsonb_build_object(
    'submitted', true,
    'score', v_score,
    'total_questions', v_total
  );
end;
$$;

create or replace function public.owner_quiz_results(p_quiz_id uuid)
returns table (
  participant_name text,
  score integer,
  total_questions integer,
  created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null then
    raise exception 'Sign in required';
  end if;

  if not exists (
    select 1
    from public.quizzes q
    where q.id = p_quiz_id
      and q.owner_id = auth.uid()
  ) then
    raise exception 'Not authorized to view these results';
  end if;

  return query
  select s.participant_name, s.score, s.total_questions, s.created_at
  from public.submissions s
  where s.quiz_id = p_quiz_id
  order by s.created_at desc;
end;
$$;

-- Remove default PUBLIC execution, then grant only the intended RPC access.
revoke all on function public.get_public_quiz(uuid) from public;
revoke all on function public.submit_quiz(uuid, text, jsonb) from public;
revoke all on function public.owner_quiz_results(uuid) from public;

grant execute on function public.get_public_quiz(uuid) to anon, authenticated;
grant execute on function public.submit_quiz(uuid, text, jsonb) to anon, authenticated;
grant execute on function public.owner_quiz_results(uuid) to authenticated;

-- Table access used by the existing app.js owner dashboard.
grant select, insert on public.quizzes to authenticated;
grant usage, select on all sequences in schema public to authenticated;
