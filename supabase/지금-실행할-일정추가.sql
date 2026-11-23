-- ============================================================================
--  새소리단 — 일정에 '종료일'과 '색상' 더하기 + 캠페인 일정을 기간 일정으로
--
--  ▷ 세 가지를 합니다.
--
--     ① events 표에 빈 칸 두 개를 더합니다
--          end_date  — 종료일 (비워 두면 지금까지처럼 하루짜리 일정)
--          color     — 색상 (blue·green·orange·pink·purple·gray 여섯 가지)
--        기존 일정은 그대로 남습니다. 종료일이 비어 있어 하루짜리로 나오고,
--        색은 기본값인 파랑이 됩니다.
--
--     ② 어제 넣으신 '시작' 일정 두 건을 기간 일정으로 바꿉니다
--          「…밸런스게임 시작」(11/16) → 「…밸런스게임」 11/16 ~ 11/26 · 파랑
--          「출근룩 사진 콘테스트 시작」(11/23) → 11/23 ~ 11/30 · 분홍
--        제목에서 '시작'을 떼고 종료일과 색을 넣는 것이 전부입니다.
--
--     ③ 혹시 ②에서 바꿀 일정이 없으면(처음 넣는 경우) 새로 넣습니다.
--
--  ▷ ★ 실행한 뒤에 손수 하실 일이 하나 있습니다 ★
--     '마감' 일정 두 건이 남습니다. 이제 기간 띠에 끝날이 드러나므로 필요
--     없습니다. 홈페이지 → 일정 에서 지워 주세요.
--
--       · 11월 26일을 누르고 →「…밸런스게임 마감」의 [삭제]
--       · 11월 30일을 누르고 →「출근룩 사진 콘테스트 마감」의 [삭제]
--
--     지우는 문장은 이 파일에 넣지 않습니다. 2026-11-19 사고가 실행용 파일에
--     남아 있던 delete 두 줄 때문이었기에, 지우는 일은 화면에서 눈으로 보고
--     하시도록 둡니다.
--
--  ★ 이 파일에는 지우는 문장이 하나도 없습니다.
--     delete · truncate · drop table 이 한 줄도 들어 있지 않습니다.
--     밸런스게임 투표 표(polls 등)도 전혀 건드리지 않습니다.
--
--  ★ 여러 번 실행해도 안전합니다.
--     칸은 '없으면 더한다', 바꾸기는 '그 날짜 그 제목일 때만', 넣기는
--     '같은 날짜·제목이 없을 때만' 입니다. 두 번 눌러도 달라지지 않습니다.
--
--  ▷ 하는 방법
--     ① Supabase → 왼쪽 메뉴 'SQL Editor' → 'New query'
--     ② 이 파일 전체를 복사해서 붙여넣기 (Ctrl+A → Ctrl+C → 붙여넣기)
--     ③ 오른쪽 아래 'Run' 단추 (또는 Ctrl+Enter)
--     ④ 맨 아래에 11월 일정이 표로 나오면 다 된 것입니다
--
--  ▷ 잘 됐는지 확인하는 방법
--     홈페이지 → 일정 → 11월 달력. 파란 띠와 분홍 띠가 여러 날에 걸쳐
--     이어져 보이면 성공입니다.
-- ============================================================================


-- ── ① events 표에 칸 두 개 더하기 ───────────────────────────────────────────
--    'if not exists' 라서 이미 있으면 조용히 넘어갑니다.
alter table public.events add column if not exists end_date date;
alter table public.events add column if not exists color    text not null default 'blue';

--    색 이름은 여섯 가지만 받도록 잠가 둡니다 (오타로 엉뚱한 값이 들어가지 않게)
do $$
begin
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.events'::regclass
                    and conname  = 'events_color_check') then
    alter table public.events
      add constraint events_color_check
      check (color in ('blue','green','orange','pink','purple','gray'));
  end if;
end $$;

--    종료일은 시작일보다 앞설 수 없습니다
do $$
begin
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.events'::regclass
                    and conname  = 'events_range_check') then
    alter table public.events
      add constraint events_range_check
      check (end_date is null or end_date >= ev_date);
  end if;
end $$;


