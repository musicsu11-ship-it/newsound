-- ============================================================================
--  새소리단 — 지금 실행해야 하는 SQL  (2026-09-07)
--
--  ▷ 하는 법
--     1. 이 파일 안을 아무 데나 클릭
--     2. Ctrl + A  (전체 선택)   →   Ctrl + C  (복사)
--     3. Supabase 사이트 → 왼쪽 메뉴 'SQL Editor' → 'New query' 버튼
--     4. 빈 칸에 Ctrl + V  (붙여넣기)   →   오른쪽 아래 'Run' 버튼
--     5. 'Success' 라고 나오면 끝입니다.
--
--  ▷ 안전한가요?
--     네. 기존 글·사진·회원 정보는 지우지 않습니다.
--     여러 번 실행해도 같은 결과가 나오게 만들어 두었습니다.
--
--  ▷ 무엇이 바뀌나요?  (아래 두 가지)
--     1) 게시글 작성자의 팀·부서, 정산의 팀을 저장할 칸을 만듭니다.
--        (이게 없으면 팀을 골라도 저장이 안 됩니다)
--     2) 익명 별칭이 사람마다 다르게 나오도록 고칩니다.
--        지금은 서로 다른 사람이 똑같이 '새소리16' 을 받고 있습니다.
--
--  ▷ 이 내용은 supabase/schema.sql 13·14절과 같습니다.
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
