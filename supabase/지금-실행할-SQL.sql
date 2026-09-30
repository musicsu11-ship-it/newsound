-- ============================================================================
--  새소리단 — 지금 실행해야 하는 SQL  (2026-10-01)
--
--  ▷ 하는 법
--     1. 이 파일 안을 아무 데나 클릭
--     2. Ctrl + A  (전체 선택)   →   Ctrl + C  (복사)
--     3. Supabase 사이트 → 왼쪽 메뉴 'SQL Editor' → 'New query' 버튼
--     4. 빈 칸에 Ctrl + V  (붙여넣기)   →   오른쪽 아래 'Run' 버튼
--     5. 'Success' 라고 나오면 끝입니다.
--
--  ▷ 세 가지가 들어 있습니다 (26·27절은 아직 실행 전이라 함께 넣었습니다)
--     26절 — 의견함 조회수
--        · 의견을 열어 보면 조회수가 1 올라갑니다(같은 사람은 한 번만).
--        · 누가 봤는지는 아무에게도 보이지 않습니다(숫자만 공개).
--     27절 — 협업 게시판 (새소리단 단원 전용)
--        · '협업' 게시판과 참여자 모집 기능을 만듭니다.
--        · 모집 인원이 차면 서버가 더 받지 않습니다.
--     28절 — 결과보고서를 올린 사람이 고치고 지울 수 있게
--        · 올린 사람: '접수·검토중' 일 때만 수정·삭제 (승인·반려 뒤에는 잠깁니다)
--        · 관리자: 어떤 보고서든 삭제
--        · 올린 사람이 상태·담당관 코멘트를 바꾸지 못하도록 서버가 막습니다.
--
--  ▷ 안전한가요?
--     네. 글·사진·의견·투표·보고서·가입한 회원은 지우지 않습니다.
--     여러 번 실행해도 같은 결과가 나오게 만들어 두었습니다.
--
--  ▷ 이 내용은 supabase/schema.sql 26~28절과 같습니다.
--     schema.sql 이 원본이고, 이 파일은 복사하기 편하라고 뽑아 둔 것입니다.
-- ============================================================================

-- ============================================================================
--  26. 의견함 조회수
--
--  의견을 열어 본 사람 수입니다. 같은 사람이 여러 번 열어도 1로 셉니다.
--  16절 '공감해요' 와 똑같은 방식이라, 누가 봤는지는 남에게 보이지 않습니다.
--  익명 의견함이라 '누가 어떤 의견을 봤는지' 가 보이면 익명이 아니게 되기 때문입니다.
--    · 본 기록은 '내가 본 것' 만 읽을 수 있고
--    · 전체 개수는 opinions.views 칸에 숫자로만 쌓아 그것만 보여 줍니다
-- ============================================================================

alter table public.opinions add column if not exists views int not null default 0;

create table if not exists public.opinion_views (
  opinion_id uuid not null references public.opinions on delete cascade,
  user_id    uuid not null default auth.uid() references auth.users on delete cascade,
  created_at timestamptz not null default now(),
  primary key (opinion_id, user_id)          -- 한 사람은 한 의견에 한 번만 셉니다
);
alter table public.opinion_views enable row level security;

drop policy if exists opview_select on public.opinion_views;
create policy opview_select on public.opinion_views for select
  using ( user_id = auth.uid() );            -- 내가 본 것만 보입니다

drop policy if exists opview_insert on public.opinion_views;
create policy opview_insert on public.opinion_views for insert
  with check ( user_id = auth.uid() );

-- 조회 개수를 opinions.views 에 반영합니다(공감과 같은 방식).
create or replace function public.bump_view()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.opinions set views = views + 1 where id = new.opinion_id;
  return new;
end $$;

drop trigger if exists opinion_views_bump on public.opinion_views;
create trigger opinion_views_bump
  after insert on public.opinion_views
  for each row execute function public.bump_view();

-- 이미 쌓인 기록이 있다면 개수를 다시 세어 맞춥니다(다시 실행해도 안전).
update public.opinions o
   set views = (select count(*) from public.opinion_views v where v.opinion_id = o.id);

-- ============================================================================
--  27. 협업 게시판 (새소리단 단원 전용)
--
--  "한 팀에서 하기엔 큰 아이디어를 여러 팀이 같이 해보자" 는 의견함 제안에서 나온
--  게시판입니다. 글 하나가 '협업 제안' 이고, 다른 단원이 '참여하기' 를 누르면
--  참여자 명단에 이름이 올라갑니다.
--
--  · 읽기·쓰기 모두 단원 이상입니다. 'collab' 은 누구나 읽는 목록(news·activity)에
--    넣지 않았으므로 기존 규칙 그대로 단원 전용이 됩니다.
--  · 참여자 이름은 서버가 계정에서 붙입니다(꾸며 넣을 수 없습니다).
--  · 모집 인원을 정해 두면 인원이 찼을 때 서버가 더 받지 않습니다.
-- ============================================================================

