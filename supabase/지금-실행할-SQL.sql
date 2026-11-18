-- ============================================================================
--  새소리단 — 지금 실행해야 하는 SQL  (2026-11-18)
--
--  ▷ 하는 법
--     1. 이 파일 안을 아무 데나 클릭
--     2. Ctrl + A  (전체 선택)   →   Ctrl + C  (복사)
--     3. Supabase 사이트 → 왼쪽 메뉴 'SQL Editor' → 'New query' 버튼
--     4. 빈 칸에 Ctrl + V  (붙여넣기)   →   오른쪽 아래 'Run' 버튼
--     5. 'Success' 라고 나오면 끝입니다.
--
--  ▷ 이번에는 41·42·43절입니다 (40절까지는 이미 들어가 있습니다)
--
--     41절 — 이벤트 응모에 '이름' 과 '개인정보 제공 동의' 를 더합니다
--
--     42절 — ★ 지금까지 들어온 밸런스 게임 표를 모두 0 으로 되돌립니다
--            · 질문·선택지·사진은 그대로이고 '표' 만 지웁니다
--            · 시험용 이벤트 응모도 함께 비웁니다
--              (명단을 남겨 두고 싶으시면 그 두 줄을 지우고 실행하세요)
--            · 되돌릴 수 없습니다. 딱 한 번만 실행하세요.
--            · ※ 이미 11.16. 이 지났으니, 지금 들어온 표를 지우고 싶지
--              않으시면 42절 부분(delete 두 덩어리)을 지우고 실행하세요.
--
--     43절 — 출근룩 콘테스트, 한 사람이 한 장만
--            · 같은 계정(같은 브라우저)으로 두 번째 사진을 올릴 수 없습니다
--            · 이름·소속이 똑같은 사진이 이미 있으면 그것도 막습니다
--              (다른 기기에서 올려 계정이 달라지는 경우를 잡기 위함)
--            · 이미 올라와 있는 사진은 지우지 않습니다 — 새로 올릴 때만 확인
--            · 수정·삭제는 그대로 됩니다
--
--  ▷ 안전한가요?
--     41·43절은 아무것도 지우지 않습니다.
--     42절만 '밸런스 게임 표' 와 '이벤트 응모' 를 비웁니다(위 ★ 참고).
--     글·사진·의견·보고서·정산·회원은 하나도 건드리지 않습니다.
--
--  ▷ 이 내용은 supabase/schema.sql 41~43절과 같습니다.
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

-- ============================================================================
--  43. 출근룩 콘테스트 — 한 사람이 한 장만
--
--  · 같은 계정(같은 브라우저)으로는 두 번째 사진을 올릴 수 없습니다.
--  · 이름과 소속이 똑같은 사진이 이미 있으면 그것도 막습니다.
--    (다른 기기에서 올려 계정이 달라지는 경우를 잡기 위한 것입니다)
--  · 이미 올라와 있는 사진은 그대로 둡니다 — 새로 올릴 때만 확인합니다.
--    (지금 같은 이름으로 두 장이 올라와 있어도 지우지 않습니다. 필요하면
--     혁신행정담당관이 화면에서 직접 내리면 됩니다.)
--  · 수정은 그대로 됩니다. 올린 본인이 사진·소개를 고치고 지울 수 있습니다.
-- ============================================================================

create or replace function public.check_ootd_one()
returns trigger language plpgsql security definer set search_path = public as $$
declare nm text; tm text;
begin
  if new.board <> 'ootd' then return new; end if;

  -- 같은 계정으로 이미 올린 사진이 있는가
  if exists (select 1 from public.posts p
              where p.board = 'ootd' and p.author_id = new.author_id) then
    raise exception '출근룩은 한 사람이 한 장만 올릴 수 있습니다. 이미 올리신 사진을 고쳐 주세요.';
  end if;

  -- 이름과 소속이 똑같은 사진이 이미 있는가(둘 다 적혀 있을 때만 확인)
  nm := lower(btrim(coalesce(new.author_name, '')));
  tm := lower(btrim(coalesce(new.author_team, '')));
  if nm <> '' and tm <> '' and exists (
       select 1 from public.posts p
        where p.board = 'ootd'
          and lower(btrim(coalesce(p.author_name, ''))) = nm
          and lower(btrim(coalesce(p.author_team, ''))) = tm) then
    raise exception '이미 같은 이름·소속으로 올린 출근룩이 있습니다. 한 사람이 한 장만 올릴 수 있습니다.';
  end if;

  return new;
end $$;

drop trigger if exists posts_ootd_one on public.posts;
create trigger posts_ootd_one before insert on public.posts
  for each row execute function public.check_ootd_one();
