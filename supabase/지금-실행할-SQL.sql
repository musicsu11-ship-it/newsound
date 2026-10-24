-- ============================================================================
--  새소리단 — 지금 실행해야 하는 SQL  (2026-10-24)
--
--  ▷ 하는 법
--     1. 이 파일 안을 아무 데나 클릭
--     2. Ctrl + A  (전체 선택)   →   Ctrl + C  (복사)
--     3. Supabase 사이트 → 왼쪽 메뉴 'SQL Editor' → 'New query' 버튼
--     4. 빈 칸에 Ctrl + V  (붙여넣기)   →   오른쪽 아래 'Run' 버튼
--     5. 'Success' 라고 나오면 끝입니다.
--
--  ▷ 이번에 새로 들어간 것
--     35절 — 활동 게시판을 단원 전용으로
--        · 활동 게시판을 '새소리단 단원 전용 공간' 메뉴 안으로 옮겼습니다.
--        · ★ 이제 일반 직원은 활동 게시판을 볼 수 없습니다.
--             메뉴만 옮기면 주소를 아는 사람은 그대로 보이기 때문에
--             데이터베이스 규칙도 같이 좁혔습니다.
--        · 그대로 공개로 두고 싶으시면 35절만 빼고 실행하시거나,
--          35절 안에 적어 둔 '되돌리는 방법' 한 줄을 쓰시면 됩니다.
--
--  ▷ 아직 안 하셨다면 29~34절도 함께 들어 있습니다.
--     이미 실행하셨다면 그냥 다시 지나갑니다(여러 번 해도 안전합니다).
--        29절 — 투표를 올린 뒤에도 고칠 수 있게(실명 → 무기명)
--        30절 — 라운지 게시판 셋
--        31절 — 결과보고서를 단원끼리 서로 볼 수 있게
--        32절 — 글에 '좋아요' + 고드래곤&새초롱이 무기명
--                ★ 그 게시판 글의 '작성자 이름' 을 지웁니다(되돌릴 수 없음)
--        33절 — 글에 댓글 + 공지사항 '제출기한'
--        34절 — 협업 게시판을 칸반 보드로
--
--  ▷ 안전한가요?
--     네. 글·사진·의견·투표·보고서·가입한 회원은 지우지 않습니다.
--     활동비 정산 영수증과 공지사항 제출 파일도 그대로 본인과 담당관만 봅니다. ★보호
--
--  ▷ 이 내용은 supabase/schema.sql 29~35절과 같습니다.
-- ============================================================================

--  29. 투표 수정 — 실명 투표를 무기명(익명)으로 바꿀 수 있게
--
--  지금까지는 투표를 올린 뒤에는 아무것도 바꿀 수 없었습니다. 다음처럼 엽니다.
--    · 제목·마감 : 언제든 바꿀 수 있습니다(예전부터 가능).
--    · 실명 → 익명 : 언제든 바꿀 수 있습니다. 바꾸는 순간 누가 무엇을 골랐는지는
--                    아무에게도 보이지 않게 됩니다(참여자 명단도 닫힙니다).
--    · 익명 → 실명 : 막습니다. 익명인 줄 알고 참여한 사람이 드러나기 때문입니다.
--    · 항목·복수 선택·종류 : 아직 아무도 투표하지 않았을 때만 바꿀 수 있습니다.
-- ============================================================================

create or replace function public.guard_poll_update()
returns trigger language plpgsql security definer set search_path = public as $$
declare votes int;
begin
  if old.anonymous and not new.anonymous then
    raise exception '익명 투표는 실명 투표로 바꿀 수 없습니다';
  end if;

  select count(*) into votes from public.poll_ballots b where b.poll_id = old.id;
  if votes > 0 and (new.options       is distinct from old.options
                 or new.option_images is distinct from old.option_images
                 or new.multi         is distinct from old.multi
                 or new.kind          is distinct from old.kind) then
    raise exception '이미 참여한 사람이 있어 항목은 바꿀 수 없습니다';
  end if;

  if new.author_id is distinct from old.author_id and new.author_id is not null then
    raise exception '투표를 올린 사람은 바꿀 수 없습니다';
  end if;
  return new;
