# Supabase 지원 요청문 (복사해서 보내세요)

**보내는 곳**: https://supabase.com/dashboard/support/new
(대시보드 오른쪽 위 ? → Support 로도 들어갈 수 있습니다)

- Project: 새소리단
- Project ref: `lixuhimwutyiqshzamtp`
- Category: **Database / Data loss**
- Severity: 가장 높은 단계로

---

## 제목 (Subject)

Urgent: accidental DELETE on Free plan — any internal backup for 2026-11-18?

## 본문 (Message) — 아래를 그대로 붙여넣으세요

Hello,

I accidentally ran a DELETE statement against my project and lost two tables'
worth of rows. I am on the Free plan, so I have no scheduled backups or PITR.
I am writing to ask whether Supabase holds any internal/disaster-recovery
snapshot of this project from before the deletion that could be restored or
exported for me.

- Project ref: lixuhimwutyiqshzamtp
- Region: (대시보드 Settings → General 에 적힌 값을 넣으세요)
- Tables affected: public.poll_ballots, public.poll_entries
- Approximate time of deletion: 2026-11-18 15:18 UTC
  (autovacuum ran on both tables at 2026-11-18 15:18:20 UTC immediately after)
- Current state: both tables are 0 bytes / 0 pages, n_dead_tup = 0,
  so there is nothing left to recover on my side.
- Rows lost: several hundred (683 accounts were created after the campaign
  opened on 2026-11-09, and most of them voted)

This data is from a staff engagement campaign run by a government department
and the entries include participants' contact details for a prize draw, so it
cannot simply be re-collected.

I understand the Free plan does not include backups. I am asking only whether
any restorable copy exists on your side from before 2026-11-18 15:18 UTC.
If a paid plan is required to perform the restore, I am willing to upgrade —
please tell me whether a restore is technically possible first.

Thank you.

---

## 참고 — 물어볼 가능성이 있는 것

- "왜 백업이 없었나?" → 무료 플랜이라 처음부터 제공되지 않았습니다.
- "복구 가치가 있는 데이터인가?" → 이벤트 응모자 연락처라 재수집이 불가능합니다.
- 영문이 부담스러우시면 한국어로 보내셔도 됩니다. 다만 영문이 처리가 빠릅니다.
