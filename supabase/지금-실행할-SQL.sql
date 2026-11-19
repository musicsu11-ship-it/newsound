-- ============================================================================
--  새소리단 — 지금 실행할 SQL
--
--  ▷ 이번에는 46·47·48·49절입니다.
--
--     46절 — 한 번에 20줄 넘게 지우려 하면 데이터베이스가 거부합니다
--     47절 — 관리자 콘솔 '💾 백업' 단추가 쓰는 함수
--     48절 — ★ 투표 기록장 — 표가 지워져도 되살릴 수 있게 한 벌 더 쌓아 둡니다
--     49절 — ★ 'truncate'(통째로 비우기) 차단 — 46절이 못 보던 구멍입니다
--
--  ★ 이 파일에는 '지우는 문장'이 하나도 없습니다.
--     delete · truncate · drop table 이 한 줄도 들어 있지 않습니다. 확인했습니다.
--     46·47절을 이미 실행하셨어도 괜찮습니다. 몇 번 실행해도 결과가 같게
--     만들었으니, 아래 내용을 그냥 전체 붙여넣고 한 번 실행하시면 됩니다.
--
--  ▷ 하는 방법
--     ① Supabase → 왼쪽 메뉴 'SQL Editor' → 'New query'
--     ② 이 파일 전체를 복사해서 붙여넣기 (Ctrl+A → Ctrl+C → 붙여넣기)
--     ③ 오른쪽 아래 'Run' 단추 (또는 Ctrl+Enter)
--     ④ 'Success. No rows returned' 가 나오면 다 된 것입니다
--
--  ▷ 잘 됐는지 확인하는 방법
--     관리자 콘솔 → 💾 백업 메뉴를 새로 열어 보세요.
--     '투표 기록장' 칸에 보관 건수가 나오면 48절이 살아 있는 것입니다.
--     그 뒤에 밸런스게임에서 아무 표나 한 번 던져 보시고 다시 열어 보시면,
--     보관 건수가 1 늘어난 것을 보실 수 있습니다.
--
--  ▷ 이 파일은 supabase/schema.sql 의 46~49절과 같은 내용입니다.
--     (schema.sql 은 처음부터 전부 담은 '설계도 원본'입니다)
-- ============================================================================

-- ============================================================================
--  46. ★ 안전장치 — 한 번에 많은 줄이 지워지지 않게 막습니다
-- ============================================================================
--  2026-11-19, 투표 표와 응모 명단이 delete 한 줄에 통째로 사라진 일이
--  있었습니다. 같은 일이 다시 일어나지 않도록, 중요한 표에서는
--  '한 번에 20줄 넘게 지우기'를 데이터베이스가 직접 거부하게 만듭니다.
--
--  정말 많이 지워야 할 때만, 같은 창에서 먼저 이 한 줄을 실행하세요.
--      set local app.bulk_delete_ok = 'yes';
--  그 창에서만, 그 번만 풀립니다.

-- (가) 보통 표 — 한 번에 20줄 넘게 지우면 막습니다
create or replace function public.guard_mass_delete()
returns trigger language plpgsql as $$
declare n int;
begin
  if coalesce(current_setting('app.bulk_delete_ok', true), '') = 'yes' then
    return null;
  end if;
  select count(*) into n from deleted;
  if n > 20 then
    raise exception '안전장치가 막았습니다 — "%" 에서 한 번에 %건을 지우려 했습니다. 정말 지우시려면 같은 창에서 먼저  set local app.bulk_delete_ok = ''yes'';  를 실행하세요.', tg_table_name, n;
  end if;
  return null;
end $$;

-- (나) 투표에 딸린 표 — 투표 자체를 지워서 함께 지워지는 것은 정상입니다.
--     투표는 그대로 둔 채 표만 무더기로 지우는 경우만 막습니다.
--     (2026-11-19 사고가 바로 이 경우였습니다)
create or replace function public.guard_poll_child_delete()
returns trigger language plpgsql as $$
declare n int; alive int;
begin
  if coalesce(current_setting('app.bulk_delete_ok', true), '') = 'yes' then
    return null;
  end if;
  select count(*) into n from deleted;
  if n <= 20 then
    return null;
  end if;
  select count(*) into alive
    from deleted d where exists (select 1 from public.polls p where p.id = d.poll_id);
  if alive = 0 then
    return null;
  end if;
  raise exception '안전장치가 막았습니다 — 투표는 그대로 둔 채 "%" 에서 %건을 지우려 했습니다. 정말 지우시려면 같은 창에서 먼저  set local app.bulk_delete_ok = ''yes'';  를 실행하세요.', tg_table_name, n;
end $$;

