-- ============================================================================
--  새소리단 — 지금 실행해야 하는 SQL  (2026-09-18)
--
--  ▷ 하는 법
--     1. 이 파일 안을 아무 데나 클릭
--     2. Ctrl + A  (전체 선택)   →   Ctrl + C  (복사)
--     3. Supabase 사이트 → 왼쪽 메뉴 'SQL Editor' → 'New query' 버튼
--     4. 빈 칸에 Ctrl + V  (붙여넣기)   →   오른쪽 아래 'Run' 버튼
--     5. 'Success' 라고 나오면 끝입니다.
--
--  ▷ 안전한가요?
--     네. 글·사진·가입한 회원은 지우지 않습니다.
--     여러 번 실행해도 같은 결과가 나오게 만들어 두었습니다.
--     이미 실행하신 부분이 섞여 있어도 그냥 넘어갑니다.
--
--  ▷ 무엇이 바뀌나요?
--     1) 게시글 작성자의 팀·부서, 정산의 팀을 저장할 칸을 만듭니다.
--     2) 익명 별칭이 사람마다 다르게 나오도록 고칩니다.
--     3) 로그인 없이 둘러본 익명 접속이 '회원 · 권한 관리' 명부에
--        쌓이지 않게 합니다. 이미 쌓인 것도 정리합니다.
--     4) 의견에 '공감해요' 를 추가합니다.
--     5) 댓글에도 '공감해요' 를 추가합니다.
--     6) 정산 신청의 입금 계좌를 은행명·계좌번호·예금주 세 칸으로 나눕니다.
--     7) 댓글에 대댓글(답글)을 달 수 있게 합니다.
--     8) '활동' 게시판을 만들고 일반 직원도 읽을 수 있게 엽니다.
--     9) '활동' 게시판을 1~6팀 게시판으로 나눕니다.
--    10) 운영 관리자가 회원을 삭제할 수 있게 합니다.
--        계정만 지우고, 그 사람이 쓴 글·보고서·정산 기록은 남깁니다.
--    11) 투표 게시판을 만듭니다(익명/실명 선택, 한 사람 한 표).
--
--  ▷ 이 내용은 supabase/schema.sql 13~23절과 같습니다.
--     schema.sql 이 원본이고, 이 파일은 복사하기 편하라고 뽑아 둔 것입니다.
-- ============================================================================

-- ============================================================================
--  13. 추가 컬럼 (나중에 붙인 기능들)
--      이미 있으면 그냥 넘어가므로 몇 번을 다시 실행해도 안전합니다.
-- ============================================================================

-- 정산 신청: 소속 팀 (결제수단은 더 이상 입력받지 않습니다)
alter table public.expenses add column if not exists team text default '';

-- 게시글 작성자 표기: 팀 또는 "혁신행정담당관", 그리고 소속청·부서
alter table public.posts add column if not exists author_team text default '';
alter table public.posts add column if not exists author_dept text default '';

-- ============================================================================
--  14. 익명 별칭 바로잡기
--
--  증상 : 서로 다른 사람이 똑같이 '새소리16' 을 받았습니다.
--
--  원인이 둘 있었고, 둘 다 같은 증상을 만듭니다.
--
--  (가) 사무실이 같으면 밖에서 보이는 IP 도 하나입니다.
--       지금까지는 '접속 IP' 로 사람을 구분했습니다. 그런데 같은 청·과에서
--       접속하면 IP 가 하나로 묶여 그 사무실 전체가 한 사람이 됩니다.
--       반대로 한 사람이 사무실에서 쓰다가 휴대폰 데이터로 옮기면 IP 가 바뀌어
--       다른 번호를 받습니다. IP 로는 사람을 제대로 나눌 수 없습니다.
--
--       -> 이 사이트는 처음 들어온 사람에게도 익명 계정을 자동으로 만들어 주고
--          그 계정이 브라우저에 그대로 남습니다. 그래서 '접속 계정' 을 기준으로
--          바꿉니다. 계정이 없을 때만 예전처럼 IP 를 씁니다.
--
--  (나) 번호를 '지금까지 최대 번호 + 1' 로 뽑고 있었습니다.
--       두 사람이 거의 동시에 처음 들어오면 둘 다 최대값을 15 로 읽고
--       둘 다 16 번을 가져갑니다. 번호에 중복 금지가 없어 그대로 저장됩니다.
--
--       -> 번호를 시퀀스에서 뽑고 번호 자체에 중복 금지를 겁니다.
--          시퀀스는 동시에 불러도 같은 값을 두 번 주지 않습니다.
--
--  방문자 수 집계는 예전처럼 IP 기준으로 둡니다(별칭과 목적이 다릅니다).
--  이 절은 여러 번 다시 실행해도 안전합니다.
-- ============================================================================

