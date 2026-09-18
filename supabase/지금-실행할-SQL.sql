-- ============================================================================
--  새소리단 — 지금 실행해야 하는 SQL  (2026-09-18, 밸런스 게임)
--
--  ▷ 하는 법
--     1. 이 파일 안을 아무 데나 클릭
--     2. Ctrl + A  (전체 선택)   →   Ctrl + C  (복사)
--     3. Supabase 사이트 → 왼쪽 메뉴 'SQL Editor' → 'New query' 버튼
--     4. 빈 칸에 Ctrl + V  (붙여넣기)   →   오른쪽 아래 'Run' 버튼
--     5. 'Success' 라고 나오면 끝입니다.
--
--  ▷ 이번에도 짧습니다
--     지난번 SQL(24절, 투표 사진)까지 실행되어 있는 것을 확인했습니다.
--     이번에 새로 생긴 25절만 들어 있습니다.
--
--  ▷ 안전한가요?
--     네. 글·사진·투표·가입한 회원은 지우지 않습니다.
--     여러 번 실행해도 같은 결과가 나오게 만들어 두었습니다.
--
--  ▷ 무엇이 바뀌나요?
--     1) 투표 게시판에 '밸런스 게임(A vs B)' 을 올릴 수 있게 합니다.
--        지금 있는 투표는 모두 '일반 투표' 로 그대로 남습니다.
--     2) 밸런스 게임은 선택지가 꼭 두 개이고, 하나만 고르게 합니다.
--     3) 올린 뒤에는 투표 ↔ 밸런스 게임 종류를 바꿀 수 없게 합니다.
--
--     ※ 실행하기 전에는 '밸런스 게임 만들기' 를 누르면 안내만 나오고,
--       일반 투표는 지금처럼 그대로 쓸 수 있습니다.
--     ※ 게시판 첨부파일 개선(어떤 파일이든 열기)은 SQL 없이 바로 적용됩니다.
--
--  ▷ 이 내용은 supabase/schema.sql 25절과 같습니다.
--     schema.sql 이 원본이고, 이 파일은 복사하기 편하라고 뽑아 둔 것입니다.
-- ============================================================================

-- ============================================================================
--  25. 밸런스 게임 (투표 게시판 안의 'A vs B' 코너)
--
--  · 투표와 같은 표·같은 규칙(한 사람 한 표, 익명/실명, 마감)을 그대로 씁니다.
--    다른 점은 종류(kind)가 'balance' 이고, 선택지가 딱 두 개(A·B)라는 것뿐입니다.
--  · 올린 뒤에는 종류도 바꿀 수 없습니다(23·24절 규칙에 더함).
-- ============================================================================

alter table public.polls add column if not exists kind text not null default 'poll';

do $$
begin
  -- 종류는 '투표(poll)' 아니면 '밸런스 게임(balance)'
  if not exists (select 1 from pg_constraint where conname = 'polls_kind_check') then
    alter table public.polls add constraint polls_kind_check check (kind in ('poll', 'balance'));
  end if;
  -- 밸런스 게임은 선택지 두 개, 하나만 고르기
  if not exists (select 1 from pg_constraint where conname = 'polls_balance_shape') then
    alter table public.polls add constraint polls_balance_shape
      check (kind <> 'balance' or (cardinality(options) = 2 and not multi));
  end if;
end $$;

create or replace function public.guard_poll_update()
returns trigger language plpgsql as $$
begin
  if new.anonymous is distinct from old.anonymous
     or new.options       is distinct from old.options
     or new.option_images is distinct from old.option_images
     or new.kind          is distinct from old.kind
     or new.multi         is distinct from old.multi
     or (new.author_id is distinct from old.author_id and new.author_id is not null) then
    raise exception '투표를 올린 뒤에는 항목과 익명 여부를 바꿀 수 없습니다';
  end if;
  return new;
end $$;
