#!/usr/bin/env bash
# test-risk-score.sh — fixture suite for the tier scorer.
#
# Every case builds a real git repo and a real diff. The load-bearing case is
# AUTH_GUARD: a four-line change to an auth guard must NOT land in T0/T1, which
# is exactly the case a multiplicative score would zero out.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCORER="$ROOT/skills/triforce/scripts/risk-score.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

# new_repo <name> — fresh repo with a realistic baseline, echoes its path
new_repo() {
  local d="$WORK/$1"
  mkdir -p "$d/src" "$d/tests"
  (
    cd "$d" || exit 1
    git init -q -b main
    git config user.email t@example.com
    git config user.name t
    for i in $(seq 1 120); do echo "// line $i of ordinary code"; done > src/util.js
    echo "function helper(a, b) { return a + b; }" >> src/util.js
    for i in $(seq 1 60); do echo "// auth line $i"; done > src/auth.js
    echo "function checkToken(t) { if (!t) { throw new Error('no token'); } return verify(t); }" >> src/auth.js
    echo "test('helper', () => {});" > tests/util.test.js
    git add -A
    git commit -qm base
  ) >/dev/null 2>&1
  echo "$d"
}

# expect <label> <repo> <min-tier> <max-tier>
expect() {
  local label="$1" d="$2" lo="$3" hi="$4"
  local out tier score floors
  out=$(cd "$d" && bash "$SCORER" "$(git rev-list --max-parents=0 HEAD)" 2>/dev/null)
  if [ -z "$out" ]; then
    printf '  FAIL  %-28s scorer produced no output\n' "$label"
    FAIL=$((FAIL + 1)); return
  fi
  tier=$(printf '%s\n' "$out" | sed -n 's/^TRIFORCE_TIER=//p')
  score=$(printf '%s\n' "$out" | sed -n 's/^TRIFORCE_SCORE=//p')
  floors=$(printf '%s\n' "$out" | sed -n 's/^TRIFORCE_FLOORS=//p')
  if [ "$tier" -ge "$lo" ] && [ "$tier" -le "$hi" ]; then
    printf '  ok    %-28s T%s score=%-3s [%s]\n' "$label" "$tier" "$score" "$floors"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %-28s T%s score=%-3s expected T%s..T%s [%s]\n' \
           "$label" "$tier" "$score" "$lo" "$hi" "$floors"
    FAIL=$((FAIL + 1))
  fi
}

echo "risk-score fixtures"
echo

# --- A: a reworded comment. Nothing consequential. --------------------------
d=$(new_repo trivial)
( cd "$d" && sed -i '3s|.*|// line 3 of ordinary code, reworded|' src/util.js \
   && git commit -qam "reword a comment" ) >/dev/null 2>&1
expect "trivial comment" "$d" 0 0

# --- B: THE LOAD-BEARING CASE ------------------------------------------------
# Four lines. Minimal spread, minimal churn, minimal fragmentation. A
# multiplicative score sends this to zero. It must not be T0 or T1.
d=$(new_repo authguard)
( cd "$d" && sed -i "s|function checkToken(t) { if (!t) { throw new Error('no token'); } return verify(t); }|function checkToken(t) { return verify(t); }|" src/auth.js \
   && git commit -qam "simplify token check" ) >/dev/null 2>&1
expect "4-line auth guard removal" "$d" 2 3

# --- C: a wide but mechanical rename across many files ----------------------
d=$(new_repo wide)
( cd "$d" && for i in $(seq 1 9); do
      printf 'export function mod%s() { return %s; }\n' "$i" "$i" > "src/mod$i.js"
    done && git add -A && git commit -qam "add nine modules" ) >/dev/null 2>&1
expect "nine new modules" "$d" 2 3

# --- D: ordinary feature work with tests ------------------------------------
d=$(new_repo withtests)
( cd "$d" && echo "function sum(xs) { return xs.reduce((a,b)=>a+b, 0); }" >> src/util.js \
   && echo "test('sum', () => {});" >> tests/util.test.js \
   && git commit -qam "add sum plus a test" ) >/dev/null 2>&1
expect "small feature + test" "$d" 0 1

# --- E: same feature, no test — the test gap must cost something ------------
d=$(new_repo notests)
( cd "$d" && echo "function sum(xs) { return xs.reduce((a,b)=>a+b, 0); }" >> src/util.js \
   && git commit -qam "add sum, no test" ) >/dev/null 2>&1
expect "small feature, no test" "$d" 1 2

# --- F: a payments migration — two danger domains, floor to T3 --------------
d=$(new_repo payments)
( cd "$d" && mkdir -p migrations \
   && echo "ALTER TABLE payments DROP COLUMN refund_id;" > migrations/003_payments.sql \
   && echo "function charge(card) { return gateway.charge(card); }" > src/billing.js \
   && git add -A && git commit -qam "payments migration" ) >/dev/null 2>&1
expect "payments + migration" "$d" 3 3

# --- G: empty diff ----------------------------------------------------------
d=$(new_repo empty)
expect "no changes" "$d" 0 0

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