-- 별칭 번호 발급기. 동시에 여러 명이 요청해도 같은 번호가 나오지 않습니다.
create sequence if not exists public.alias_seq;

-- 별칭 명부. 방문자 집계용 ip_alias 와 목적이 달라 표를 나눴습니다.
--   key_hash : 누구인지 가린 값(계정 id 또는 IP 를 되돌릴 수 없게 해시한 것)
--   n        : 별칭 번호. unique 라 두 사람이 같은 번호를 가질 수 없습니다.
create table if not exists public.alias_no (
  key_hash   text primary key,
  n          int  not null unique,
  created_at timestamptz not null default now()
);
alter table public.alias_no enable row level security;
-- 클라이언트는 이 표를 직접 읽거나 쓸 수 없습니다. 아래 함수로만 접근합니다.

-- 별칭 기준 신원 — 계정을 먼저 보고, 계정이 없을 때만 IP 를 봅니다.
create or replace function public.alias_hash()
returns text language sql stable security definer set search_path = public, extensions as $$
  select encode(extensions.digest(
    coalesce(auth.uid()::text, public.client_ip(), 'unknown') || '::saesori-alias', 'sha256'), 'hex')
$$;

-- 번호 발급. 처음 보는 사람이면 시퀀스에서 새 번호를 꺼내 줍니다.
create or replace function public.alias_n(h text)
returns int language plpgsql security definer set search_path = public as $$
declare num int;
begin
  select n into num from public.alias_no where key_hash = h;
  if num is null then
    insert into public.alias_no(key_hash, n) values (h, nextval('public.alias_seq'))
    on conflict (key_hash) do nothing;
    select n into num from public.alias_no where key_hash = h;
  end if;
  return num;
end $$;

-- 이미 쓰인 번호 다음부터 발급되도록 시작점을 맞춥니다.
-- 옛 글의 '새소리16' 과 새로 들어온 사람의 번호가 겹치면 안 되기 때문입니다.
-- setval 은 0 을 받지 못하므로 '최대값 + 1, 아직 안 쓴 상태' 로 지정합니다.
do $$
declare m int; cur bigint;
begin
  select greatest(
    coalesce((select max(n) from public.alias_no), 0),
    coalesce((select max(n) from public.ip_alias), 0),
    coalesce((select max(nullif(regexp_replace(alias, '[^0-9]', '', 'g'), ''))::int
                from public.opinions), 0),
    coalesce((select max(nullif(regexp_replace(alias, '[^0-9]', '', 'g'), ''))::int
                from public.opinion_comments), 0)
  ) into m;
  -- 이미 더 앞서 있으면 되돌리지 않습니다(다시 실행해도 번호가 되감기지 않게)
  select last_value into cur from public.alias_seq;
  if cur < m + 1 then
    perform setval('public.alias_seq', m + 1, false);
  end if;
end $$;

-- 별칭 만들기 — 앞으로 올라오는 글은 이 함수로 이름이 붙습니다.
create or replace function public.my_alias()
returns text language plpgsql security definer set search_path = public as $$
begin
  return '새소리' || public.alias_n(public.alias_hash());
end $$;
grant execute on function public.my_alias() to anon, authenticated;

-- 이미 올라온 글·댓글의 별칭도 계정 기준으로 다시 매깁니다.
-- 같은 사람이 쓴 글은 같은 번호로, 다른 사람이 쓴 글은 다른 번호로 갈라집니다.
-- author_id 가 비어 있는 글은 누가 썼는지 알 수 없으므로 손대지 않습니다.
do $$
declare uid uuid; h text; num int;
begin
  for uid in
    select author_id from public.opinions where author_id is not null
    union
    select author_id from public.opinion_comments where author_id is not null
  loop
    h   := encode(extensions.digest(uid::text || '::saesori-alias', 'sha256'), 'hex');
    num := public.alias_n(h);
    update public.opinions         set alias = '새소리' || num where author_id = uid;
    update public.opinion_comments set alias = '새소리' || num where author_id = uid;
  end loop;