-- ① 게시판 이름 목록에 'collab' 추가 (20절과 같은 방식 — 다시 실행해도 안전)
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
  check (board in ('news','notice','free','share','activity','collab'));

-- ② 모집 인원과 진행 상태 (협업 글에만 씁니다)
alter table public.posts add column if not exists collab_need   int;
alter table public.posts add column if not exists collab_status text not null default 'open';

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'posts_collab_status_check') then
    alter table public.posts add constraint posts_collab_status_check
      check (collab_status in ('open','doing','done'));   -- 모집 중 · 진행 중 · 마무리
  end if;
end $$;

-- ③ 참여 신청
create table if not exists public.post_joins (
  post_id    uuid not null references public.posts on delete cascade,
  user_id    uuid not null default auth.uid() references auth.users on delete cascade,
  name       text not null default '',                    -- 서버가 계정 이름으로 채웁니다
  note       text not null default '',                    -- "디자인 쪽 도울 수 있어요" 같은 한 줄 (선택)
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)                          -- 한 사람이 한 협업에 한 번만
);
alter table public.post_joins enable row level security;

drop policy if exists join_select on public.post_joins;
create policy join_select on public.post_joins for select
  using ( public.is_inner() );                            -- 협업 게시판이 단원 전용이라 명단도 단원만

drop policy if exists join_insert on public.post_joins;
create policy join_insert on public.post_joins for insert
  with check ( user_id = auth.uid() and public.is_inner() );

drop policy if exists join_update on public.post_joins;
create policy join_update on public.post_joins for update
  using ( user_id = auth.uid() );                         -- 한 줄 메모 고치기

drop policy if exists join_delete on public.post_joins;
create policy join_delete on public.post_joins for delete
  using ( user_id = auth.uid() or public.is_admin() );     -- 참여 취소는 본인(또는 관리자)

-- 서버에서 한 번 더 확인합니다 (화면을 거치지 않고 보내도 똑같이 막힙니다)
create or replace function public.check_join()
returns trigger language plpgsql security definer set search_path = public as $$
declare b text; st text; nd int; nm text; cnt int;
begin
  select board, collab_status, collab_need into b, st, nd from public.posts where id = new.post_id;
  if not found              then raise exception '없는 글입니다'; end if;
  if b is distinct from 'collab' then raise exception '협업 게시판 글에만 참여할 수 있습니다'; end if;
  if st = 'done'            then raise exception '이미 마무리된 협업입니다'; end if;

  if tg_op = 'INSERT' and nd is not null then
    select count(*) into cnt from public.post_joins j where j.post_id = new.post_id;
    if cnt >= nd then raise exception '모집 인원이 찼습니다'; end if;
  end if;

  select name into nm from public.profiles where id = auth.uid();
  new.user_id := auth.uid();
  new.name    := coalesce(nullif(trim(nm), ''), '이름 없음');   -- 이름은 서버가 붙입니다
  return new;
end $$;

drop trigger if exists post_joins_check on public.post_joins;
create trigger post_joins_check before insert or update on public.post_joins
  for each row execute function public.check_join();

-- ============================================================================
--  28. 결과보고서 — 올린 사람이 고치고 지울 수 있게
--
--  지금까지는 담당관만 보고서를 고칠 수 있었고, 지우는 것은 관리자만 됐습니다.
--  올린 사람이 잘못 낸 파일을 바꾸거나 내릴 수 없어서 다음처럼 엽니다.
--
--    · 올린 사람 : '접수' 또는 '검토중' 일 때만 고치고 지울 수 있습니다.
--                  담당관이 승인·반려한 뒤에는 손댈 수 없습니다(처리 결과 보존).
--    · 담당관    : 지금처럼 상태·코멘트를 바꿉니다.
--    · 관리자    : 어떤 보고서든 지울 수 있습니다.
--
--  올린 사람이 상태나 담당관 코멘트를 몰래 바꾸지 못하도록, 담당관이 아니면
--  그 칸들은 예전 값 그대로 두도록 서버에서 되돌립니다.
-- ============================================================================

drop policy if exists reports_update on public.reports;
create policy reports_update on public.reports for update
  using (
    public.is_officer()
    or (author_id = auth.uid() and status in ('접수','검토중'))
  )
  with check (
    public.is_officer()
    or (author_id = auth.uid() and status in ('접수','검토중'))
  );

drop policy if exists reports_delete on public.reports;
create policy reports_delete on public.reports for delete
  using (
    public.is_admin()
    or (author_id = auth.uid() and status in ('접수','검토중'))
  );

-- 담당관이 아니면 상태·코멘트·작성자는 바꿀 수 없습니다(화면을 거치지 않고 보내도 막힙니다)
create or replace function public.guard_report_update()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if not public.is_officer() then
    new.status          := old.status;
    new.officer_comment := old.officer_comment;
    new.author_id       := old.author_id;
    new.author_name     := old.author_name;
    new.created_at      := old.created_at;
  end if;
  return new;
end $$;

drop trigger if exists reports_guard on public.reports;
create trigger reports_guard before update on public.reports
  for each row execute function public.guard_report_update();
