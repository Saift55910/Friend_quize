-- Run this entire file in the Supabase SQL Editor.
create extension if not exists pgcrypto;
create table if not exists public.quizzes (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references auth.users(id) on delete cascade,
 title text not null check (char_length(title) between 1 and 100),
 questions jsonb not null,
 created_at timestamptz not null default now()
);
create table if not exists public.submissions (
 id uuid primary key default gen_random_uuid(),
 quiz_id uuid not null references public.quizzes(id) on delete cascade,
 participant_name text not null check (char_length(participant_name) between 1 and 50),
 answers jsonb not null,
 score integer not null,
 total_questions integer not null,
 created_at timestamptz not null default now()
);
alter table public.quizzes enable row level security;
alter table public.submissions enable row level security;
drop policy if exists "owners manage own quizzes" on public.quizzes;
create policy "owners manage own quizzes" on public.quizzes for all to authenticated
 using (auth.uid()=owner_id) with check (auth.uid()=owner_id);
revoke all on public.submissions from anon, authenticated;
grant select,insert,update,delete on public.quizzes to authenticated;
grant select on public.quizzes to anon;
create or replace function public.get_public_quiz(p_quiz_id text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare q public.quizzes;
begin
 select * into q from public.quizzes where id::text=p_quiz_id;
 if not found then return null; end if;
 return jsonb_build_object('id',q.id,'title',q.title,'questions',
  (select jsonb_agg(jsonb_build_object('text',x->>'text','options',x->'options','multi',coalesce((x->>'multi')::boolean,false)) order by n)
   from jsonb_array_elements(q.questions) with ordinality a(x,n)));
end; $$;
create or replace function public.submit_quiz(p_quiz_id text,p_name text,p_answers jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare q public.quizzes; item jsonb; submitted jsonb; i integer:=0; points integer:=0; total integer; got integer[]; correct integer[];
begin
 select * into q from public.quizzes where id::text=p_quiz_id;
 if not found then raise exception 'Quiz not found'; end if;
 if char_length(trim(p_name)) not between 1 and 50 then raise exception 'Invalid name'; end if;
 if jsonb_typeof(p_answers)<>'array' or jsonb_array_length(p_answers)<>jsonb_array_length(q.questions) then raise exception 'Invalid answers'; end if;
 total:=jsonb_array_length(q.questions);
 for item in select value from jsonb_array_elements(q.questions) loop
  submitted:=p_answers->i;
  if jsonb_typeof(submitted)<>'array' then raise exception 'Invalid answer'; end if;
  select coalesce(array_agg(value::text::integer order by value::text::integer),array[]::integer[]) into got from jsonb_array_elements(submitted);
  select coalesce(array_agg(value::text::integer order by value::text::integer),array[]::integer[]) into correct from jsonb_array_elements(item->'correct_indices');
  if got=correct then points:=points+1; end if;
  i:=i+1;
 end loop;
 insert into public.submissions(quiz_id,participant_name,answers,score,total_questions)
 values(q.id,trim(p_name),p_answers,points,total);
 return jsonb_build_object('saved',true);
end; $$;
create or replace function public.owner_quiz_results(p_quiz_id text)
returns table(participant_name text,score integer,total_questions integer,created_at timestamptz)
language plpgsql security definer set search_path=public as $$
begin
 if not exists(select 1 from public.quizzes where id::text=p_quiz_id and owner_id=auth.uid()) then raise exception 'Not authorized'; end if;
 return query select s.participant_name,s.score,s.total_questions,s.created_at
 from public.submissions s where s.quiz_id::text=p_quiz_id order by s.created_at desc;
end; $$;
revoke all on function public.get_public_quiz(text) from public;
revoke all on function public.submit_quiz(text,text,jsonb) from public;
revoke all on function public.owner_quiz_results(text) from public;
grant execute on function public.get_public_quiz(text) to anon,authenticated;
grant execute on function public.submit_quiz(text,text,jsonb) to anon,authenticated;
grant execute on function public.owner_quiz_results(text) to authenticated;