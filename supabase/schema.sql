-- ============================================================================
--  새소리단 활동 플랫폼 — Supabase 스키마
--  Supabase 대시보드 > SQL Editor 에 이 파일 전체를 붙여넣고 실행하세요.
--  (여러 번 실행해도 안전하도록 작성되어 있습니다)
-- ============================================================================

create extension if not exists pgcrypto with schema extensions;

-- ============================================================================
--  1. 사용자 프로필 / 권한
--     권한은 반드시 서버(DB)에만 저장합니다. 브라우저에서 보내는 값은 믿지 않습니다.
--     visitor : 로그인만 한 일반 방문자 (익명 포함)
--     member  : 새소리단 단원
--     officer : 혁신행정담당관
--     admin   : 운영 관리자
-- ============================================================================
create table if not exists public.profiles (
  id          uuid primary key references auth.users on delete cascade,
  name        text not null default '',
  team        text default '',
  role        text not null default 'visitor'
              check (role in ('visitor','member','officer','admin')),
  created_at  timestamptz not null default now()
);

-- 가입 시 프로필 자동 생성 (권한은 항상 visitor로 시작)
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, name)
  values (new.id, coalesce(new.raw_user_meta_data->>'name', ''))
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- 내 권한 조회 (security definer — profiles RLS 재귀를 피하기 위함)
create or replace function public.my_role()
returns text language sql stable security definer set search_path = public as $$
  select coalesce((select role from public.profiles where id = auth.uid()), 'visitor')
$$;

-- 단원 이상인가?
create or replace function public.is_inner()
returns boolean language sql stable security definer set search_path = public as $$
  select public.my_role() in ('member','officer','admin')
$$;

-- 담당관 이상인가? (영수증·보고서 전체 열람 권한)
create or replace function public.is_officer()
returns boolean language sql stable security definer set search_path = public as $$
  select public.my_role() in ('officer','admin')
$$;

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select public.my_role() = 'admin'
$$;

-- ---------------------------------------------------------------------------
--  1-1. 첫 관리자 자동 등록
--       관리자가 한 명도 없을 때만, 로그인한 본인을 관리자로 올립니다.
--       한 명이라도 생기면 이 함수는 영원히 아무 일도 하지 않습니다.
-- ---------------------------------------------------------------------------
create or replace function public.admin_exists()
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.profiles where role = 'admin')
$$;
grant execute on function public.admin_exists() to anon, authenticated;

create or replace function public.claim_first_admin(display_name text default null)
returns text language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then
    return 'not-logged-in';
  end if;
  -- 익명 방문자는 관리자가 될 수 없습니다
  if coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) then
    return 'anonymous';
  end if;
  if exists(select 1 from public.profiles where role = 'admin') then
    return 'already-exists';
  end if;

  update public.profiles
     set role = 'admin',
         name = coalesce(nullif(trim(display_name), ''), nullif(name, ''), '운영 관리자')
   where id = auth.uid();
  return 'ok';
end $$;
grant execute on function public.claim_first_admin(text) to authenticated;

-- ============================================================================
--  2. 익명 별칭 — 실제 접속 IP 기준으로 '새소리1, 새소리2 …' 순서대로 부여
--     PostgREST가 넘겨주는 요청 헤더에서 IP를 읽어 해시로만 보관합니다.
--     (원본 IP는 저장하지 않습니다)
-- ============================================================================
create table if not exists public.ip_alias (
  ip_hash    text primary key,
  n          int  not null,
  created_at timestamptz not null default now()
);
alter table public.ip_alias enable row level security;
-- 클라이언트는 이 표를 직접 읽거나 쓸 수 없습니다. my_alias() 함수로만 접근합니다.

create or replace function public.client_ip()
returns text language sql stable as $$
  select nullif(
    split_part(
      coalesce(current_setting('request.headers', true)::json ->> 'x-forwarded-for', ''),
    ',', 1),
  '')
$$;