do $$
declare t text;
begin
  foreach t in array array['polls','posts','opinions','profiles','events','reports','expenses']
  loop
    execute format('drop trigger if exists guard_mass_delete on public.%I', t);
    execute format($f$create trigger guard_mass_delete after delete on public.%I
      referencing old table as deleted for each statement
      execute function public.guard_mass_delete()$f$, t);
  end loop;

  foreach t in array array['poll_ballots','poll_entries']
  loop
    execute format('drop trigger if exists guard_mass_delete on public.%I', t);
    execute format($f$create trigger guard_mass_delete after delete on public.%I
      referencing old table as deleted for each statement
      execute function public.guard_poll_child_delete()$f$, t);
  end loop;
end $$;

-- ============================================================================
--  47. 백업 — 관리자 콘솔에서 전체 자료를 한 번에 내려받습니다
-- ============================================================================
--  관리자 콘솔 '💾 백업' 메뉴의 단추가 이 함수를 부릅니다.
--  혁신행정담당관 · 운영 관리자만 부를 수 있습니다.

create or replace function public.backup_dump()
returns jsonb language plpgsql security definer set search_path = public as $$
declare r text; result jsonb;
begin
  select p.role into r from public.profiles p where p.id = auth.uid();
  if r is null or r not in ('officer','admin') then
    raise exception '백업은 혁신행정담당관 또는 운영 관리자만 내려받을 수 있습니다.';
  end if;

  select jsonb_build_object(
    'taken_at',         now(),
    'taken_by',         coalesce((select name from public.profiles where id = auth.uid()), ''),
    'polls',            (select coalesce(jsonb_agg(to_jsonb(t)),'[]'::jsonb) from public.polls t),
    'poll_ballots',     (select coalesce(jsonb_agg(to_jsonb(t)),'[]'::jsonb) from public.poll_ballots t),
    'poll_entries',     (select coalesce(jsonb_agg(to_jsonb(t)),'[]'::jsonb) from public.poll_entries t),
    'vote_journal',     (select coalesce(jsonb_agg(to_jsonb(t)),'[]'::jsonb) from public.vote_journal t),
    'posts',            (select coalesce(jsonb_agg(to_jsonb(t)),'[]'::jsonb) from public.posts t),
    'post_comments',    (select coalesce(jsonb_agg(to_jsonb(t)),'[]'::jsonb) from public.post_comments t),
    'post_likes',       (select coalesce(jsonb_agg(to_jsonb(t)),'[]'::jsonb) from public.post_likes t),
    'post_joins',       (select coalesce(jsonb_agg(to_jsonb(t)),'[]'::jsonb) from public.post_joins t),
    'opinions',         (select coalesce(jsonb_agg(to_jsonb(t)),'[]'::jsonb) from public.opinions t),
    'opinion_comments', (select coalesce(jsonb_agg(to_jsonb(t)),'[]'::jsonb) from public.opinion_comments t),
    'opinion_likes',    (select coalesce(jsonb_agg(to_jsonb(t)),'[]'::jsonb) from public.opinion_likes t),
    'comment_likes',    (select coalesce(jsonb_agg(to_jsonb(t)),'[]'::jsonb) from public.comment_likes t),
    'profiles',         (select coalesce(jsonb_agg(to_jsonb(t)),'[]'::jsonb) from public.profiles t),
    'events',           (select coalesce(jsonb_agg(to_jsonb(t)),'[]'::jsonb) from public.events t),
    'reports',          (select coalesce(jsonb_agg(to_jsonb(t)),'[]'::jsonb) from public.reports t),
    'expenses',         (select coalesce(jsonb_agg(to_jsonb(t)),'[]'::jsonb) from public.expenses t),
    'site',             (select coalesce(jsonb_agg(to_jsonb(t)),'[]'::jsonb) from public.site t),
    'visit_daily',      (select coalesce(jsonb_agg(to_jsonb(t)),'[]'::jsonb) from public.visit_daily t)
  ) into result;

  return result;
end $$;

revoke execute on function public.backup_dump() from anon;
grant  execute on function public.backup_dump() to authenticated;

-- ============================================================================
--  48. ★ 투표 기록장 — 표가 지워져도 되살릴 수 있게
-- ============================================================================
--  46절 안전장치는 '지우는 것'을 막습니다. 그런데 막는 담장은 넘을 수 있습니다.
--  (표를 통째로 비우거나 truncate, 안전장치를 떼어내고 지우거나, 표를 drop 하는 경우)
--
--  그래서 담장 하나에 기대지 않고, '표가 던져진 기록'을 따로 한 벌 더 쌓아 둡니다.
--    · 어느 표와도 연결하지 않습니다  → 무엇이 지워져도 함께 지워지지 않습니다
--    · 넣기만 되고 지우기는 아예 막습니다 → 쌓인 기록은 사라지지 않습니다
--    · 사이트·관리자 콘솔에서는 보이지 않습니다 (연락처가 들어 있으므로 완전 차단)
--    · 되살리기는 혁신행정담당관·관리자만, 함수로만 할 수 있습니다
--
--  즉 46절이 뚫려도 48절이 받칩니다. 2026-11-19 사고가 지금 일어나면
--  restore_votes() 한 번으로 표가 되돌아옵니다.

