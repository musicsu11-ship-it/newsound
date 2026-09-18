-- ============================================================================
--  새소리단 — 지금 실행해야 하는 SQL  (2026-09-18, 투표 항목 사진)
--
--  ▷ 하는 법
--     1. 이 파일 안을 아무 데나 클릭
--     2. Ctrl + A  (전체 선택)   →   Ctrl + C  (복사)
--     3. Supabase 사이트 → 왼쪽 메뉴 'SQL Editor' → 'New query' 버튼
--     4. 빈 칸에 Ctrl + V  (붙여넣기)   →   오른쪽 아래 'Run' 버튼
--     5. 'Success' 라고 나오면 끝입니다.
--
--  ▷ 이번에는 짧습니다
--     지난번 SQL(13~23절)은 이미 실행되어 있는 것을 확인했습니다.
--     이번에 새로 생긴 24절만 들어 있습니다.
--
--  ▷ 안전한가요?
--     네. 글·사진·투표·가입한 회원은 지우지 않습니다.
--     여러 번 실행해도 같은 결과가 나오게 만들어 두었습니다.
--
--  ▷ 무엇이 바뀌나요?
--     1) 투표 항목마다 사진을 한 장씩 붙일 수 있게 합니다.
--     2) 일반 직원도 투표를 만들 수 있으므로, 가입한 회원이면 '투표 사진'
--        폴더에만 사진을 올릴 수 있게 좁게 열어 둡니다.
--        (영수증·보고서 저장소 docs 는 전혀 건드리지 않습니다)
--     3) 투표를 올린 뒤에는 항목 사진도 바꿀 수 없게 합니다.
--
--     ※ 실행하기 전에는 '투표 만들기' 창에 사진 버튼(📷)이 나오지 않을 뿐,
--       투표는 지금처럼 그대로 쓸 수 있습니다.
--
--  ▷ 이 내용은 supabase/schema.sql 24절과 같습니다.
--     schema.sql 이 원본이고, 이 파일은 복사하기 편하라고 뽑아 둔 것입니다.
-- ============================================================================

-- ============================================================================
--  24. 투표 항목 사진
--
--  · 투표를 만들 때 항목마다 사진을 한 장씩 붙일 수 있습니다(안 붙여도 됩니다).
--  · 사진은 공개 저장소 media 의  polls/<올린 사람 uid>/  폴더에 올라갑니다.
--    투표는 누구나 보는 게시판이라 사진도 공개입니다.
--    (영수증·보고서가 들어 있는 비공개 저장소 docs 와는 완전히 다른 곳입니다)
--  · 일반 직원도 투표를 만들 수 있으므로, 가입한 회원이면 polls 폴더의
--    jpg 사진만 올릴 수 있게 좁게 열어 둡니다. 다른 폴더는 지금처럼 단원 이상만.
--  · 투표를 올린 뒤에는 항목 사진도 바꿀 수 없습니다(투표 도중 사진 바꿔치기 방지).
-- ============================================================================

-- 항목별 사진 경로. 항목 순서와 같고, 사진이 없는 항목은 '' 입니다.
alter table public.polls add column if not exists option_images text[] not null default '{}';

-- 사진 칸 수는 0(사진 없는 투표)이거나 항목 수와 같아야 합니다.
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'polls_option_images_count') then
    alter table public.polls add constraint polls_option_images_count
      check (cardinality(option_images) = 0 or cardinality(option_images) = cardinality(options));
  end if;
end $$;

-- 가입한 회원: media 저장소의  polls/<내 uid>/…jpg  에만 올릴 수 있습니다.
-- (정책이 여러 개면 하나만 맞아도 되므로, 단원의 기존 업로드 권한은 그대로입니다)
drop policy if exists media_write_polls on storage.objects;
create policy media_write_polls on storage.objects for insert
  with check (
    bucket_id = 'media'
    and (storage.foldername(name))[1] = 'polls'
    and public.is_member_account()
    and public.storage_owner(name) = auth.uid()   -- 남의 폴더에 못 올림
    and lower(name) like '%.jpg'
  );

-- 23절의 '올린 뒤에는 못 바꿈' 규칙에 항목 사진을 더합니다.
create or replace function public.guard_poll_update()
returns trigger language plpgsql as $$
begin
  if new.anonymous is distinct from old.anonymous
     or new.options       is distinct from old.options
     or new.option_images is distinct from old.option_images
     or new.multi         is distinct from old.multi
     or (new.author_id is distinct from old.author_id and new.author_id is not null) then
    raise exception '투표를 올린 뒤에는 항목과 익명 여부를 바꿀 수 없습니다';
  end if;
  return new;
end $$;
