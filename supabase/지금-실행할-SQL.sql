-- ============================================================================
--  새소리단 — 지금 실행할 SQL
-- ============================================================================
--
--  ▷ 이번에는 46·47절입니다
--
--     46절 — ★ 안전장치. 표가 무더기로 지워지는 사고를 데이터베이스가 직접 막습니다
--     47절 — 백업. 관리자 콘솔에 '💾 백업' 메뉴가 생깁니다
--
--  ▷ 어떻게 실행하나요?
--     1. Supabase 대시보드 → 왼쪽 메뉴 SQL Editor
--     2. 이 파일을 전체 복사(Ctrl+A → Ctrl+C) 해서 붙여넣기
--     3. 오른쪽 위 Run (또는 Ctrl+Enter)
--     4. 끝나면 관리자 콘솔을 새로 열고 '💾 백업'에서 한 번 내려받아 두세요
--
--  ▷ 안전한가요?
--     네. 이 파일에는 '지우는 문장(delete)' 이 하나도 없습니다.
--     오히려 앞으로 지워지는 것을 막아 주는 내용입니다.
--     여러 번 실행해도 결과는 같습니다.
--
--  ▷ 46절이 무엇을 막나요?
--     'polls, posts, opinions, profiles, events, reports, expenses' 에서
--     한 번에 20줄 넘게 지우려 하면 데이터베이스가 거부합니다.
--     'poll_ballots(투표 표), poll_entries(응모 명단)' 는 조금 다릅니다.
--       · 투표 자체를 지워서 표가 함께 지워지는 것 → 그대로 허용
--       · 투표는 놔둔 채 표만 무더기로 지우는 것   → 거부 (2026-11-19 사고)
--
--     정말 많이 지워야 할 때만, 같은 창에서 먼저 이 한 줄을 실행하세요.
--         set local app.bulk_delete_ok = 'yes';
--
--  ▷ 원본은 supabase/schema.sql 46·47절과 같습니다.
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
