-- ============================================================================
--  새소리단 — 지금 실행해야 하는 SQL  (2026-11-15)
--
--  ▷ 하는 법
--     1. 이 파일 안을 아무 데나 클릭
--     2. Ctrl + A  (전체 선택)   →   Ctrl + C  (복사)
--     3. Supabase 사이트 → 왼쪽 메뉴 'SQL Editor' → 'New query' 버튼
--     4. 빈 칸에 Ctrl + V  (붙여넣기)   →   오른쪽 아래 'Run' 버튼
--     5. 'Success' 라고 나오면 끝입니다.
--
--  ▷ 이번에 할 것은 39·40절입니다 (38절까지는 이미 들어가 있습니다)
--
--     39절 — ① 라운지에 '우리 지청 맛집' 게시판을 엽니다
--            ② 진행 중인 투표를 모두 🎁 이벤트 대상으로 켭니다(Q5 포함)
--
--     40절 — 새소리단 전용이 아닌 게시판은 '로그인 없이도' 글을 쓸 수 있게
--            · 여는 곳 : 출근룩 콘테스트 · 고드래곤&새초롱이 · AI.zip ·
--                        멘탈관리.zip · 우리 지청 맛집  (댓글도 함께)
--            · 그대로 : 새소리단 소식(공지 성격이라 단원만 올립니다),
--                       공지사항·자유방·활동·협업·새소리단 공간,
--                       그리고 투표를 '만드는' 것(로그인 회원만)
--            · 장난 글·사진은 혁신행정담당관이 바로 내릴 수 있게 했습니다 ★정리
--            · 첨부는 그 게시판 이름 폴더에, 그것도 자기 폴더에만 올라갑니다
--
--  ▷ 안전한가요?
--     네. 이번에도 아무것도 지우지 않습니다.
--     글·사진·의견·투표·보고서·정산·가입한 회원 모두 그대로입니다.
--     영수증과 공지사항 제출 파일(docs 저장소)은 손도 대지 않습니다. ★보호
--     39절을 이미 실행하셨어도 그냥 다시 지나갑니다(여러 번 해도 안전합니다).
--
--  ▷ 이 내용은 supabase/schema.sql 39·40절과 같습니다.
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

-- ============================================================================
--  40. 새소리단 전용 공간이 아닌 게시판은 '로그인 없이도' 글을 쓸 수 있게
--
--  열어 주는 곳 (OPEN_BOARDS)
--    · ootd   출근룩 사진 콘테스트  (37절에서 이미 열었습니다)
--    · mascot 고드래곤&새초롱이
--    · ai     AI.zip
--    · relief 멘탈관리.zip
--    · food   우리 지청 맛집
--
--  그대로 두는 곳
--    · news   새소리단 소식 — 공지 성격이라 지금처럼 단원 이상만 올립니다.
--    · notice/free/share/activity/collab — 새소리단 전용 공간 그대로입니다.
--    · 투표·밸런스 게임 '만들기' — 지금처럼 가입해서 로그인한 회원만 만듭니다.
--      (참여(투표)는 예전부터 로그인 없이도 됩니다)
--
--  할 수 있는 일 / 지킨 것
--    · 글쓰기·댓글 : 홈페이지에 들어온 사람 누구나(익명 접속 포함)
--    · 고치기·지우기 : 올린 본인만 (익명 접속도 그 브라우저 계정이 본인입니다)
--    · 장난 글·사진 : 혁신행정담당관·관리자가 바로 내릴 수 있습니다 ★정리
--    · 첨부 파일 : media 저장소의 '게시판 이름' 폴더에만, 그것도 자기 폴더에만
--                  올라갑니다 (media/food/<사람>/… ). 다른 폴더는 예전 그대로입니다.
--    · 영수증·공지사항 제출 파일(docs 저장소)은 전혀 건드리지 않습니다. ★보호
-- ============================================================================

-- 올리기 — 열린 게시판 다섯 곳은 누구나, 공지사항은 담당관, 나머지는 단원 이상
drop policy if exists posts_insert on public.posts;
create policy posts_insert on public.posts for insert
  with check (
    author_id = auth.uid()
    and case
          when board in ('ootd','mascot','ai','relief','food') then auth.uid() is not null
          when board = 'notice' then public.is_officer()
          else public.is_inner()
        end
  );

-- 지우기 — 올린 본인·관리자에 더해, 열린 게시판은 담당관도 내릴 수 있게
drop policy if exists posts_delete on public.posts;
create policy posts_delete on public.posts for delete
  using (
    author_id = auth.uid()
    or public.is_admin()
    or (board in ('ootd','mascot','ai','relief','food') and public.is_officer())
  );

-- 댓글 — 열린 게시판은 누구나, 나머지는 단원 이상
drop policy if exists pc_insert on public.post_comments;
create policy pc_insert on public.post_comments for insert
  with check (
    author_id = auth.uid()
    and (
      public.is_inner()
      or exists (select 1 from public.posts p
                  where p.id = post_id
                    and p.board in ('ootd','mascot','ai','relief','food'))
    )
  );

-- 사진·파일 올리기 — 열린 게시판 이름의 폴더는 누구나(자기 폴더에만),
--                    그 밖(posts/ 등)은 예전처럼 단원 이상
drop policy if exists media_write on storage.objects;
create policy media_write on storage.objects for insert
  with check (
    bucket_id = 'media'
    and public.storage_owner(name) = auth.uid()        -- 남의 폴더에 못 올림
    and (
      public.is_inner()
      or (storage.foldername(name))[1] in ('ootd','mascot','ai','relief','food')
    )
  );

-- 사진·파일 내리기 — 올린 본인·관리자에 더해, 열린 게시판 폴더는 담당관도
drop policy if exists media_delete on storage.objects;
create policy media_delete on storage.objects for delete
  using (
    bucket_id = 'media'
    and (
      public.storage_owner(name) = auth.uid()
      or public.is_admin()
      or ((storage.foldername(name))[1] in ('ootd','mascot','ai','relief','food')
          and public.is_officer())
    )
  );

-- 댓글 내리기 — 올린 본인·관리자에 더해, 열린 게시판은 담당관도 ★정리
drop policy if exists pc_delete on public.post_comments;
create policy pc_delete on public.post_comments for delete
  using (
    author_id = auth.uid()
    or public.is_admin()
    or (public.is_officer() and exists (
          select 1 from public.posts p
           where p.id = post_id
             and p.board in ('ootd','mascot','ai','relief','food')))
  );
