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

drop policy if exists events_update on public.events;
create policy events_update on public.events for update
  using ( author_id = auth.uid() or public.is_admin() );

drop policy if exists events_delete on public.events;
create policy events_delete on public.events for delete
  using ( author_id = auth.uid() or public.is_admin() );

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