-- 접속 IP를 되돌릴 수 없는 해시로 바꿉니다. 원본 IP는 저장하지 않습니다.
-- IP를 모르는 경우(로컬 테스트 등)에는 사용자 uid로 대체합니다.
create or replace function public.visitor_hash()
returns text language sql stable security definer set search_path = public, extensions as $$
  select encode(extensions.digest(
    coalesce(public.client_ip(), auth.uid()::text, 'unknown') || '::saesori', 'sha256'), 'hex')
$$;

-- 이 방문자의 순번을 얻습니다. 처음 보는 IP면 새 번호를 발급합니다.
create or replace function public.visitor_no(h text)
returns int language plpgsql security definer set search_path = public as $$
declare num int;
begin
  select n into num from public.ip_alias where ip_hash = h;
  if num is null then
    insert into public.ip_alias(ip_hash, n)
    values (h, (select coalesce(max(n), 0) + 1 from public.ip_alias))
    on conflict (ip_hash) do nothing;
    select n into num from public.ip_alias where ip_hash = h;
  end if;
  return num;
end $$;

create or replace function public.my_alias()
returns text language plpgsql security definer set search_path = public as $$
begin
  return '새소리' || public.visitor_no(public.visitor_hash());
end $$;

grant execute on function public.my_alias() to anon, authenticated;

-- ---------------------------------------------------------------------------
--  2-1. 방문자 집계 — IP가 다르면 다른 방문자로 셉니다
--       ip_alias 를 고유 방문자 명부로 함께 쓰고, 날짜별 집계는 visit_daily 에 쌓습니다.
-- ---------------------------------------------------------------------------
alter table public.ip_alias add column if not exists first_seen timestamptz not null default now();
alter table public.ip_alias add column if not exists last_seen  timestamptz not null default now();
alter table public.ip_alias add column if not exists visits     integer     not null default 0;

create table if not exists public.visit_daily (
  day      date    not null,
  ip_hash  text    not null,
  hits     integer not null default 1,
  primary key (day, ip_hash)
);
alter table public.visit_daily enable row level security;
-- 클라이언트는 이 표에 직접 접근할 수 없습니다. 아래 함수로만 읽고 씁니다.

-- 페이지를 열 때 한 번 호출합니다. 같은 IP가 하루에 여러 번 와도 고유 방문자는 1로 셉니다.
create or replace function public.track_visit()
returns json language plpgsql security definer set search_path = public as $$
declare h text; d date := (now() at time zone 'Asia/Seoul')::date;
begin
  h := public.visitor_hash();
  perform public.visitor_no(h);                        -- 명부에 없으면 등록
  update public.ip_alias
     set last_seen = now(), visits = visits + 1
   where ip_hash = h;
  insert into public.visit_daily(day, ip_hash, hits)
  values (d, h, 1)
  on conflict (day, ip_hash) do update set hits = visit_daily.hits + 1;
  return public.visit_stats();
end $$;

-- 요약 숫자 (개인정보 없음 · 합계만)
--   today / week / month / total : 서로 다른 IP 수 (같은 IP는 하루에 1명)
--   *_hits                       : 페이지를 연 횟수 (같은 IP가 다시 와도 계속 올라감)
create or replace function public.visit_stats()
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'today',      (select count(*) from public.visit_daily
                    where day = (now() at time zone 'Asia/Seoul')::date),
    'today_hits', (select coalesce(sum(hits), 0) from public.visit_daily
                    where day = (now() at time zone 'Asia/Seoul')::date),
    'week',       (select count(distinct ip_hash) from public.visit_daily
                    where day > (now() at time zone 'Asia/Seoul')::date - 7),
    'week_hits',  (select coalesce(sum(hits), 0) from public.visit_daily
                    where day > (now() at time zone 'Asia/Seoul')::date - 7),
    'month',      (select count(distinct ip_hash) from public.visit_daily
                    where day > (now() at time zone 'Asia/Seoul')::date - 30),
    'total',      (select count(*) from public.ip_alias),
    'hits',       (select coalesce(sum(visits), 0) from public.ip_alias)
  )
$$;

