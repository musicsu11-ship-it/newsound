-- ============================================================================
--  새소리단 — 지금 실행해야 하는 SQL  (2026-10-22)
--
--  ▷ 하는 법
--     1. 이 파일 안을 아무 데나 클릭
--     2. Ctrl + A  (전체 선택)   →   Ctrl + C  (복사)
--     3. Supabase 사이트 → 왼쪽 메뉴 'SQL Editor' → 'New query' 버튼
--     4. 빈 칸에 Ctrl + V  (붙여넣기)   →   오른쪽 아래 'Run' 버튼
--     5. 'Success' 라고 나오면 끝입니다.
--
--  ▷ 세 가지가 들어 있습니다 (29·30절은 아직 실행 전이라 함께 넣었습니다)
--     29절 — 투표를 올린 뒤에도 고칠 수 있게
--        · 제목·마감은 언제든, 실명 투표는 무기명(익명)으로 바꿀 수 있습니다.
--        · 익명 → 실명은 막습니다. 항목은 아무도 투표하지 않았을 때만 고칩니다.
--        · 이걸 실행해야 지금 올라와 있는 밸런스 게임을 무기명으로 바꿀 수 있습니다.
--     30절 — 라운지 게시판 셋 (고드래곤·새초롱이관 / AI관 / 힘들땐 여기)
--     31절 — 결과보고서를 단원끼리 서로 볼 수 있게
--        · 목록·내용·첨부파일(reports 폴더)을 단원 이상이면 모두 볼 수 있습니다.
--        · 활동비 정산 영수증은 그대로 본인과 혁신행정담당관만 봅니다. ★그대로 보호
--
--  ▷ 안전한가요?
--     네. 글·사진·의견·투표·보고서·가입한 회원은 지우지 않습니다.
--     여러 번 실행해도 같은 결과가 나오게 만들어 두었습니다.
--
--  ▷ 이 내용은 supabase/schema.sql 29~31절과 같습니다.
-- ============================================================================

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
--  30. 새 게시판 셋 — 고드래곤·새초롱이관 / AI관 / 힘들땐 여기
--
--  · mascot : 고드래곤·새초롱이 관련 자체 제작 이미지와 자료를 나누는 곳
--  · ai     : 고용(실업급여·직업능력 등)·노동·산업안전 분야의 AI 꿀팁을 나누는 곳
--             글마다 분야(topic)를 적어 둡니다.
--  · relief : '힘들땐 여기' — 스트레스 해소법과 마음을 나누는 곳(사진·영상·파일 가능)
--
--  읽기는 누구나(일반 직원 포함), 쓰기는 단원 이상입니다. 소식·활동과 같은 규칙입니다.
-- ============================================================================

-- 글의 분야 (AI관에서 씁니다. 다른 게시판 글은 비워 둡니다)
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
