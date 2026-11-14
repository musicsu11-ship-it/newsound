-- ============================================================================
--  새소리단 — 지금 실행해야 하는 SQL  (2026-11-14)
--
--  ▷ 하는 법
--     1. 이 파일 안을 아무 데나 클릭
--     2. Ctrl + A  (전체 선택)   →   Ctrl + C  (복사)
--     3. Supabase 사이트 → 왼쪽 메뉴 'SQL Editor' → 'New query' 버튼
--     4. 빈 칸에 Ctrl + V  (붙여넣기)   →   오른쪽 아래 'Run' 버튼
--     5. 'Success' 라고 나오면 끝입니다.
--
--  ▷ 이번에 할 것은 38절 하나입니다
--     지난번 파일(29~37절)은 이미 다 들어가 있는 것을 확인했습니다.
--     그래서 이 파일에는 새로 필요한 38절만 담았습니다.
--
--     38절 — 밸런스 게임 참여 이벤트 (소속·연락처 응모)
--        · 한쪽을 고르면 "이벤트에 참여하시겠어요?" 창이 떠서
--          소속과 연락처를 남길 수 있습니다(추첨·경품 안내용).
--        · 명단은 혁신행정담당관·운영 관리자만 목록으로 볼 수 있습니다.
--        · ★ 명단에는 '어느 쪽을 골랐는지' 를 아예 적지 않습니다.
--             익명 투표의 표는 본인 말고 아무도(관리자도) 못 읽습니다.
--             그래서 명단과 표를 붙여 볼 수 있는 사람이 아무도 없습니다.
--        · ★ 지금 올라와 있는 밸런스 게임(Q1~Q4)의 표를 모두 0으로 되돌리고
--             이벤트를 켭니다. 표만 지웁니다 — 질문·선택지·게시글은 그대로입니다.
--             (딱 한 번만 돕니다. 이 파일을 또 실행해도 새 표는 지워지지 않습니다.)
--
--  ▷ 안전한가요?
--     네. 글·사진·의견·보고서·정산·가입한 회원은 하나도 건드리지 않습니다.
--     영수증과 공지사항 제출 파일도 그대로 본인과 담당관만 봅니다. ★보호
--     지우는 것은 밸런스 게임의 '표' 뿐입니다(위 ★ 참고).
--
--  ▷ 이 내용은 supabase/schema.sql 38절과 같습니다.
--     (29~37절을 다시 보고 싶으시면 supabase/schema.sql 에 모두 남아 있습니다.)
-- ============================================================================

-- ============================================================================
--  38. 밸런스 게임 참여 이벤트 (소속·연락처 응모)
--
--  밸런스 게임에서 한쪽을 고르고 나면 "이벤트에 참여하시겠어요?" 창이 떠서
--  소속과 연락처를 남길 수 있습니다. 추첨·경품 안내에 쓰는 명단입니다.
--
--  ★ 가장 중요한 약속 — '누가 어느 쪽을 골랐는지' 는 끝까지 아무도 모릅니다.
--    · 응모 명단(poll_entries)에는 고른 쪽을 아예 적지 않습니다. 소속·연락처뿐입니다.
--    · 표(poll_ballots)는 익명 투표에서는 본인 말고 아무도 못 읽습니다(23절 그대로).
--      관리자도 못 읽습니다. 사람들에게는 항목별 표 수만 보여 줍니다.
--    · 그래서 명단과 표를 붙여 볼 수 있는 사람이 아무도 없습니다.
--
--  누가 무엇을 할 수 있나
--    · 응모하기 : 그 게임에 투표한 사람(익명 접속 포함). 한 사람 한 번, 고쳐 쓸 수 있음
--    · 명단 보기 : 혁신행정담당관 · 운영 관리자 (추첨용)
--    · 내 응모 : 본인은 언제나 자기가 남긴 것을 보고 고칠 수 있습니다
--    · 응모 인원 수(숫자) : 담당관 화면에만 보여 줍니다
-- ============================================================================

-- (1) 이벤트를 받는 게임인지 — 켜 두면 투표한 뒤에 응모 창이 뜹니다
alter table public.polls add column if not exists event_on boolean not null default false;

-- (2) 응모 명단 — 고른 쪽은 적지 않습니다
create table if not exists public.poll_entries (
  poll_id    uuid not null references public.polls on delete cascade,
  user_id    uuid not null default auth.uid() references auth.users on delete cascade,
  team       text not null default '',        -- 소속 (예: 서울남부고용센터 실업급여팀)
  contact    text not null default '',        -- 연락처
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (poll_id, user_id)              -- 한 사람 한 번
);
create index if not exists poll_entries_poll_idx on public.poll_entries (poll_id, created_at);

alter table public.poll_entries enable row level security;

-- 읽기 : 내가 남긴 것 + 혁신행정담당관·관리자는 전부(추첨용)
drop policy if exists pe_select on public.poll_entries;
create policy pe_select on public.poll_entries for select
  using ( user_id = auth.uid() or public.is_officer() );

drop policy if exists pe_insert on public.poll_entries;
create policy pe_insert on public.poll_entries for insert
  with check ( user_id = auth.uid() );

drop policy if exists pe_update on public.poll_entries;
create policy pe_update on public.poll_entries for update
  using ( user_id = auth.uid() );

drop policy if exists pe_delete on public.poll_entries;
create policy pe_delete on public.poll_entries for delete
  using ( user_id = auth.uid() or public.is_admin() );

-- 서버에서도 확인합니다 (화면을 거치지 않고 보내도 똑같이 막힙니다)
--   · 이벤트를 받는 게임인가
--   · 그 게임에 투표를 한 사람인가
--   · 소속·연락처를 비워 두지 않았는가
create or replace function public.check_entry()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.polls p where p.id = new.poll_id and p.event_on) then
    raise exception '이 투표는 이벤트 응모를 받지 않습니다';
  end if;
  if not exists (select 1 from public.poll_ballots b
                  where b.poll_id = new.poll_id and b.user_id = auth.uid()) then
    raise exception '먼저 투표한 뒤에 이벤트에 참여할 수 있습니다';
  end if;

  new.user_id := auth.uid();
  new.team    := btrim(coalesce(new.team, ''));
  new.contact := btrim(coalesce(new.contact, ''));
  if new.team    = '' then raise exception '소속을 입력해 주세요'; end if;
  if new.contact = '' then raise exception '연락처를 입력해 주세요'; end if;
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists poll_entries_check on public.poll_entries;
create trigger poll_entries_check before insert or update on public.poll_entries
  for each row execute function public.check_entry();

-- 응모 인원 — 숫자만 돌려줍니다(명단은 담당관만, 숫자는 담당관 화면에서 씁니다)
create or replace function public.poll_entry_counts()
returns table(poll_id uuid, entries int)
language sql stable security definer set search_path = public as $$
  select e.poll_id, count(*)::int from public.poll_entries e group by e.poll_id
$$;
grant execute on function public.poll_entry_counts() to anon, authenticated;

-- (3) 지금 올라와 있는 밸런스 게임 — 표를 0으로 되돌리고 이벤트를 켭니다
--     ★ 딱 한 번만 돕니다. '이벤트를 켠 밸런스 게임' 이 이미 있으면 그냥 지나가므로,
--       이 파일을 여러 번 실행해도 쌓인 표가 다시 지워지지 않습니다.
do $$
begin
  if not exists (select 1 from public.polls where kind = 'balance' and event_on) then
    delete from public.poll_ballots
     where poll_id in (select id from public.polls where kind = 'balance');
    update public.polls set event_on = true where kind = 'balance';
  end if;
end $$;