end $$;

-- ============================================================================
--  30. 새 게시판 셋 — 고드래곤&새초롱이 / AI.zip / 멘탈관리.zip
--
--  · mascot : '고드래곤&새초롱이' — 자체 제작 이미지와 자료를 나누는 곳
--  · ai     : 'AI.zip' — 고용·노동·산안 담당 업무별 AI 꿀팁을 나누는 곳
--             글마다 담당 업무(topic)를 적어 둡니다. 예) '실업급여','노동위원회'
--             업무 이름 목록은 화면(index.html 의 AI_FIELDS)에만 있습니다.
--             topic 은 그냥 글자이므로 이름이 바뀌어도 SQL 은 고치지 않아도 됩니다.
--  · relief : '멘탈관리.zip' — 스트레스 해소법과 마음을 나누는 곳(사진·영상·파일 가능)
--
--  읽기는 누구나(일반 직원 포함), 쓰기는 단원 이상입니다. 소식·활동과 같은 규칙입니다.
-- ============================================================================

-- 글의 담당 업무 (AI.zip 에서 씁니다. 다른 게시판 글은 비워 둡니다)
alter table public.posts add column if not exists topic text;

-- 게시판 이름 목록 다시 걸기 (20·27절과 같은 방식 — 다시 실행해도 안전)
do $$
declare c text;
begin
  for c in
    select conname from pg_constraint
     where conrelid = 'public.posts'::regclass
       and contype  = 'c'
       and pg_get_constraintdef(oid) ilike '%board%'
  loop
    execute format('alter table public.posts drop constraint %I', c);
  end loop;
end $$;

alter table public.posts add constraint posts_board_check
  check (board in ('news','notice','free','share','activity','collab','mascot','ai','relief'));

-- 읽기 권한 — 소식·활동과 새 게시판 셋은 누구나, 나머지는 단원 이상
drop policy if exists posts_select on public.posts;
create policy posts_select on public.posts for select
  using ( board in ('news','activity','mascot','ai','relief') or public.is_inner() );

-- ============================================================================
--  31. 결과보고서를 단원끼리 서로 볼 수 있게
--
--  지금까지는 '올린 본인과 혁신행정담당관' 만 볼 수 있었습니다.
--  조별 활동 결과를 서로 참고할 수 있도록 단원 이상이면 모두 볼 수 있게 엽니다.
--
--  · 목록·내용 : 단원 이상 모두 열람
--  · 첨부 파일 : 단원 이상 모두 열람 (docs 저장소의 reports/ 폴더만)
--  · 활동비 정산 영수증(docs 의 expenses/ 폴더)은 그대로 본인과 담당관만 봅니다. ★중요
--  · 수정·삭제 권한은 그대로입니다(올린 본인은 접수·검토중일 때만, 관리자는 언제든).
-- ============================================================================

drop policy if exists reports_select on public.reports;
create policy reports_select on public.reports for select
  using ( author_id = auth.uid() or public.is_inner() );

-- 첨부 파일 읽기 — reports/ 폴더는 단원 이상, 그 밖(영수증 등)은 본인과 담당관만
drop policy if exists docs_read on storage.objects;
create policy docs_read on storage.objects for select
  using (
    bucket_id = 'docs'
    and (
      public.storage_owner(name) = auth.uid()
      or public.is_officer()
      or ((storage.foldername(name))[1] = 'reports' and public.is_inner())
    )
  );

