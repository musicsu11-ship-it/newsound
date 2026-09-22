-- ============================================================================
--  새소리단 — 지금 실행해야 하는 SQL  (2026-09-22, 의견함 조회수)
--
--  ▷ 하는 법
--     1. 이 파일 안을 아무 데나 클릭
--     2. Ctrl + A  (전체 선택)   →   Ctrl + C  (복사)
--     3. Supabase 사이트 → 왼쪽 메뉴 'SQL Editor' → 'New query' 버튼
--     4. 빈 칸에 Ctrl + V  (붙여넣기)   →   오른쪽 아래 'Run' 버튼
--     5. 'Success' 라고 나오면 끝입니다.
--
--  ▷ 이번에도 짧습니다
--     지난번 SQL(25절, 밸런스 게임)까지 실행되어 있는 것을 확인했습니다.
--     이번에 새로 생긴 26절만 들어 있습니다.
--
--  ▷ 안전한가요?
--     네. 글·사진·의견·투표·가입한 회원은 지우지 않습니다.
--     여러 번 실행해도 같은 결과가 나오게 만들어 두었습니다.
--
--  ▷ 무엇이 바뀌나요?
--     1) 의견함에 '조회수' 를 만듭니다. 의견을 열어 보면 1씩 올라갑니다.
--     2) 같은 사람이 여러 번 열어도 1로 셉니다.
--     3) 누가 봤는지는 아무에게도 보이지 않습니다(숫자만 공개).
--        의견함이 익명이라, '누가 어떤 의견을 봤는지' 가 보이면 안 되기 때문입니다.
--
--     ※ 실행하기 전에는 조회수 칸만 안 보일 뿐, 의견함은 지금처럼 그대로 쓸 수 있습니다.
--     ※ 공감 아이콘 키우기, '가장 공감한 의견' 시상대, 안내 문구 변경은
--       SQL 없이 바로 적용됩니다.
--
--  ▷ 이 내용은 supabase/schema.sql 26절과 같습니다.
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