end $$;

-- 예전 IP 명부에 남아 있던 중복 번호도 정리합니다(방문자 수에는 영향 없음).
-- 같은 번호를 가진 행 중 먼저 만들어진 것만 남기고 나머지에 새 번호를 줍니다.
-- 고칠 대상을 먼저 배열에 담아 둡니다 — 훑는 도중에 같은 표를 고치면
-- 어디까지 봤는지가 흔들릴 수 있기 때문입니다.
do $$
declare dup text[]; k text;
begin
  select coalesce(array_agg(a.ip_hash), '{}'::text[])
    into dup
    from public.ip_alias a
   where exists (select 1 from public.ip_alias b
                  where b.n = a.n and b.ip_hash <> a.ip_hash
                    and (b.created_at, b.ip_hash) < (a.created_at, a.ip_hash));
  foreach k in array dup loop
    update public.ip_alias set n = nextval('public.alias_seq') where ip_hash = k;
  end loop;
end $$;

-- 중복 금지를 겁니다. 혹시 위에서 못 잡은 중복이 남아 있어도 이 한 줄 때문에
-- schema.sql 전체가 되돌아가면 곤란하므로, 실패하면 알림만 남기고 넘어갑니다.
-- (별칭은 아래 alias_no 표에서 나오므로 이 인덱스가 없어도 별칭은 안 겹칩니다)
do $$
begin
  create unique index if not exists ip_alias_n_key on public.ip_alias(n);
exception when others then
  raise notice 'ip_alias 번호에 중복이 남아 있어 중복 금지를 걸지 못했습니다: %', sqlerrm;
end $$;

-- 방문자 집계용 번호 발급도 시퀀스로 바꿔 같은 번호가 두 번 나오지 않게 합니다.
create or replace function public.visitor_no(h text)
returns int language plpgsql security definer set search_path = public as $$
declare num int;
begin
  select n into num from public.ip_alias where ip_hash = h;
  if num is null then
    insert into public.ip_alias(ip_hash, n) values (h, nextval('public.alias_seq'))
    on conflict (ip_hash) do nothing;
    select n into num from public.ip_alias where ip_hash = h;
  end if;
  return num;
end $$;

-- ---------------------------------------------------------------------------
--  점검용 — 실행 후 확인해 보고 싶을 때 아래를 SQL Editor 에 따로 붙여 넣으세요.
--
--  -- 같은 번호를 두 사람이 쓰고 있는지 (0줄이면 정상)
--  select n, count(*) from public.alias_no group by n having count(*) > 1;
--
--  -- 지금 의견함에 붙어 있는 별칭 (서로 다른 사람이면 번호가 달라야 합니다)
--  select alias, author_id, created_at from public.opinions order by created_at;
-- ---------------------------------------------------------------------------

-- ============================================================================
--  15. 익명 접속은 회원 명부에 넣지 않기
--
--  이 사이트는 로그인하지 않은 사람에게도 익명 계정을 자동으로 만들어 줍니다
--  (글을 못 써도 화면은 볼 수 있어야 하고, 의견함 별칭도 그 계정으로 나눕니다).
--  그런데 auth.users 에 한 줄 생길 때마다 profiles 에도 한 줄이 생기다 보니,
--  관리자 콘솔 '회원 · 권한 관리' 명부가 이름 없는 익명 접속으로 가득 찹니다.
--
--  -> 앞으로는 익명 계정이면 profiles 를 만들지 않습니다.
--     화면 쪽은 이미 프로필이 없어도 '방문자' 로 처리하게 되어 있어 문제없습니다.
--     이미 쌓여 있던 익명 프로필도 아래에서 지웁니다.
--
--  지우는 대상은 세 조건을 모두 만족하는 행뿐입니다.
--    · 권한이 '일반 방문자' 이고           (단원·담당관·관리자는 절대 안 지웁니다)
--    · 이름이 비어 있고                    (가입할 때 이름은 필수라 가입자는 이름이 있습니다)
--    · auth.users 에서 익명으로 표시된 계정
--  profiles 를 참조하는 다른 표가 없어서 지워도 다른 자료는 그대로입니다.
-- ============================================================================

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  -- 익명 계정이면 회원 명부에 넣지 않습니다.
  -- to_jsonb 로 꺼내는 이유: is_anonymous 칸이 없는 예전 프로젝트에서도 오류가 안 나게.
  if coalesce((to_jsonb(new) ->> 'is_anonymous')::boolean, false) then
    return new;
  end if;

  insert into public.profiles (id, name)
  values (new.id, coalesce(new.raw_user_meta_data->>'name', ''))
  on conflict (id) do nothing;
  return new;