-- ============================================================================
--  32. 글에 '좋아요' + 고드래곤&새초롱이 무기명
--
--  (1) 좋아요 — 소식·활동·라운지 등 게시판 글 전부에 붙습니다.
--      · 한 계정이 한 글에 한 번만. 다시 누르면 취소됩니다.
--      · 누가 눌렀는지는 남에게 보이지 않습니다(16절 의견 공감과 같은 방식).
--        '내가 눌렀는지' 만 내가 읽을 수 있고, 전체 개수는 posts.likes 숫자를 씁니다.
--
--  (2) 고드래곤&새초롱이(mascot)은 무기명입니다.
--      화면에서 이름을 비워 보내고, 서버에서도 그 게시판 글이면 이름·소속을 지웁니다.
--      ★ author_id(누가 올렸는지 가리키는 번호)는 남습니다. 본인이 자기 글을
--        고치고 지울 수 있어야 하고, 데이터베이스 권한 규칙도 그 번호로 판단하기
--        때문입니다. 화면에는 어디에도 나오지 않지만, 데이터베이스를 직접 열 수 있는
--        관리자라면 번호를 회원 명단과 맞춰 볼 수는 있습니다. 완전한 익명이 필요하면
--        말씀해 주세요(그 경우 본인 수정·삭제를 포기해야 합니다).
--
--  이미 올라와 있는 mascot 글의 이름도 함께 지웁니다 — 되돌릴 수 없습니다.
-- ============================================================================

alter table public.posts add column if not exists likes int not null default 0;

create table if not exists public.post_likes (
  post_id    uuid not null references public.posts on delete cascade,
  user_id    uuid not null default auth.uid() references auth.users on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)             -- 한 사람이 한 글에 한 번만
);
alter table public.post_likes enable row level security;

drop policy if exists postlike_select on public.post_likes;
create policy postlike_select on public.post_likes for select
  using ( user_id = auth.uid() );            -- 내가 누른 것만 보입니다

drop policy if exists postlike_insert on public.post_likes;
create policy postlike_insert on public.post_likes for insert
  with check ( user_id = auth.uid() );

drop policy if exists postlike_delete on public.post_likes;
create policy postlike_delete on public.post_likes for delete
  using ( user_id = auth.uid() );            -- 자기가 누른 것만 취소

-- 좋아요 개수를 posts.likes 에 반영합니다(공감 표를 못 읽는 사람도 개수는 정확하게).
create or replace function public.bump_post_like()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    update public.posts set likes = likes + 1 where id = new.post_id;
    return new;
  else
    update public.posts set likes = greatest(likes - 1, 0) where id = old.post_id;
    return old;
  end if;
end $$;

drop trigger if exists post_likes_bump on public.post_likes;
create trigger post_likes_bump
  after insert or delete on public.post_likes
  for each row execute function public.bump_post_like();

-- 이미 눌린 좋아요가 있다면 개수를 다시 세어 맞춥니다(다시 실행해도 안전).
update public.posts p
   set likes = (select count(*) from public.post_likes l where l.post_id = p.id);

-- 고드래곤&새초롱이 무기명 — 이름이 들어와도 서버에서 지웁니다
create or replace function public.anon_mascot_post()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.board = 'mascot' then
    new.author_name := '';
    new.author_team := '';
    new.author_dept := '';
  end if;
  return new;
end $$;

drop trigger if exists posts_anon_mascot on public.posts;
create trigger posts_anon_mascot
  before insert or update on public.posts
  for each row execute function public.anon_mascot_post();

-- 이미 올라와 있는 글의 이름도 지웁니다
update public.posts
   set author_name = '', author_team = '', author_dept = ''
 where board = 'mascot';

