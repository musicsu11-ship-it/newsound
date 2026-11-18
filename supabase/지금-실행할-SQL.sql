-- ============================================================================
--  새소리단 — 지금 실행해야 하는 SQL  (2026-11-19)
--
--  ▷ 하는 법
--     1. 이 파일 안을 아무 데나 클릭
--     2. Ctrl + A  (전체 선택)   →   Ctrl + C  (복사)
--     3. Supabase 사이트 → 왼쪽 메뉴 'SQL Editor' → 'New query' 버튼
--     4. 빈 칸에 Ctrl + V  (붙여넣기)   →   오른쪽 아래 'Run' 버튼
--     5. 'Success' 라고 나오면 끝입니다.
--
--  ▷ 이번에는 41·43·44·45절입니다 (40절까지는 이미 들어가 있습니다)
--
--     ※ 42절(투표 표 비우기)은 이 파일에서 뺐습니다. 다시 실행해도
--        쌓인 표가 지워지지 않습니다.
--
--     41절 — 이벤트 응모에 '이름' 과 '개인정보 제공 동의' 를 더합니다
--
--     43절 — 출근룩 콘테스트, 한 사람이 한 장만
--            · 같은 계정(같은 브라우저)으로 두 번째 사진을 올릴 수 없습니다
--            · 이름·소속이 똑같은 사진이 이미 있으면 그것도 막습니다
--              (다른 기기에서 올려 계정이 달라지는 경우를 잡기 위함)
--            · 이미 올라와 있는 사진은 지우지 않습니다 — 새로 올릴 때만 확인
--            · 수정·삭제는 그대로 됩니다
--
--     44절 — 우리 지청 맛집에 '가게 정보' 칸을 더합니다
--            · 분류·별점·위치·대표 메뉴·가격대를 따로 담습니다
--            · 칸 하나만 더하고, 지우는 것은 없습니다
--
--     45절 — 새소리단 소식도 '누구나' 올릴 수 있게
--            · 방문자가 볼 수 있는 게시판은 이제 모두 글을 쓸 수 있습니다
--            · 새소리단 전용 공간(공지사항·자유방·활동·협업·공간)은 그대로입니다
--
--  ▷ 안전한가요?
--     네. 이 파일에는 '지우는 문장(delete)' 이 하나도 없습니다.
--     칸을 더하고 권한을 여는 것뿐이라, 여러 번 실행해도 안전합니다.
--
--  ▷ 이 내용은 supabase/schema.sql 41·43·44·45절과 같습니다.
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

-- ============================================================================
--  44. 우리 지청 맛집 — 가게 정보 칸 (네이버 플레이스처럼)
--
--  맛집 글에 가게 정보를 따로 담습니다. 글 본문(한 줄 평)과 섞이지 않아
--  목록에서 분류·별점·위치를 바로 보여 줄 수 있습니다.
--
--    place = {
--      "cat"   : "한식",                 -- 분류
--      "star"  : 4,                      -- 별점 1~5
--      "loc"   : "지청 정문 건너편, 도보 5분",
--      "menu"  : "김치찌개 9,000원",
--      "price" : "1만원 미만"            -- 가격대
--    }
--
--  · 맛집 게시판에서만 씁니다. 다른 게시판 글은 비어 있습니다.
--  · 지우는 것은 없습니다. 칸 하나만 더합니다.
-- ============================================================================

alter table public.posts add column if not exists place jsonb;

-- ============================================================================
--  45. 새소리단 소식도 '누구나' 올릴 수 있게
--
--  홈페이지에 들어온 사람이면 로그인 없이도 소식을 올릴 수 있습니다.
--  이제 방문자가 볼 수 있는 게시판은 모두 글을 쓸 수 있습니다.
--    · 열린 곳 : 소식 · 출근룩 콘테스트 · 고드래곤&새초롱이 · AI.zip ·
--                멘탈관리.zip · 우리 지청 맛집   (댓글도 함께)
--    · 그대로 : 공지사항(담당관) · 자유방 · 활동 · 협업 · 새소리단 공간
--               — 새소리단 전용 공간이라 단원만 보고 씁니다
--    · 투표·밸런스 게임 '만들기' 도 그대로 로그인 회원만입니다
--
--  장난 글은 혁신행정담당관이 바로 내릴 수 있습니다(40절과 같은 방식). ★정리
-- ============================================================================

-- 올리기
drop policy if exists posts_insert on public.posts;
create policy posts_insert on public.posts for insert
  with check (
    author_id = auth.uid()
    and case
          when board in ('news','ootd','mascot','ai','relief','food') then auth.uid() is not null
          when board = 'notice' then public.is_officer()
          else public.is_inner()
        end
  );

-- 지우기 — 올린 본인·관리자에 더해, 열린 게시판은 담당관도
drop policy if exists posts_delete on public.posts;
create policy posts_delete on public.posts for delete
  using (
    author_id = auth.uid()
    or public.is_admin()
    or (board in ('news','ootd','mascot','ai','relief','food') and public.is_officer())
  );

-- 댓글
drop policy if exists pc_insert on public.post_comments;
create policy pc_insert on public.post_comments for insert
  with check (
    author_id = auth.uid()
    and (
      public.is_inner()
      or exists (select 1 from public.posts p
                  where p.id = post_id
                    and p.board in ('news','ootd','mascot','ai','relief','food'))
    )
  );

drop policy if exists pc_delete on public.post_comments;
create policy pc_delete on public.post_comments for delete
  using (
    author_id = auth.uid()
    or public.is_admin()
    or (public.is_officer() and exists (
          select 1 from public.posts p
           where p.id = post_id
             and p.board in ('news','ootd','mascot','ai','relief','food')))
  );

-- 사진·파일 올리기 / 내리기
drop policy if exists media_write on storage.objects;
create policy media_write on storage.objects for insert
  with check (
    bucket_id = 'media'
    and public.storage_owner(name) = auth.uid()
    and (
      public.is_inner()
      or (storage.foldername(name))[1] in ('news','ootd','mascot','ai','relief','food')
    )
  );

drop policy if exists media_delete on storage.objects;
create policy media_delete on storage.objects for delete
  using (
    bucket_id = 'media'
    and (
      public.storage_owner(name) = auth.uid()
      or public.is_admin()
      or ((storage.foldername(name))[1] in ('news','ootd','mascot','ai','relief','food')
          and public.is_officer())
    )
  );