end $$;

-- 이미 쌓여 있던 익명 프로필 정리
delete from public.profiles p
 where p.role = 'visitor'
   and coalesce(p.name, '') = ''
   and exists (
     select 1 from auth.users u
      where u.id = p.id
        and coalesce((to_jsonb(u) ->> 'is_anonymous')::boolean, false)
   );

-- ============================================================================
--  16. 의견함 '공감해요'
--
--  한 계정이 한 의견에 한 번만 누를 수 있습니다(다시 누르면 취소).
--  기본키가 (의견, 사람) 이라 같은 사람이 두 번 저장되는 것 자체가 막힙니다.
--
--  누가 눌렀는지는 남에게 보이지 않게 했습니다.
--  의견함이 익명인데 '누가 어디에 공감했는지' 가 보이면 익명이 아니게 됩니다.
--    · 공감 표는 '내가 누른 것' 만 읽을 수 있습니다 (하트를 칠할지 판단용)
--    · 전체 개수는 opinions.likes 칸에 숫자로만 쌓아 두고 그걸 보여 줍니다
-- ============================================================================

alter table public.opinions add column if not exists likes int not null default 0;

create table if not exists public.opinion_likes (
  opinion_id uuid not null references public.opinions on delete cascade,
  user_id    uuid not null default auth.uid() references auth.users on delete cascade,
  created_at timestamptz not null default now(),
  primary key (opinion_id, user_id)          -- 한 사람이 한 의견에 한 번만
);
alter table public.opinion_likes enable row level security;

drop policy if exists oplike_select on public.opinion_likes;
create policy oplike_select on public.opinion_likes for select
  using ( user_id = auth.uid() );            -- 내가 누른 것만 보입니다

drop policy if exists oplike_insert on public.opinion_likes;
create policy oplike_insert on public.opinion_likes for insert
  with check ( user_id = auth.uid() );

drop policy if exists oplike_delete on public.opinion_likes;
create policy oplike_delete on public.opinion_likes for delete
  using ( user_id = auth.uid() );            -- 자기가 누른 것만 취소

-- 공감 개수를 opinions.likes 에 반영합니다.
-- security definer 로 두어 공감 표를 못 읽는 사람도 개수는 정확히 쌓이게 합니다.
create or replace function public.bump_like()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    update public.opinions set likes = likes + 1 where id = new.opinion_id;
    return new;
  else
    update public.opinions set likes = greatest(likes - 1, 0) where id = old.opinion_id;
    return old;
  end if;
end $$;

drop trigger if exists opinion_likes_bump on public.opinion_likes;
create trigger opinion_likes_bump
  after insert or delete on public.opinion_likes
  for each row execute function public.bump_like();

-- 이미 눌린 공감이 있다면 개수를 다시 세어 맞춥니다(다시 실행해도 안전).
update public.opinions o
   set likes = (select count(*) from public.opinion_likes l where l.opinion_id = o.id);

-- ============================================================================
--  17. 댓글에도 '공감해요'
--      16절 의견 공감과 똑같은 방식입니다.
--      한 계정이 한 댓글에 한 번만, 누가 눌렀는지는 남에게 보이지 않습니다.
-- ============================================================================

alter table public.opinion_comments add column if not exists likes int not null default 0;

create table if not exists public.comment_likes (
  comment_id uuid not null references public.opinion_comments on delete cascade,
  user_id    uuid not null default auth.uid() references auth.users on delete cascade,
  created_at timestamptz not null default now(),
  primary key (comment_id, user_id)          -- 한 사람이 한 댓글에 한 번만
);
alter table public.comment_likes enable row level security;