-- ============================================================================
--  33. 글에 댓글 + 공지사항 '제출기한'
--
--  (1) post_comments — 게시판 글에 다는 댓글
--      · 읽기 : 그 글을 볼 수 있는 사람이면 누구나(소식·활동·라운지는 전 직원)
--      · 쓰기 : 단원 이상. 지우기·고치기는 쓴 본인과 관리자만.
--      · 이름 : 서버가 회원 명단에서 가져와 붙입니다(꾸며 넣을 수 없음).
--               고드래곤&새초롱이 은 무기명이라 댓글에도 이름을 붙이지 않습니다.
--
--  (2) files — 댓글에 올린 파일. 공지사항(notice) 제출용입니다.
--      ★ 파일은 비공개 저장소 docs 의 submits/ 폴더에 둡니다.
--        올린 본인과 혁신행정담당관만 열 수 있습니다(31절 docs_read 규칙 그대로).
--        글·사진 첨부가 쓰는 media 저장소와 달리 주소만 알면 열리지 않습니다.
--
--  (3) posts.due_at — 공지사항 글의 제출기한(날짜). 비워 두면 기한 없는 보통 공지입니다.
--      · 기한이 지나도 낼 수는 있고, 대신 '마감 후 제출' 로 표시됩니다.
--        (못 내게 막는 것보다 늦게라도 받는 편이 낫다고 보고 이렇게 했습니다.
--         아예 막아야 하면 말씀해 주세요.)
-- ============================================================================

alter table public.posts add column if not exists due_at date;

create table if not exists public.post_comments (
  id          uuid primary key default gen_random_uuid(),
  post_id     uuid not null references public.posts on delete cascade,
  body        text not null default '',
  files       jsonb not null default '[]'::jsonb,   -- docs 버킷 submits/ 경로
  author_id   uuid not null default auth.uid() references auth.users on delete cascade,
  author_name text not null default '',
  created_at  timestamptz not null default now()
);
create index if not exists post_comments_post_idx on public.post_comments (post_id, created_at);

alter table public.post_comments enable row level security;

-- 댓글 이름은 서버가 붙입니다. 무기명 게시판(mascot)이면 비워 둡니다.
create or replace function public.set_comment_author()
returns trigger language plpgsql security definer set search_path = public as $$
declare bd text;
begin
  select p.board into bd from public.posts p where p.id = new.post_id;
  if bd = 'mascot' then
    new.author_name := '';
  else
    new.author_name := coalesce((select name from public.profiles where id = auth.uid()), '단원');
  end if;
  return new;
end $$;

drop trigger if exists post_comments_set_author on public.post_comments;
create trigger post_comments_set_author before insert on public.post_comments
  for each row execute function public.set_comment_author();

-- 읽기 — 그 글을 볼 수 있으면 댓글도 봅니다(posts 의 읽기 규칙을 그대로 따라갑니다)
drop policy if exists pc_select on public.post_comments;
create policy pc_select on public.post_comments for select
  using ( exists (select 1 from public.posts p where p.id = post_id) );

drop policy if exists pc_insert on public.post_comments;
create policy pc_insert on public.post_comments for insert
  with check ( author_id = auth.uid() and public.is_inner() );

drop policy if exists pc_update on public.post_comments;
create policy pc_update on public.post_comments for update
  using ( author_id = auth.uid() or public.is_admin() );

drop policy if exists pc_delete on public.post_comments;
create policy pc_delete on public.post_comments for delete
  using ( author_id = auth.uid() or public.is_admin() );

-- 제출 파일 저장소는 새로 만들 것이 없습니다.
--   올리기 : 9절 docs_write — 단원 이상이 '자기 폴더' 에만 올릴 수 있습니다.
--            제출 파일 경로가 submits/<내 계정번호>/... 라서 그대로 통과합니다.
--   읽기   : 31절 docs_read — 올린 본인과 혁신행정담당관만. ★제출물 보호
--   지우기 : 9절 docs_delete — 올린 본인과 관리자만.

-- ============================================================================
--  34. 협업 게시판을 칸반 보드로 — 인원 모집 대신 '할 일 · 진행 중 · 완료'
--
--  · 모집 인원(collab_need)은 더 쓰지 않습니다. 칸은 그대로 두되 화면에서는
--    쓰지 않습니다(예전 글에 적힌 값도 그냥 남아 있기만 합니다).
--  · post_joins 는 '모집한 참여자' 가 아니라 '담당자' 가 됩니다. 쓰는 방법은 같습니다.
--  · 마감일은 33절에서 만든 posts.due_at 을 함께 씁니다.
--
--  ★ 바뀌는 권한 : 담당자로 참여한 사람도 카드를 옮길 수 있게 합니다.
--    칸반 보드는 맡은 사람이 직접 '진행 중 → 완료' 로 옮길 수 있어야 쓸모가 있습니다.
--    담당자는 진행 상태(collab_status) 말고는 아무것도 바꾸지 못합니다.
--    제목·내용·첨부·마감일·글쓴이는 서버에서 예전 값으로 되돌립니다.
--    글을 고치고 지우는 것은 지금처럼 글쓴이와 관리자만 할 수 있습니다.
-- ============================================================================