-- 최근 N일 추이 (관리자 콘솔 그래프용)
create or replace function public.visit_series(days int default 14)
-- 반환 컬럼 이름을 d 로 둔 이유: day 로 두면 visit_daily.day 와 이름이 겹쳐 모호해질 수 있습니다.
returns table(d date, uniques bigint, hits bigint)
language sql stable security definer set search_path = public as $$
  select g::date,
         count(v.ip_hash),
         coalesce(sum(v.hits), 0)
    from generate_series(
           (now() at time zone 'Asia/Seoul')::date - (greatest(days,1) - 1),
           (now() at time zone 'Asia/Seoul')::date,
           interval '1 day') g
    left join public.visit_daily v on v.day = g::date
   group by g
   order by g
$$;

grant execute on function public.track_visit()   to anon, authenticated;
grant execute on function public.visit_stats()   to anon, authenticated;
grant execute on function public.visit_series(int) to authenticated;

-- ============================================================================
--  3. 게시판 (소식 / 공지방 / 자유방 / 활동 공유방)
-- ============================================================================
create table if not exists public.posts (
  id          uuid primary key default gen_random_uuid(),
  board       text not null check (board in ('news','notice','free','share')),
  title       text not null,
  body        text not null,
  images      jsonb not null default '[]'::jsonb,   -- media 버킷의 파일 경로 배열
  pinned      boolean not null default false,
  author_id   uuid not null default auth.uid() references auth.users on delete cascade,
  author_name text not null default '',
  created_at  timestamptz not null default now()
);
create index if not exists posts_board_created_idx on public.posts (board, created_at desc);

alter table public.posts enable row level security;

drop policy if exists posts_select on public.posts;
create policy posts_select on public.posts for select
  using ( board = 'news' or public.is_inner() );   -- 소식은 누구나, 나머지는 단원 이상

drop policy if exists posts_insert on public.posts;
create policy posts_insert on public.posts for insert
  with check (
    author_id = auth.uid()
    and case when board = 'notice' then public.is_officer() else public.is_inner() end
  );

drop policy if exists posts_update on public.posts;
create policy posts_update on public.posts for update
  using ( author_id = auth.uid() or public.is_admin() );

drop policy if exists posts_delete on public.posts;
create policy posts_delete on public.posts for delete
  using ( author_id = auth.uid() or public.is_admin() );

-- ============================================================================
--  4. 의견함 — 익명 기본, 전체 공개, 댓글
--     별칭은 서버에서 강제로 채웁니다 (클라이언트가 위조할 수 없음)
-- ============================================================================
create table if not exists public.opinions (
  id         uuid primary key default gen_random_uuid(),
  cat        text not null default '일반 의견',
  body       text not null,
  alias      text not null default '',
  author_id  uuid not null default auth.uid() references auth.users on delete cascade,
  created_at timestamptz not null default now()
);
create index if not exists opinions_created_idx on public.opinions (created_at desc);

create table if not exists public.opinion_comments (
  id         uuid primary key default gen_random_uuid(),
  opinion_id uuid not null references public.opinions on delete cascade,
  body       text not null,
  alias      text not null default '',
  author_id  uuid not null default auth.uid() references auth.users on delete cascade,
  created_at timestamptz not null default now()
);
create index if not exists opinion_comments_op_idx on public.opinion_comments (opinion_id, created_at);

-- 별칭 자동 부여
create or replace function public.set_alias()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.alias := public.my_alias();
  return new;
end $$;

drop trigger if exists opinions_set_alias on public.opinions;
create trigger opinions_set_alias before insert on public.opinions
  for each row execute function public.set_alias();

drop trigger if exists opinion_comments_set_alias on public.opinion_comments;
create trigger opinion_comments_set_alias before insert on public.opinion_comments
  for each row execute function public.set_alias();

alter table public.opinions enable row level security;
alter table public.opinion_comments enable row level security;

drop policy if exists opinions_select on public.opinions;
create policy opinions_select on public.opinions for select using ( true );

drop policy if exists opinions_insert on public.opinions;
create policy opinions_insert on public.opinions for insert
  with check ( author_id = auth.uid() );