drop policy if exists cmtlike_select on public.comment_likes;
create policy cmtlike_select on public.comment_likes for select
  using ( user_id = auth.uid() );            -- 내가 누른 것만 보입니다

drop policy if exists cmtlike_insert on public.comment_likes;
create policy cmtlike_insert on public.comment_likes for insert
  with check ( user_id = auth.uid() );

drop policy if exists cmtlike_delete on public.comment_likes;
create policy cmtlike_delete on public.comment_likes for delete
  using ( user_id = auth.uid() );

create or replace function public.bump_comment_like()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    update public.opinion_comments set likes = likes + 1 where id = new.comment_id;
    return new;
  else
    update public.opinion_comments set likes = greatest(likes - 1, 0) where id = old.comment_id;
    return old;
  end if;
end $$;

drop trigger if exists comment_likes_bump on public.comment_likes;
create trigger comment_likes_bump
  after insert or delete on public.comment_likes
  for each row execute function public.bump_comment_like();

-- 개수를 다시 세어 맞춥니다(다시 실행해도 안전).
update public.opinion_comments c
   set likes = (select count(*) from public.comment_likes l where l.comment_id = c.id);

-- ============================================================================
--  18. 정산 입금 계좌를 칸 세 개로
--
--  전에는 bank 칸 하나에 "은행 / 계좌번호 / 예금주" 를 몰아 적었습니다.
--  담당관이 그 값을 보고 그대로 이체하는데, 한 줄에 붙어 있으면
--  계좌번호만 골라 복사하기가 번거롭습니다.
--
--  이제 bank 는 은행명만 담고, 계좌번호와 예금주는 새 칸에 따로 담습니다.
--  칸을 나누기 전에 올라온 신청서는 bank 에 다 적혀 있는데,
--  화면에서는 적힌 그대로 보여 주므로 옛 신청서도 그대로 읽힙니다.
-- ============================================================================

alter table public.expenses add column if not exists acct_no text default '';
alter table public.expenses add column if not exists holder  text default '';

-- ============================================================================
--  19. 댓글에 대댓글(답글)
--
--  댓글 표에 '어느 댓글에 달린 답글인지' 를 적는 칸 하나만 더합니다.
--  비어 있으면 원래 댓글, 값이 있으면 그 댓글에 달린 답글입니다.
--  원래 댓글을 지우면 거기 달린 답글도 함께 지워집니다(on delete cascade).
--
--  답글도 결국 같은 표의 댓글이라, 16·17절에서 만든 공감 기능이 그대로 됩니다.
--  별칭을 붙이는 방식도 기존 댓글과 같습니다.
-- ============================================================================

alter table public.opinion_comments
  add column if not exists parent_id uuid references public.opinion_comments(id) on delete cascade;

create index if not exists opinion_comments_parent_idx
  on public.opinion_comments (parent_id, created_at);

-- ============================================================================
--  20. '활동' 게시판 — 일반 직원(방문자)도 읽을 수 있게
--
--  게시판을 늘리려면 두 군데를 같이 풀어야 합니다.
--    ① 게시판 이름 목록 : posts.board 에 들어갈 수 있는 값이 정해져 있어서,
--                        'activity' 를 넣지 않으면 글 저장 자체가 거절됩니다.
--    ② 읽기 권한        : 지금까지는 '소식' 만 누구나 읽고 나머지는 단원 이상만
--                        읽을 수 있었습니다. '활동' 도 누구나 읽게 엽니다.
--  글쓰기 권한은 그대로입니다. 공지방은 담당관 이상, 나머지(활동 포함)는 단원 이상.
-- ============================================================================

-- ① 게시판 이름 목록 다시 걸기
--    원래 규칙의 이름을 몰라도 되도록, posts 에 걸린 규칙 중 board 를 검사하는
--    것을 찾아 지우고 새로 겁니다. 다시 실행해도 같은 결과가 됩니다.
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
  check (board in ('news','notice','free','share','activity'));

-- ② 읽기 권한 — 소식과 활동은 누구나, 나머지는 단원 이상
drop policy if exists posts_select on public.posts;
create policy posts_select on public.posts for select
  using ( board in ('news','activity') or public.is_inner() );

