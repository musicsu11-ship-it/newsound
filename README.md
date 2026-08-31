# 새소리단 활동 플랫폼

| 파일 | 설명 |
|---|---|
| `index.html` | **Supabase 연동판.** 여러 사람이 각자 기기에서 함께 사용합니다. |
| `standalone.html` | 서버 없이 도는 단일 파일판. 데이터가 그 브라우저에만 저장됩니다. 시연·연습용. |
| `supabase/schema.sql` | 데이터베이스 테이블 · 권한(RLS) · 파일 저장소 설정 |

---

## 설치 순서 (약 15분)

### 1. Supabase 프로젝트 만들기
[supabase.com](https://supabase.com) 에서 무료 프로젝트를 하나 만듭니다. 지역은 **Northeast Asia (Seoul)** 을 고르면 빠릅니다.

### 2. 데이터베이스 설정
대시보드 좌측 **SQL Editor** → New query → `supabase/schema.sql` 내용을 **전부** 붙여넣고 **Run**.

테이블, 권한 정책, `media`/`docs` 파일 저장소가 한 번에 만들어집니다. 다시 실행해도 안전합니다.

### 3. 익명 접속 켜기
**Authentication → Sign In / Providers → Anonymous sign-ins** 를 **켭니다.**
로그인 없이 소개·소식을 보고 의견함에 글을 남기려면 필요합니다.

### 4. 메일 인증 (선택)
내부에서만 쓴다면 **Authentication → Sign In / Providers → Email → Confirm email** 을 **끄면** 가입 즉시 로그인됩니다.
켜두면 가입자가 메일의 링크를 눌러야 합니다.

### 5. 접속 정보 입력
`index.html` 을 브라우저로 엽니다. 설정 화면이 나오면 **Project Settings → API** 의 두 값을 넣습니다.

- **Project URL** — `https://xxxxxxxx.supabase.co`
- **anon public** 키

> anon 키는 공개되어도 되는 키입니다. 실제 권한은 데이터베이스의 RLS 정책이 결정하므로, 이 키를 알아도 남의 영수증은 볼 수 없습니다.

여러 사람에게 배포할 때는 `index.html` 위쪽의 이 줄에 값을 미리 박아두면 각자 입력할 필요가 없습니다.

```js
const BAKED = { url:'', anonKey:'' };
```

### 6. 첫 관리자 지정
회원가입을 한 번 한 뒤, SQL Editor에서 이메일만 본인 것으로 바꿔 실행합니다.

```sql
update public.profiles set role = 'admin', name = '운영 관리자'
  where id = (select id from auth.users where email = 'you@example.com');
```

이후 **회원 · 권한 관리** 메뉴에서 나머지 사람들의 권한을 화면으로 올릴 수 있습니다.

### 7. 배포
`index.html` 하나만 올리면 됩니다. Netlify Drop, Vercel, GitHub Pages, 기관 웹서버 어디든 됩니다.

---

## 권한 구조

| 권한 | 볼 수 있는 것 | 할 수 있는 것 |
|---|---|---|
| **일반 방문자** (`visitor`) | 소개, 소식, 의견함, 일정 | 의견·댓글 작성, 본인 글 삭제 |
| **새소리단 단원** (`member`) | + 공지방, 자유방, 활동 공유방 | + 게시글 작성, 보고서 제출, 정산 신청, 일정 등록 |
| **혁신행정담당관** (`officer`) | + **전체 보고서·정산·영수증** | + 승인/반려 처리, 공지 작성 |
| **운영 관리자** (`admin`) | 전체 | + 권한 부여, 소개 편집, 게임 등록, 모든 글 삭제 |

가입한 사람은 전부 `visitor` 로 시작합니다. 권한 승격은 관리자만 할 수 있고, DB에서만 바뀝니다.

---

## 핵심 요구사항이 지켜지는 방식

**"단원이 영수증을 첨부하면 혁신행정담당관이 볼 수 있게"** — 이건 화면에서 버튼을 숨기는 방식이 아니라, 데이터베이스 정책으로 막습니다.

```sql
create policy expenses_select on public.expenses for select
  using ( author_id = auth.uid() or public.is_officer() );
```

영수증 파일도 마찬가지로 비공개 `docs` 버킷에 들어가고, 열람 권한이 없으면 Supabase가 파일 주소 자체를 내주지 않습니다. 브라우저 개발자 도구로 코드를 고쳐도 남의 영수증은 나오지 않습니다.

**익명 별칭** — 의견함의 `새소리1, 새소리2 …` 는 접속 IP를 SHA-256으로 해시한 값에 순번을 매긴 것입니다. IP 원본은 어디에도 저장하지 않습니다. 별칭은 DB 트리거가 붙이므로 클라이언트가 다른 사람 별칭을 사칭할 수 없습니다.

> 같은 사무실·같은 공유기에서 접속하면 IP가 같아 **같은 별칭**으로 보일 수 있습니다. 이건 IP 기준 별칭의 원래 성질입니다. 사람별로 구분하려면 `schema.sql` 의 `my_alias()` 에서 `public.client_ip()` 를 `auth.uid()::text` 로 바꾸면 됩니다.

---

## 무료 한도

Supabase 무료 플랜 기준 — 데이터베이스 500MB, 파일 저장소 1GB, 월 전송량 5GB.
사진은 업로드 전 1600px / 품질 0.75로 자동 축소되어 장당 200~400KB 정도입니다. 대략 사진 3,000장 수준까지 무료로 쓸 수 있습니다.

---

## 문제가 생기면

| 증상 | 확인할 것 |
|---|---|
| "익명 로그인이 꺼져 있습니다" | 3번 — Anonymous sign-ins 켜기 |
| 가입은 됐는데 로그인이 안 됨 | 4번 — 메일 인증 대기 중이거나 Confirm email 설정 |
| 글쓰기 버튼이 안 보임 | 권한이 아직 `visitor` — 6번으로 권한 부여 |
| "권한이 없습니다" | RLS가 정상 작동 중. 해당 작업에 필요한 권한인지 확인 |
| 사진이 안 보임 | 2번 SQL을 끝까지 실행했는지 (`media`/`docs` 버킷 생성 부분) |