drop policy if exists opinions_delete on public.opinions;
create policy opinions_delete on public.opinions for delete
  using ( author_id = auth.uid() or public.is_admin() );

drop policy if exists opc_select on public.opinion_comments;
create policy opc_select on public.opinion_comments for select using ( true );

drop policy if exists opc_insert on public.opinion_comments;
create policy opc_insert on public.opinion_comments for insert
  with check ( author_id = auth.uid() );

drop policy if exists opc_delete on public.opinion_comments;
create policy opc_delete on public.opinion_comments for delete
  using ( author_id = auth.uid() or public.is_admin() );

-- ============================================================================
--  5. 결과보고서
-- ============================================================================
create table if not exists public.reports (
  id          uuid primary key default gen_random_uuid(),
  title       text not null,
  act_date    date not null,
  team        text default '',
  overview    text not null default '',
  content     text default '',
  result      text default '',
  improve     text default '',
  files       jsonb not null default '[]'::jsonb,   -- docs 버킷 경로
  status      text not null default '접수' check (status in ('접수','검토중','승인','반려')),
  officer_comment text default '',
  author_id   uuid not null default auth.uid() references auth.users on delete cascade,
  author_name text not null default '',
  created_at  timestamptz not null default now()
);
alter table public.reports enable row level security;

drop policy if exists reports_select on public.reports;
create policy reports_select on public.reports for select
  using ( author_id = auth.uid() or public.is_officer() );

drop policy if exists reports_insert on public.reports;
create policy reports_insert on public.reports for insert
  with check ( author_id = auth.uid() and public.is_inner() );

-- 담당관만 상태·코멘트를 바꿀 수 있습니다
drop policy if exists reports_update on public.reports;
create policy reports_update on public.reports for update
  using ( public.is_officer() ) with check ( public.is_officer() );

drop policy if exists reports_delete on public.reports;
create policy reports_delete on public.reports for delete
  using ( public.is_admin() );

-- ============================================================================
--  6. 활동비 정산 — 영수증은 본인과 혁신행정담당관만 열람
-- ============================================================================
create table if not exists public.expenses (
  id          uuid primary key default gen_random_uuid(),
  act_date    date not null,
  activity    text not null,
  item        text not null,
  amount      integer not null check (amount >= 0),
  pay_method  text default '개인카드',
  bank        text default '',
  contact     text default '',
  note        text default '',
  receipts    jsonb not null default '[]'::jsonb,   -- docs 버킷 경로 (비공개)
  status      text not null default '접수' check (status in ('접수','검토중','승인','반려')),
  officer_comment text default '',
  author_id   uuid not null default auth.uid() references auth.users on delete cascade,
  author_name text not null default '',
  created_at  timestamptz not null default now()
);
alter table public.expenses enable row level security;

-- 핵심 요구사항: 단원이 올린 영수증을 혁신행정담당관이 볼 수 있게, 그 외에는 못 보게
drop policy if exists expenses_select on public.expenses;
create policy expenses_select on public.expenses for select
  using ( author_id = auth.uid() or public.is_officer() );

drop policy if exists expenses_insert on public.expenses;
create policy expenses_insert on public.expenses for insert
  with check ( author_id = auth.uid() and public.is_inner() );

drop policy if exists expenses_update on public.expenses;
create policy expenses_update on public.expenses for update
  using ( public.is_officer() ) with check ( public.is_officer() );

drop policy if exists expenses_delete on public.expenses;
create policy expenses_delete on public.expenses for delete
  using ( public.is_admin() );

-- ============================================================================
--  7. 일정 (캘린더)
-- ============================================================================
create table if not exists public.events (
  id          uuid primary key default gen_random_uuid(),
  ev_date     date not null,
  ev_time     text default '',
  title       text not null,
  place       text default '',
  descr       text default '',
  author_id   uuid not null default auth.uid() references auth.users on delete cascade,
  author_name text not null default '',
  created_at  timestamptz not null default now()
);
create index if not exists events_date_idx on public.events (ev_date);
alter table public.events enable row level security;

drop policy if exists events_select on public.events;
create policy events_select on public.events for select using ( true );   -- 누구나 열람