-- ============================================================================
--  21. '활동' 게시판을 1~6팀 게시판으로 나누기
--
--  글마다 '몇 팀 게시판에 올린 글인지' 를 번호로 적는 칸을 더합니다.
--  팀 순서는 소개 페이지에 등록된 팀 순서와 같습니다(1팀 = 첫 번째 팀).
--
--  이름이 아니라 번호로 적는 이유: 소개 페이지에서 팀 이름을 고쳐도
--  이미 쓴 글이 엉뚱한 팀으로 가거나 어느 팀에도 안 보이게 되는 일이 없습니다.
--  활동 게시판이 아닌 글은 이 칸을 비워 둡니다.
-- ============================================================================

alter table public.posts add column if not exists team_no int;
create index if not exists posts_activity_team_idx
  on public.posts (team_no, created_at desc) where board = 'activity';

-- ============================================================================
--  22. 회원 삭제 (운영 관리자만) — 계정만 지우고 그 사람이 남긴 기록은 보존
--
--  지금까지는 계정을 지우면 그 사람이 쓴 게시글·의견·댓글·일정·결과보고서·
--  활동비 정산이 전부 함께 지워지게 걸려 있었습니다(on delete cascade).
--  정산·보고서처럼 나중에 확인해야 하는 기록이 사라지면 안 되므로 바꿉니다.
--
--  ① 기록을 담는 표 6개의 author_id 를 '계정이 지워지면 비워 두기'
--     (on delete set null) 로 바꿉니다. 글에는 작성자 이름(author_name)이
--     따로 적혀 있어서 계정이 없어져도 누가 썼는지는 그대로 보입니다.
--     주인이 없어진 글은 담당관·관리자만 고치거나 지울 수 있습니다.
--  ② 운영 관리자만 부를 수 있는 삭제 함수를 만듭니다.
--     브라우저에는 계정 삭제 권한(서비스 키)을 절대 두지 않고, 데이터베이스
--     안에서 '부른 사람이 운영 관리자인지' 를 확인한 뒤에만 지웁니다.
--
--  공감(좋아요) 기록은 그대로 함께 지워집니다 — 그만큼 공감 수가 1씩 줄어듭니다.
--  위쪽 create table 들에는 옛 규칙(not null, cascade)이 적혀 있지만,
--  이 절이 뒤에 실행되며 덮어씁니다.
-- ============================================================================

-- ① 기록 보존으로 바꾸기
do $$
declare t text; c record;
begin
  foreach t in array array['posts','opinions','opinion_comments','reports','expenses','events'] loop
    -- 계정이 지워지면 비워 둘 수 있게 '반드시 채움' 을 풉니다
    execute format('alter table public.%I alter column author_id drop not null', t);
    -- 이 표에서 auth.users 를 가리키는 규칙을 찾아 지우고
    for c in
      select conname from pg_constraint
       where conrelid  = format('public.%I', t)::regclass
         and contype   = 'f'
         and confrelid = 'auth.users'::regclass
    loop
      execute format('alter table public.%I drop constraint %I', t, c.conname);
    end loop;
    -- '계정이 지워지면 비워 두기' 로 다시 겁니다
    execute format(
      'alter table public.%I add constraint %I foreign key (author_id) references auth.users(id) on delete set null',
      t, t || '_author_id_fkey');
  end loop;
end $$;

-- ② 회원 삭제 함수 — 운영 관리자만, 자기 자신은 못 지움
create or replace function public.admin_delete_user(target uuid)
returns text language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin()   then return 'forbidden'; end if;   -- 운영 관리자만
  if target is null          then return 'no-target'; end if;
  if target = auth.uid()     then return 'self';      end if;   -- 본인 삭제 금지(관리자가 0명이 되는 것 방지)

  -- 안전장치: 기록을 담는 표 중에 아직 '계정과 함께 지우기' 로 걸린 곳이 하나라도 있으면
  -- 지우지 않습니다. ① 이 어떤 이유로든 반영되지 않았을 때 기록이 날아가는 일을 막습니다.
  if exists (
    select 1 from pg_constraint
     where contype = 'f'
       and confrelid = 'auth.users'::regclass
       and confdeltype = 'c'                                 -- c = cascade
       and conrelid in ('public.posts'::regclass, 'public.opinions'::regclass,
                        'public.opinion_comments'::regclass, 'public.reports'::regclass,
                        'public.expenses'::regclass, 'public.events'::regclass)
  ) then
    return 'records-not-protected';
  end if;

  delete from auth.users where id = target;
  if not found then return 'not-found'; end if;
  return 'ok';