create table if not exists public.vote_journal (
  id      bigserial   primary key,
  at      timestamptz not null default now(),
  kind    text        not null,   -- 'ballot' 투표 표 | 'entry' 이벤트 응모
  op      text        not null,   -- 'I' 넣음 | 'U' 고침 | 'D' 지워짐
  poll_id uuid        not null,   -- ★ 일부러 references 를 걸지 않습니다
  user_id uuid        not null,   -- ★ 계정이 지워져도 기록은 남습니다
  payload jsonb       not null    -- 그 순간의 줄 전체
);

create index if not exists vote_journal_key_idx
  on public.vote_journal (kind, poll_id, user_id, at desc);

-- 사이트에서는 아예 손댈 수 없게 합니다 (정책을 하나도 만들지 않습니다)
alter table public.vote_journal enable row level security;
revoke all on public.vote_journal from anon, authenticated;

-- (가) 표가 들어오고·고쳐지고·지워질 때마다 기록장에 한 줄 남깁니다
create or replace function public.vote_journal_write()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'DELETE' then
    insert into public.vote_journal(kind, op, poll_id, user_id, payload)
    values (tg_argv[0], 'D', old.poll_id, old.user_id, to_jsonb(old));
  else
    insert into public.vote_journal(kind, op, poll_id, user_id, payload)
    values (tg_argv[0],
            case tg_op when 'INSERT' then 'I' else 'U' end,
            new.poll_id, new.user_id, to_jsonb(new));
  end if;
  return null;
end $$;

drop trigger if exists vote_journal_ballot on public.poll_ballots;
create trigger vote_journal_ballot
  after insert or update or delete on public.poll_ballots
  for each row execute function public.vote_journal_write('ballot');

drop trigger if exists vote_journal_entry on public.poll_entries;
create trigger vote_journal_entry
  after insert or update or delete on public.poll_entries
  for each row execute function public.vote_journal_write('entry');

-- (나) 기록장은 '넣기 전용' — 지우려 하면 몇 줄이든 막습니다
create or replace function public.guard_append_only()
returns trigger language plpgsql as $$
begin
  if coalesce(current_setting('app.bulk_delete_ok', true), '') = 'yes' then
    return null;
  end if;
  raise exception '안전장치가 막았습니다 — "%" 는 기록장이라 지울 수 없습니다. 꼭 지워야 하면 같은 창에서 먼저  set local app.bulk_delete_ok = ''yes'';  를 실행하세요.', tg_table_name;
end $$;

drop trigger if exists guard_append_only on public.vote_journal;
create trigger guard_append_only before delete on public.vote_journal
  for each statement execute function public.guard_append_only();

