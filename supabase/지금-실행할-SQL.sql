-- ============================================================================
--  새소리단 — 지금 실행해야 하는 SQL  (2026-11-15 세 번째)
--
--  ▷ 하는 법
--     1. 이 파일 안을 아무 데나 클릭
--     2. Ctrl + A  (전체 선택)   →   Ctrl + C  (복사)
--     3. Supabase 사이트 → 왼쪽 메뉴 'SQL Editor' → 'New query' 버튼
--     4. 빈 칸에 Ctrl + V  (붙여넣기)   →   오른쪽 아래 'Run' 버튼
--     5. 'Success' 라고 나오면 끝입니다.
--
--  ▷ 이번에는 41·42절입니다 (40절까지는 이미 들어가 있습니다)
--
--     41절 — 이벤트 응모에 '이름' 과 '개인정보 제공 동의' 를 더합니다
--            · 응모 창에서 이름 · 소속 · 연락처를 받습니다
--            · 동의(체크)해야 응모됩니다 — 서버에서도 막습니다
--            · 관리자 콘솔 명단에 이름·동의 여부가 함께 나옵니다
--
--     42절 — ★ 지금까지 들어온 투표를 모두 0 으로 되돌립니다
--            · 11. 16. 시작에 맞춰 시험 삼아 던진 표를 비웁니다
--            · 질문·선택지·사진·게시글은 그대로이고 '표' 만 지웁니다
--            · 시험용 이벤트 응모 1건도 함께 비웁니다
--              (명단을 남겨 두고 싶으시면 파일 맨 아래 두 줄을 지우세요)
--            · 되돌릴 수 없습니다. 시작 전 딱 한 번만 실행하세요.
--
--  ▷ 안전한가요?
--     41절은 아무것도 지우지 않습니다.
--     42절은 '투표한 표' 와 '이벤트 응모' 만 지웁니다. 그 밖의 글·사진·
--     의견·보고서·정산·회원은 하나도 건드리지 않습니다.
--
--  ▷ 이 내용은 supabase/schema.sql 41·42절과 같습니다.
-- ============================================================================

-- ============================================================================
--  41. 이벤트 응모에 이름 + 개인정보 제공 동의 받기
--
--  · 응모할 때 이름 · 소속 · 연락처를 받고, 개인정보 제공 동의를 체크해야
--    응모가 됩니다(체크하지 않으면 서버에서도 막습니다).
--  · 동의한 시각은 서버 시계로 적습니다(화면에서 꾸며 보낼 수 없습니다).
--
--  ★ 그대로 지킨 것 — 응모 명단에는 '어느 쪽을 골랐는지' 가 여전히 없습니다.
--    익명 투표의 표는 본인 말고 아무도(관리자도) 못 읽습니다(23·38절 그대로).
-- ============================================================================

alter table public.poll_entries add column if not exists name      text not null default '';
alter table public.poll_entries add column if not exists agreed_at timestamptz;

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
  new.name    := btrim(coalesce(new.name, ''));
  new.team    := btrim(coalesce(new.team, ''));
  new.contact := btrim(coalesce(new.contact, ''));
  if new.name    = '' then raise exception '이름을 입력해 주세요'; end if;
  if new.team    = '' then raise exception '소속을 입력해 주세요'; end if;
  if new.contact = '' then raise exception '연락처를 입력해 주세요'; end if;

  -- 개인정보 제공에 동의해야 응모됩니다. 동의 시각은 서버 시계로 적습니다.
  if new.agreed_at is null then
    raise exception '개인정보 제공에 동의해야 응모할 수 있습니다';
  end if;
  new.agreed_at  := now();
  new.updated_at := now();
  return new;
end $$;

-- ============================================================================
--  42. 캠페인 시작 전 — 투표 결과를 모두 0 으로 되돌리기
--
--  11. 16. 시작에 맞춰, 그동안 들어온 '시험 삼아 던진 표' 를 모두 비웁니다.
--  질문·선택지·사진·게시글은 그대로이고, 표만 지웁니다.
--
--  ★ 되돌릴 수 없습니다. 시작 전 딱 한 번만 실행하세요.
--    (다시 실행하면 그때까지 쌓인 진짜 표도 지워집니다)
-- ============================================================================

-- 진행 중인 투표(Q1~Q5)의 표를 모두 지웁니다 → 모든 항목 0표
delete from public.poll_ballots
 where poll_id in (select id from public.polls where not closed);

-- 시험 삼아 넣어 본 이벤트 응모도 함께 비웁니다.
--   ※ 응모 명단을 남겨 두고 싶으시면 아래 두 줄만 지우고 실행하세요.
delete from public.poll_entries
 where poll_id in (select id from public.polls where not closed);