exception when others then
  return 'error: ' || sqlerrm;
end $$;

revoke all on function public.admin_delete_user(uuid) from public, anon;
grant execute on function public.admin_delete_user(uuid) to authenticated;

-- ============================================================================
--  23. 투표 게시판 (카카오톡 투표처럼)
--
--  · 누구나 볼 수 있습니다.
--  · 투표 만들기: 가입해서 로그인한 사람 (일반 직원·단원 모두). 익명 방문자는
--    만들 수 없습니다(아무나 마구 만드는 것을 막기 위해).
--  · 투표 하기  : 익명 투표는 누구나(로그인 안 해도), 실명 투표는 로그인한 사람만.
--  · 한 사람 한 표. 마감 전에는 다시 투표해서 고를 수 있습니다.
--
--  익명 투표는 '누가 무엇을 골랐는지' 를 투표한 본인 말고는 아무도 볼 수 없습니다.
--  관리자도 화면에서는 볼 수 없고, 사람들에게는 항목별 표 수만 보여 줍니다.
--  실명 투표는 투표할 때 서버가 계정의 이름을 붙이므로 이름을 꾸며 넣을 수 없습니다.
--
--  회원이 삭제되면 그 사람이 올린 투표는 남고(작성자 이름 그대로), 그 사람이 던진
--  표는 함께 지워져 표 수가 그만큼 줄어듭니다(공감과 같은 방식).
-- ============================================================================

create table if not exists public.polls (
  id          uuid primary key default gen_random_uuid(),
  title       text not null,
  options     text[] not null,                     -- 항목들 (2~10개)
  multi       boolean not null default false,      -- 복수 선택
  anonymous   boolean not null default true,       -- 익명 투표 (끄면 실명)
  closes_at   timestamptz,                         -- 마감 시각 (비우면 직접 마감할 때까지)
  closed      boolean not null default false,      -- 만든 사람이 직접 마감
  author_id   uuid default auth.uid() references auth.users on delete set null,
  author_name text not null default '',
  created_at  timestamptz not null default now(),
  constraint polls_options_count check (array_length(options, 1) between 2 and 10)
);
create index if not exists polls_created_idx on public.polls (created_at desc);

create table if not exists public.poll_ballots (
  poll_id    uuid not null references public.polls on delete cascade,
  user_id    uuid not null default auth.uid() references auth.users on delete cascade,
  choices    int[] not null,                       -- 고른 항목 번호 (0부터)
  voter_name text not null default '',             -- 실명 투표일 때만 서버가 채움
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (poll_id, user_id)                   -- 한 사람 한 표
);

alter table public.polls        enable row level security;
alter table public.poll_ballots enable row level security;

-- 가입한 계정인가? (익명 방문자 계정이 아닌가)
create or replace function public.is_member_account()
returns boolean language sql stable as $$
  select auth.uid() is not null
     and not coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false)
$$;

drop policy if exists polls_select on public.polls;
create policy polls_select on public.polls for select using ( true );

drop policy if exists polls_insert on public.polls;
create policy polls_insert on public.polls for insert
  with check ( public.is_member_account() and author_id = auth.uid() );

drop policy if exists polls_update on public.polls;            -- 마감하기
create policy polls_update on public.polls for update
  using ( author_id = auth.uid() or public.is_admin() );

drop policy if exists polls_delete on public.polls;
create policy polls_delete on public.polls for delete
  using ( author_id = auth.uid() or public.is_admin() );

-- 표: 내 표는 언제나, 실명 투표의 표는 모두에게 보입니다(누가 뭘 골랐는지 보여 주려고).
--     익명 투표의 남의 표는 아무도 못 봅니다.
drop policy if exists ballots_select on public.poll_ballots;
create policy ballots_select on public.poll_ballots for select
  using ( user_id = auth.uid()
          or exists (select 1 from public.polls p where p.id = poll_id and not p.anonymous) );