-- (다) 되살리기 — 기록장을 읽어, 지금 없는 표만 다시 채웁니다
--      규칙은 하나입니다 — '지워지기 직전의 마지막 내용'으로 돌려놓습니다.
--      사이트는 표를 고치기만 하고 지우지는 않으므로,
--      기록장의 'D'(지워짐)은 사고 아니면 생기지 않습니다.
--      as_of 를 주면 그 시각까지의 내용만 씁니다.
--      이미 있는 표는 건드리지 않습니다 → 몇 번 눌러도 안전합니다
create or replace function public.restore_votes(as_of timestamptz default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r text; t timestamptz; nb int; ne int;
begin
  select p.role into r from public.profiles p where p.id = auth.uid();
  if r is null or r not in ('officer','admin') then
    raise exception '표 되살리기는 혁신행정담당관 또는 운영 관리자만 할 수 있습니다.';
  end if;
  t := coalesce(as_of, now());

  with last as (
    select distinct on (poll_id, user_id) poll_id, user_id, payload
      from public.vote_journal
     where kind = 'ballot' and at <= t and op <> 'D'
     order by poll_id, user_id, at desc, id desc
  )
  insert into public.poll_ballots
  select (jsonb_populate_record(null::public.poll_ballots, l.payload)).*
    from last l
   where exists (select 1 from public.polls p where p.id = l.poll_id)
     and exists (select 1 from auth.users  u where u.id = l.user_id)
  on conflict (poll_id, user_id) do nothing;
  get diagnostics nb = row_count;

  with last as (
    select distinct on (poll_id, user_id) poll_id, user_id, payload
      from public.vote_journal
     where kind = 'entry' and at <= t and op <> 'D'
     order by poll_id, user_id, at desc, id desc
  )
  insert into public.poll_entries
  select (jsonb_populate_record(null::public.poll_entries, l.payload)).*
    from last l
   where exists (select 1 from public.polls p where p.id = l.poll_id)
     and exists (select 1 from auth.users  u where u.id = l.user_id)
  on conflict (poll_id, user_id) do nothing;
  get diagnostics ne = row_count;

  return jsonb_build_object(
    'as_of', t, 'ballots_restored', nb, 'entries_restored', ne,
    'live_ballots', (select count(*) from public.poll_ballots),
    'live_entries', (select count(*) from public.poll_entries));
end $$;

-- (라) 기록장이 잘 쌓이는지 관리자 콘솔에서 눈으로 확인할 수 있게
create or replace function public.vote_journal_status()
returns jsonb language plpgsql security definer set search_path = public as $$
declare r text;
begin
  select p.role into r from public.profiles p where p.id = auth.uid();
  if r is null or r not in ('officer','admin') then
    raise exception '혁신행정담당관 또는 운영 관리자만 볼 수 있습니다.';
  end if;
  return jsonb_build_object(
    'rows',         (select count(*) from public.vote_journal),
    'kept_ballots', (select count(*) from (select distinct poll_id, user_id
                       from public.vote_journal where kind = 'ballot') s),
    'kept_entries', (select count(*) from (select distinct poll_id, user_id
                       from public.vote_journal where kind = 'entry') s),
    'first_at',     (select min(at) from public.vote_journal),
    'last_at',      (select max(at) from public.vote_journal),
    'live_ballots', (select count(*) from public.poll_ballots),
    'live_entries', (select count(*) from public.poll_entries));
end $$;

revoke execute on function public.restore_votes(timestamptz) from anon;
grant  execute on function public.restore_votes(timestamptz) to authenticated;
revoke execute on function public.vote_journal_status() from anon;
grant  execute on function public.vote_journal_status() to authenticated;

-- (마) 처음 한 번 — 지금 들어 있는 표를 기록장에 담아 둡니다
--     기록장은 '앞으로 들어올 표'만 자동으로 받습니다. 이 절이 없으면
--     48절을 켜기 전에 이미 던져진 표는 기록장에 없어 되살릴 수 없습니다.
--     이미 담긴 것은 건너뛰므로, 몇 번 실행해도 중복되지 않습니다.
insert into public.vote_journal(at, kind, op, poll_id, user_id, payload)
select coalesce(b.updated_at, b.created_at, now()), 'ballot', 'I', b.poll_id, b.user_id, to_jsonb(b)
  from public.poll_ballots b
 where not exists (select 1 from public.vote_journal j
                    where j.kind = 'ballot' and j.poll_id = b.poll_id and j.user_id = b.user_id);

insert into public.vote_journal(at, kind, op, poll_id, user_id, payload)
select coalesce(e.updated_at, e.created_at, now()), 'entry', 'I', e.poll_id, e.user_id, to_jsonb(e)
  from public.poll_entries e
 where not exists (select 1 from public.vote_journal j
                    where j.kind = 'entry' and j.poll_id = e.poll_id and j.user_id = e.user_id);

-- ============================================================================
--  49. ★ 통째로 비우기(truncate) 차단 — 46절의 구멍을 막습니다
-- ============================================================================
--  46절은 'delete' 만 봅니다. 그런데 'truncate' 는 delete 가 아니어서
--  46절 안전장치를 그냥 지나갑니다. 한 줄로 표를 완전히 비우는 명령입니다.
--  그래서 truncate 전용 안전장치를 따로 답니다. 여기서는 몇 줄이든 무조건 막습니다.

create or replace function public.guard_truncate()
returns trigger language plpgsql as $$
begin
  if coalesce(current_setting('app.bulk_delete_ok', true), '') = 'yes' then
    return null;
  end if;
  raise exception '안전장치가 막았습니다 — "%" 를 통째로 비우려(truncate) 했습니다. 정말 비우시려면 같은 창에서 먼저  set local app.bulk_delete_ok = ''yes'';  를 실행하세요.', tg_table_name;
end $$;

do $$
declare t text;
begin
  foreach t in array array['polls','poll_ballots','poll_entries','vote_journal',
                           'posts','post_comments','post_likes','post_joins',
                           'opinions','opinion_comments','opinion_likes','comment_likes',
                           'profiles','events','reports','expenses']
  loop
    execute format('drop trigger if exists guard_truncate on public.%I', t);
    execute format('create trigger guard_truncate before truncate on public.%I
      for each statement execute function public.guard_truncate()', t);
  end loop;
end $$;