drop policy if exists events_insert on public.events;
create policy events_insert on public.events for insert
  with check ( author_id = auth.uid() and public.is_inner() );

-- 관리자 콘솔의 "일정 관리"는 담당관·관리자 모두 접근하는 화면이라
-- (admin.html MENUS: roles:['officer','admin']) 삭제/수정 권한도 그에 맞춥니다.
-- is_admin() 만 허용했을 때는 담당관이 남이 등록한 일정을 지우려 하면
-- 버튼은 보이는데 DB 정책에 막혀 조용히 실패했습니다.
drop policy if exists events_update on public.events;
create policy events_update on public.events for update
  using ( author_id = auth.uid() or public.is_officer() );

drop policy if exists events_delete on public.events;
create policy events_delete on public.events for delete
  using ( author_id = auth.uid() or public.is_officer() );

-- ============================================================================
--  8. 사이트 설정 / 새소리단 소개 (단일 행)
-- ============================================================================
create table if not exists public.site (
  id         int primary key default 1 check (id = 1),
  intro      jsonb not null default '{}'::jsonb,
  game_url   text default '',
  game_html  text default '',
  updated_at timestamptz not null default now()
);
insert into public.site (id) values (1) on conflict (id) do nothing;

alter table public.site enable row level security;

drop policy if exists site_select on public.site;
create policy site_select on public.site for select using ( true );

drop policy if exists site_update on public.site;
create policy site_update on public.site for update
  using ( public.is_admin() ) with check ( public.is_admin() );

-- ============================================================================
--  9. 프로필 RLS
--     단원 이상은 서로의 이름을 볼 수 있고, 권한 변경은 관리자만 가능합니다.
-- ============================================================================
alter table public.profiles enable row level security;

drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select
  using ( id = auth.uid() or public.is_officer() );

drop policy if exists profiles_update_self on public.profiles;
create policy profiles_update_self on public.profiles for update
  using ( id = auth.uid() ) with check ( id = auth.uid() and role = public.my_role() );

drop policy if exists profiles_update_admin on public.profiles;
create policy profiles_update_admin on public.profiles for update
  using ( public.is_admin() ) with check ( public.is_admin() );

-- ============================================================================
-- 10. 파일 저장소 (Storage)
--     media : 소식·활동공유방 사진 (공개)
--     docs  : 영수증·보고서 첨부 (비공개 — 본인과 담당관만)
-- ============================================================================
insert into storage.buckets (id, name, public)
values ('media','media', true)
on conflict (id) do update set public = true;

insert into storage.buckets (id, name, public)
values ('docs','docs', false)
on conflict (id) do update set public = false;

-- 파일 경로는 항상  <폴더>/<올린사람 uid>/<파일명>  형태입니다.
-- owner 컬럼 대신 경로에서 소유자를 읽습니다 (owner 컬럼은 향후 제거 예정이라 안전하지 않음).
create or replace function public.storage_owner(object_name text)
returns uuid language sql immutable as $$
  select nullif((storage.foldername(object_name))[2], '')::uuid
$$;

-- media: 누구나 보기, 단원 이상만 업로드
drop policy if exists media_read on storage.objects;
create policy media_read on storage.objects for select
  using ( bucket_id = 'media' );

drop policy if exists media_write on storage.objects;
create policy media_write on storage.objects for insert
  with check (
    bucket_id = 'media' and public.is_inner()
    and public.storage_owner(name) = auth.uid()   -- 남의 폴더에 못 올림
  );

drop policy if exists media_delete on storage.objects;
create policy media_delete on storage.objects for delete
  using ( bucket_id = 'media'
          and (public.storage_owner(name) = auth.uid() or public.is_admin()) );

-- docs: 올린 본인과 혁신행정담당관·관리자만 열람  ★영수증 보호의 핵심
drop policy if exists docs_read on storage.objects;
create policy docs_read on storage.objects for select
  using ( bucket_id = 'docs'
          and (public.storage_owner(name) = auth.uid() or public.is_officer()) );