drop policy if exists ballots_insert on public.poll_ballots;
create policy ballots_insert on public.poll_ballots for insert with check ( user_id = auth.uid() );

drop policy if exists ballots_update on public.poll_ballots;
create policy ballots_update on public.poll_ballots for update using ( user_id = auth.uid() );

drop policy if exists ballots_delete on public.poll_ballots;
create policy ballots_delete on public.poll_ballots for delete using ( user_id = auth.uid() );

-- 표를 넣거나 바꿀 때 서버에서 확인합니다 (화면을 거치지 않고 보내도 똑같이 막힙니다)
create or replace function public.check_ballot()
returns trigger language plpgsql security definer set search_path = public as $$
declare p public.polls; n int; nm text;
begin
  select * into p from public.polls where id = new.poll_id;
  if not found then raise exception '없는 투표입니다'; end if;
  if p.closed or (p.closes_at is not null and p.closes_at <= now()) then
    raise exception '마감된 투표입니다';
  end if;

  n := array_length(p.options, 1);
  if new.choices is null or coalesce(array_length(new.choices, 1), 0) = 0 then
    raise exception '항목을 하나 이상 골라 주세요';
  end if;
  if (select count(*) from unnest(new.choices) c where c < 0 or c >= n) > 0 then
    raise exception '없는 항목이 들어 있습니다';
  end if;
  if (select count(distinct c) from unnest(new.choices) c) <> array_length(new.choices, 1) then
    raise exception '같은 항목을 두 번 고를 수 없습니다';
  end if;
  if not p.multi and array_length(new.choices, 1) <> 1 then
    raise exception '이 투표는 하나만 고를 수 있습니다';
  end if;

  if p.anonymous then
    new.voter_name := '';                           -- 익명 투표는 이름을 아예 남기지 않습니다
  else
    if not public.is_member_account() then
      raise exception '실명 투표는 로그인한 회원만 참여할 수 있습니다';
    end if;
    select name into nm from public.profiles where id = auth.uid();
    if coalesce(trim(nm), '') = '' then
      raise exception '이름이 등록된 계정만 실명 투표에 참여할 수 있습니다';
    end if;
    new.voter_name := trim(nm);                     -- 이름은 서버가 붙입니다(꾸밀 수 없음)
  end if;

  new.user_id    := auth.uid();
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists poll_ballots_check on public.poll_ballots;
create trigger poll_ballots_check before insert or update on public.poll_ballots
  for each row execute function public.check_ballot();

-- 결과 — 항목별 표 수와 참여 인원만 돌려줍니다(익명 투표도 이 숫자는 모두에게 공개)
create or replace function public.poll_results()
returns table(poll_id uuid, tally int[], voters int)
language sql stable security definer set search_path = public as $$
  select p.id,
         array(select (select count(*) from public.poll_ballots b
                        where b.poll_id = p.id and (i - 1) = any(b.choices))::int
                 from generate_series(1, array_length(p.options, 1)) i
                order by i),
         (select count(*)::int from public.poll_ballots b where b.poll_id = p.id)
    from public.polls p
$$;
grant execute on function public.poll_results() to anon, authenticated;

-- 투표를 올린 뒤에는 항목·익명 여부·복수 선택을 바꿀 수 없게 합니다.
-- 특히 '익명 → 실명' 으로 바꾸면 이미 익명으로 들어온 표가 드러날 수 있어서 막습니다.
-- (마감하기, 마감 시각 조정만 허용. 작성자 계정이 삭제되어 author_id 가 비워지는 것도 허용)
create or replace function public.guard_poll_update()
returns trigger language plpgsql as $$
begin
  if new.anonymous is distinct from old.anonymous
     or new.options is distinct from old.options
     or new.multi   is distinct from old.multi
     or (new.author_id is distinct from old.author_id and new.author_id is not null) then
    raise exception '투표를 올린 뒤에는 항목과 익명 여부를 바꿀 수 없습니다';
  end if;
  return new;
end $$;

drop trigger if exists polls_guard on public.polls;
create trigger polls_guard before update on public.polls
  for each row execute function public.guard_poll_update();