drop policy if exists posts_update on public.posts;
create policy posts_update on public.posts for update
  using (
    author_id = auth.uid()
    or public.is_admin()
    -- 협업 카드는 담당자도 손댈 수 있습니다(아래 트리거가 '상태만' 으로 좁힙니다)
    or (board = 'collab' and exists (
          select 1 from public.post_joins j
           where j.post_id = posts.id and j.user_id = auth.uid()))
  );

-- 좋아요 개수를 올리고 내리는 중이라는 표시를 켜 둡니다.
-- 아래 guard_collab_update 가 이 표시를 보고 그냥 지나갑니다
-- (안 그러면 담당자가 좋아요를 누를 때 개수가 도로 되돌려집니다).
create or replace function public.bump_post_like()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform set_config('app.like_bump', '1', true);     -- true = 이 트랜잭션 안에서만
  if tg_op = 'INSERT' then
    update public.posts set likes = likes + 1 where id = new.post_id;
    perform set_config('app.like_bump', '', true);
    return new;
  else
    update public.posts set likes = greatest(likes - 1, 0) where id = old.post_id;
    perform set_config('app.like_bump', '', true);
    return old;
  end if;
end $$;

create or replace function public.guard_collab_update()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce(current_setting('app.like_bump', true), '') = '1' then return new; end if;
  -- 글쓴이·관리자는 지금처럼 전부 바꿀 수 있습니다
  if old.author_id = auth.uid() or public.is_admin() then return new; end if;
  -- 그 밖의 사람(담당자)은 진행 상태만 — 나머지는 예전 값으로 되돌립니다
  new.title        := old.title;
  new.body         := old.body;
  new.board        := old.board;
  new.images       := old.images;
  new.pinned       := old.pinned;
  new.author_id    := old.author_id;
  new.author_name  := old.author_name;
  new.author_team  := old.author_team;
  new.author_dept  := old.author_dept;
  new.topic        := old.topic;
  new.team_no      := old.team_no;
  new.due_at       := old.due_at;
  new.collab_need  := old.collab_need;
  new.likes        := old.likes;
  return new;
end $$;

drop trigger if exists posts_guard_collab on public.posts;
create trigger posts_guard_collab
  before update on public.posts
  for each row execute function public.guard_collab_update();

-- ============================================================================
--  35. 활동 게시판을 단원 전용으로
--
--  활동 게시판을 '새소리단 단원 전용 공간' 메뉴 안으로 옮겼습니다.
--  메뉴만 옮기면 주소를 아는 일반 직원은 그대로 볼 수 있으므로,
--  데이터베이스 규칙도 같이 단원 이상으로 좁힙니다.
--
--  · 누구나 읽는 게시판 : 소식 + 라운지 셋(고드래곤&새초롱이 / AI.zip / 멘탈관리.zip)
--  · 단원 이상만 읽는 게시판 : 활동 · 공지사항 · 자유방 · 새소리단 공간 · 협업
--
--  ※ 다시 누구나 볼 수 있게 되돌리려면 아래 목록에 'activity' 를 넣고 다시 실행하면 됩니다.
--      using ( board in ('news','activity','mascot','ai','relief') or public.is_inner() );
-- ============================================================================

drop policy if exists posts_select on public.posts;
create policy posts_select on public.posts for select
  using ( board in ('news','mascot','ai','relief') or public.is_inner() );