-- ── ②③ 캠페인 일정을 기간 일정으로 ─────────────────────────────────────────
do $$
declare
  owner_id   uuid;
  owner_name text;
  fixed      int;
  added      int;

  bg_title text := '「세대가 함께 그리는 조직문화」 밸런스게임';
  og_title text := '출근룩 사진 콘테스트';

  bg_descr text := concat_ws(chr(10),
    '새소리단 8기 3조 세대공감팀이 진행하는 밸런스게임입니다.',
    '',
    '· 참여 기간 : 11. 16.(월) ~ 11. 26.(목)',
    '· 참여 대상 : 고용노동부 전 직원 (연차·직급·새소리단 여부 무관)',
    '· 걸리는 시간 : 약 1분',
    '· 경품 : 한정판 고드래곤&새초롱이 키캡 · 추첨 50명',
    '· 당첨자 발표 : 11월 말 · 개별 연락',
    '',
    '입직 1년 차 신규 직원부터 수십 년 경력의 선배님까지, 세대마다 다른',
    '생각과 일하는 방식을 함께 들여다봅니다. 정답은 없으니 편하고 솔직하게',
    '골라 주세요!',
    '',
    '투표 결과는 카드뉴스로 정리해 우리부 소식과 새소리단 홈페이지에',
    '공유할 예정입니다.');

  og_descr text := concat_ws(chr(10),
    '고용노동부 패셔니스타를 찾아라! 출근룩 사진 콘테스트입니다.',
    '',
    '· 참여 기간 : 11. 23.(월) ~ 11. 30.(월)',
    '· 응모 자격 : 고용노동부 직원이면 누구나',
    '',
    '[참여 방법]',
    '1. 사진을 올리고 — 출근룩 한 장 + 한 줄 소개 (한 사람이 한 장)',
    '2. 마음에 드는 출근룩에 좋아요 (한 사람이 한 장에 한 번)',
    '3. 좋아요 많은 순으로 시상 (순위는 실시간으로 바뀝니다)',
    '',
    '[시상 내역]',
    '1등 10만원 1명 / 2등 5만원 2명 / 3등 3만원 3명',
    '장려상 5천원 10명 / 참가상 키캡 추첨 20명',
    '1~3등·장려상은 상품권, 참가상은 키캡으로 드립니다.');
begin
  -- ② 이미 있는 '시작' 일정을 기간 일정으로 바꿉니다.
  --    그 날짜에 그 제목일 때만 손대므로 다른 일정은 닿지 않습니다.
  update public.events
     set title    = bg_title,
         end_date = date '2026-11-26',
         color    = 'blue',
         descr    = bg_descr
   where ev_date = date '2026-11-16'
     and title   = bg_title || ' 시작';
  get diagnostics fixed = row_count;

  update public.events
     set title    = og_title,
         end_date = date '2026-11-30',
         color    = 'pink',
         descr    = og_descr
   where ev_date = date '2026-11-23'
     and title   = og_title || ' 시작';
  get diagnostics added = row_count;
  fixed := fixed + added;
  raise notice '기간 일정으로 바꾼 것 % 건', fixed;

  -- ③ 바꿀 것이 없었다면(처음 넣는 경우) 새로 넣습니다.
  select p.id, coalesce(nullif(p.name, ''), '새소리단')
    into owner_id, owner_name
    from public.profiles p
   where p.role in ('admin', 'officer', 'member')
   order by case p.role when 'admin' then 1 when 'officer' then 2 else 3 end,
            p.created_at
   limit 1;

  if owner_id is null then
    raise notice '등록자로 쓸 계정이 없어 새로 넣기는 건너뜁니다.';
    return;
  end if;

  insert into public.events (ev_date, end_date, ev_time, title, place, descr, color,
                             author_id, author_name)
  select v.d::date, v.e::date, '', v.title, v.place, v.descr, v.color, owner_id, owner_name
    from (values
      ('2026-11-16', '2026-11-26', bg_title,
       '새소리단 홈페이지 · 밸런스 게임', 'blue',  bg_descr),
      ('2026-11-23', '2026-11-30', og_title,
       '새소리단 홈페이지 · 출근룩 콘테스트', 'pink', og_descr)
    ) as v(d, e, title, place, color, descr)
   where not exists (
     select 1 from public.events x
      where x.ev_date = v.d::date
        and x.title   = v.title);

  get diagnostics added = row_count;
  raise notice '새로 넣은 것 % 건', added;
end $$;


-- ── 확인용 — 11월 일정을 눈으로 봅니다 ──────────────────────────────────────
--    '마감'이라고 적힌 줄 두 개는 이제 필요 없습니다.
--    홈페이지 → 일정 에서 그 날짜를 누르고 [삭제]를 눌러 주세요.
select to_char(ev_date, 'MM. DD.')                      as "시작일",
       coalesce(to_char(end_date, 'MM. DD.'), '(하루)')  as "종료일",
       color                                            as "색",
       title                                            as "행사명",
       author_name                                      as "등록자"
  from public.events
 where ev_date between date '2026-11-01' and date '2026-11-30'
 order by ev_date, title;
