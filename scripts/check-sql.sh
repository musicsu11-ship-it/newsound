#!/bin/sh
# ============================================================================
#  '전체 복사해서 Run' 하는 SQL 파일을 커밋 전에 기계가 검사합니다.
#
#  ① 지우는 문장(delete·truncate·drop table)이 들어 있지 않은지
#  ② 설계도 원본에서 표 비우는 문장이 되살아나지 않았는지
#  ③ 다른 기능을 고치는 작업 파일이 밸런스게임 표를 건드리지 않는지
#
#  2026-11-19, 실행용 파일에 남아 있던 delete 두 줄 때문에 밸런스게임 표와
#  이벤트 응모 명단이 전부 사라졌습니다. 사람이 기억하는 것에 기대지 않도록
#  커밋할 때마다 확인합니다.
#
#  직접 돌려 보기 :  sh scripts/check-sql.sh
#  켜 두기        :  git config core.hooksPath .githooks
# ============================================================================
cd "$(dirname "$0")/.." || exit 1
fail=0

# 주석(--)을 떼고, '문장이 그 낱말로 시작하는 경우'만 봅니다.
#   · 걸립니다   : delete from … / truncate … / drop table …
#   · 안 걸립니다: 안내문 속 낱말, drop trigger if exists, before truncate on …
scan_destructive() {
  sed 's/--.*$//' "$1" | grep -nE \
    -e '(^|;)[[:space:]]*[Dd][Ee][Ll][Ee][Tt][Ee][[:space:]]+[Ff][Rr][Oo][Mm]' \
    -e '(^|;)[[:space:]]*[Tt][Rr][Uu][Nn][Cc][Aa][Tt][Ee]([[:space:]]|$)' \
    -e '(^|;)[[:space:]]*[Dd][Rr][Oo][Pp][[:space:]]+([Tt][Aa][Bb][Ll][Ee]|[Ss][Cc][Hh][Ee][Mm][Aa]|[Dd][Aa][Tt][Aa][Bb][Aa][Ss][Ee])' \
    -e '[Dd][Ii][Ss][Aa][Bb][Ll][Ee][[:space:]]+[Tt][Rr][Ii][Gg][Gg][Ee][Rr]'
}

# 밸런스게임 자료를 담는 표들
scan_vote_tables() {
  sed 's/--.*$//' "$1" | grep -nE 'poll_ballots|poll_entries|public\.polls|vote_journal'
}

found=0
for f in supabase/지금-실행할-*.sql; do
  [ -f "$f" ] || continue
  found=1

  # ── ① 지우는 문장 ──────────────────────────────────────────────────
  bad=$(scan_destructive "$f")
  if [ -n "$bad" ]; then
    echo "✋ $f 안에 지우는 문장이 있습니다."
    echo "$bad" | sed 's/^/     /'
    echo
    echo "   이 파일은 담당자가 '전체 복사해서 Run' 하는 파일입니다."
    echo "   지우는 작업은 별도 파일로 분리해 그때만 따로 전달하세요."
    fail=1
  else
    echo "✓ $f — 지우는 문장 없음"
  fi

  # ── ③ 캠페인 보호 — 다른 기능 작업이 투표 표에 닿지 않게 ───────────
  #  출근룩·맛집처럼 다른 기능을 고치는 동안 밸런스게임 자료가 휩쓸리는 것을
  #  막습니다. 투표 기능 자체를 일부러 손볼 때만 파일 머리말에 적으세요:
  #      -- 투표표-건드림-허용
  if grep -q '투표표-건드림-허용' "$f"; then
    echo "· $f — 투표 표를 다루는 작업으로 표시돼 있습니다 (의도한 것으로 봅니다)"
  else
    touched=$(scan_vote_tables "$f")
    if [ -n "$touched" ]; then
      echo "✋ $f 이 밸런스게임 표(polls·poll_ballots·poll_entries)를 건드립니다."
      echo "$touched" | sed 's/^/     /'
      echo
      echo "   출근룩 등 다른 기능 작업이라면 이 줄들을 빼세요."
      echo "   투표 기능을 일부러 손보는 중이라면 파일 머리말에 한 줄 넣으세요:"
      echo "       -- 투표표-건드림-허용"
      fail=1
    else
      echo "✓ $f — 밸런스게임 표를 건드리지 않음"
    fi
  fi
done
[ "$found" = 0 ] && echo "· 실행할 SQL 파일이 없습니다 (검사 생략)"

# ── ② 설계도 원본 — 표 비우는 문장이 되살아나지 않았는지 ───────────────
if [ -f supabase/schema.sql ]; then
  revived=$(sed 's/--.*$//' supabase/schema.sql | grep -nE \
    '(^|;)[[:space:]]*[Dd][Ee][Ll][Ee][Tt][Ee][[:space:]]+[Ff][Rr][Oo][Mm][[:space:]]+public\.(poll_ballots|poll_entries|vote_journal)')
  if [ -n "$revived" ]; then
    echo "✋ supabase/schema.sql 에서 표를 비우는 문장이 살아났습니다. (42절·38절)"
    echo "$revived" | sed 's/^/     /'
    echo "   주석 처리된 상태로 두어야 합니다."
    fail=1
  else
    echo "✓ supabase/schema.sql — 표 비우는 문장 주석 처리 유지"
  fi
fi

if [ "$fail" = 1 ]; then
  echo
  echo "커밋을 멈췄습니다. 위 내용을 고친 뒤 다시 커밋하세요."
  exit 1
fi
exit 0