drop policy if exists docs_write on storage.objects;
create policy docs_write on storage.objects for insert
  with check (
    bucket_id = 'docs' and public.is_inner()
    and public.storage_owner(name) = auth.uid()
  );

drop policy if exists docs_delete on storage.objects;
create policy docs_delete on storage.objects for delete
  using ( bucket_id = 'docs'
          and (public.storage_owner(name) = auth.uid() or public.is_admin()) );

-- ============================================================================
-- 11. 실시간 반영 (선택) — 켜두면 다른 사람이 올린 글이 즉시 보입니다
-- ============================================================================
do $$
begin
  alter publication supabase_realtime add table public.posts;
exception when duplicate_object then null; end $$;
do $$
begin
  alter publication supabase_realtime add table public.opinions;
exception when duplicate_object then null; end $$;
do $$
begin
  alter publication supabase_realtime add table public.opinion_comments;
exception when duplicate_object then null; end $$;
do $$
begin
  alter publication supabase_realtime add table public.events;
exception when duplicate_object then null; end $$;
-- 권한이 바뀌면 해당 사용자 화면에 즉시 반영되도록
do $$
begin
  alter publication supabase_realtime add table public.profiles;
exception when duplicate_object then null; end $$;
-- 관리자 콘솔에서 소개·게임을 바꾸면 홈페이지에 즉시 반영되도록
do $$
begin
  alter publication supabase_realtime add table public.site;
exception when duplicate_object then null; end $$;

-- ============================================================================
-- 12. 첫 관리자 지정
--     회원가입을 한 번 한 뒤, 아래 줄의 이메일을 본인 것으로 바꿔 실행하세요.
-- ============================================================================
-- update public.profiles set role = 'admin', name = '운영 관리자'
--   where id = (select id from auth.users where email = 'you@example.com');

-- ---------------------------------------------------------------------------
--  의견함은 의견을 받기만 하는 공간입니다. 처리 상태는 두지 않습니다.
--  따라서 수정(update) 정책도 만들지 않습니다 — 남기기·읽기·삭제만 가능합니다.
--  (예전 버전에서 만들어진 것이 있다면 정리합니다)
-- ---------------------------------------------------------------------------
drop policy if exists opinions_update on public.opinions;

-- ---------------------------------------------------------------------------
--  조회수는 혁신행정담당관·운영 관리자만 볼 수 있습니다.
--  집계는 계속 쌓되(track_visit), 숫자를 읽는 것은 담당관 이상으로 제한합니다.
-- ---------------------------------------------------------------------------
create or replace function public.visit_stats()
returns json language sql stable security definer set search_path = public as $$
  select case when public.is_officer() then
    json_build_object(
      'today',      (select count(*) from public.visit_daily
                      where day = (now() at time zone 'Asia/Seoul')::date),
      'today_hits', (select coalesce(sum(hits), 0) from public.visit_daily
                      where day = (now() at time zone 'Asia/Seoul')::date),
      'week',       (select count(distinct ip_hash) from public.visit_daily
                      where day > (now() at time zone 'Asia/Seoul')::date - 7),
      'week_hits',  (select coalesce(sum(hits), 0) from public.visit_daily
                      where day > (now() at time zone 'Asia/Seoul')::date - 7),
      'month',      (select count(distinct ip_hash) from public.visit_daily
                      where day > (now() at time zone 'Asia/Seoul')::date - 30),
      'total',      (select count(*) from public.ip_alias),
      'hits',       (select coalesce(sum(visits), 0) from public.ip_alias)
    )
  else null end
$$;

-- 추이 그래프도 담당관 이상만
create or replace function public.visit_series(days int default 14)
returns table(d date, uniques bigint, hits bigint)
language sql stable security definer set search_path = public as $$
  select g::date, count(v.ip_hash), coalesce(sum(v.hits), 0)
    from generate_series(
           (now() at time zone 'Asia/Seoul')::date - (greatest(days,1) - 1),
           (now() at time zone 'Asia/Seoul')::date,
           interval '1 day') g
    left join public.visit_daily v on v.day = g::date
   where public.is_officer()
   group by g
   order by g
$$;

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
