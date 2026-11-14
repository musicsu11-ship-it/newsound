-- ============================================================================
--  새소리단 — 지금 실행해야 하는 SQL  (2026-11-14 두 번째)
--
--  ▷ 하는 법
--     1. 이 파일 안을 아무 데나 클릭
--     2. Ctrl + A  (전체 선택)   →   Ctrl + C  (복사)
--     3. Supabase 사이트 → 왼쪽 메뉴 'SQL Editor' → 'New query' 버튼
--     4. 빈 칸에 Ctrl + V  (붙여넣기)   →   오른쪽 아래 'Run' 버튼
--     5. 'Success' 라고 나오면 끝입니다.
--
--  ▷ 이번에 할 것은 39절 하나입니다 (38절까지는 이미 들어가 있습니다)
--
--     39절 — ① 라운지에 '우리 지청 맛집' 게시판을 엽니다
--               · 읽기는 누구나, 글쓰기는 새소리단 단원 이상
--                 (라운지의 다른 세 곳과 똑같은 규칙입니다)
--            ② 진행 중인 투표를 모두 🎁 이벤트 대상으로 켭니다
--               · 38절은 밸런스 게임(A vs B)만 켰습니다.
--                 항목이 여럿인 Q5 도 같은 이벤트로 묶기 위한 것입니다.
--
--  ▷ 안전한가요?
--     네. 이번에는 아무것도 지우지 않습니다.
--     투표에 들어온 표도 그대로 둡니다(38절과 달리 0으로 되돌리지 않습니다).
--     글·사진·의견·보고서·정산·가입한 회원도 그대로입니다.
--     영수증과 공지사항 제출 파일도 그대로 본인과 담당관만 봅니다. ★보호
--
--  ▷ 이 내용은 supabase/schema.sql 39절과 같습니다.
-- ============================================================================

-- ============================================================================
--  39. 라운지에 '우리 지청 맛집' 게시판 (food)
--      + 여러 항목 투표도 참여 이벤트를 받을 수 있게
--
--  · 맛집 게시판은 라운지 세 곳(고드래곤&새초롱이 · AI.zip · 멘탈관리.zip)과
--    똑같은 규칙입니다 — 읽기는 누구나, 글쓰기는 새소리단 단원 이상.
--  · 밸런스 게임(A vs B)뿐 아니라 여러 항목 투표에도 🎁 이벤트를 켤 수 있습니다.
--    (조직문화개선 Q5 처럼 항목이 여럿인 투표도 같은 이벤트로 묶기 위해서입니다)
-- ============================================================================

-- 게시판 이름 목록 다시 걸기
--   ★ 목록에 없는 이름이 글에 남아 있으면 그 이름도 함께 넣습니다(37절과 같은 방식).
do $$
declare c text; extra text;
begin
  for c in
    select conname from pg_constraint
     where conrelid = 'public.posts'::regclass
       and contype  = 'c'
       and pg_get_constraintdef(oid) ilike '%board%'
  loop
    execute format('alter table public.posts drop constraint %I', c);
  end loop;

  select string_agg(distinct quote_literal(board), ', ') into extra
    from public.posts
   where board not in ('news','notice','free','share','activity','collab',
                       'mascot','ai','relief','ootd','food');

  if extra is not null then
    raise notice '목록에 없던 게시판 이름을 함께 넣었습니다: %', extra;
  end if;

  execute 'alter table public.posts add constraint posts_board_check check (board in ('
       || '''news'',''notice'',''free'',''share'',''activity'',''collab'','
       || '''mascot'',''ai'',''relief'',''ootd'',''food'''
       || coalesce(', ' || extra, '') || '))';
end $$;

-- 읽기 — 맛집도 누구나 볼 수 있게(라운지 셋과 같은 수준)
drop policy if exists posts_select on public.posts;
create policy posts_select on public.posts for select
  using ( board in ('news','mascot','ai','relief','ootd','food') or public.is_inner() );

-- 글쓰기·지우기·댓글은 37절 규칙 그대로입니다.
--   맛집은 'ootd' 처럼 따로 열지 않았으므로 단원 이상만 글을 씁니다.

-- 진행 중인 투표는 모두 🎁 이벤트를 받도록 켭니다
--   (38절은 밸런스 게임만 켰습니다. 여러 항목 투표인 Q5 도 같이 묶습니다.
--    표는 건드리지 않습니다 — 이미 들어온 표는 그대로입니다.)
update public.polls set event_on = true where not closed and not event_on;
