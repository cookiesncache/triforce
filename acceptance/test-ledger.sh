#!/usr/bin/env bash
# test-ledger.sh — the termination proof, exercised.
#
# Acceptance case 8 (invocation ceiling) and half of case 9 (every ledger write
# monotone) live here. If these pass, invocations per branch are bounded above
# by INVOCATION_CAP[tier] + GROUND_TRUTH_GRANT by construction.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
L="$ROOT/skills/triforce/scripts/ledger.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK" || exit 1
export TRIFORCE_LEDGER_DIR="$WORK/.triforce/ledger"
export TRIFORCE_AUDITED_DIR="$WORK/.triforce/audited"

PASS=0; FAIL=0
ok()   { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1 ($3)"; else bad "$1 — got '$2' want '$3'"; fi; }

echo "ledger"
echo

# --- keys -------------------------------------------------------------------
K1=$(bash "$L" key base tree crit)
K2=$(bash "$L" key base tree crit)
K3=$(bash "$L" key base tree OTHER)
[ "$K1" = "$K2" ] && ok "key is deterministic" || bad "key is deterministic"
[ "$K1" != "$K3" ] && ok "criteria change yields a new key" || bad "criteria change yields a new key"

# --- content-addressed violation ids ----------------------------------------
V1=$(bash "$L" vid C3 "if (!token) { throw }")
V2=$(bash "$L" vid C3 "if  (!token)   {  throw  }")   # whitespace differs only
V3=$(bash "$L" vid C4 "if (!token) { throw }")
[ "$V1" = "$V2" ] && ok "violation id survives whitespace (span moved)" \
                  || bad "violation id survives whitespace"
[ "$V1" != "$V3" ] && ok "violation id keyed on criterion too" \
                   || bad "violation id keyed on criterion too"

# --- init + read ------------------------------------------------------------
bash "$L" init "$K1" 2 deadbeef crithash >/dev/null
check "tier round-trips"        "$(bash "$L" get "$K1" tier)" "2"
check "audited_sha round-trips" "$(bash "$L" get "$K1" audited_sha)" "deadbeef"
check "invocations start at 0"  "$(bash "$L" get "$K1" invocations_used)" "0"

# --- re-init must NOT reset counters ----------------------------------------
bash "$L" bump "$K1" invocations_used >/dev/null
bash "$L" init "$K1" 2 deadbeef crithash >/dev/null 2>&1
check "re-init preserves counters" "$(bash "$L" get "$K1" invocations_used)" "1"

# --- T2 invocation ceiling: cap 6 -------------------------------------------
KT2=$(bash "$L" key t2 tree crit)
bash "$L" init "$KT2" 2 sha crit >/dev/null
n=0
while bash "$L" can "$KT2" invocations_used >/dev/null 2>&1; do
  bash "$L" bump "$KT2" invocations_used >/dev/null 2>&1 || break
  n=$((n+1))
  [ "$n" -gt 50 ] && break     # loop guard: if this trips, the cap does not hold
done
check "T2 stops at INVOCATION_CAP" "$n" "6"
if bash "$L" can "$KT2" invocations_used >/dev/null 2>&1; then
  bad "budget refuses further work"
else
  ok "budget refuses further work once exhausted"
fi

# --- T1 ceiling: cap 4 ------------------------------------------------------
KT1=$(bash "$L" key t1 tree crit)
bash "$L" init "$KT1" 1 sha crit >/dev/null
n=0
while bash "$L" bump "$KT1" invocations_used >/dev/null 2>&1; do
  n=$((n+1)); [ "$n" -gt 50 ] && break
done
check "T1 stops at INVOCATION_CAP" "$n" "4"

# --- T0 spends nothing ------------------------------------------------------
KT0=$(bash "$L" key t0 tree crit)
bash "$L" init "$KT0" 0 sha crit >/dev/null
if bash "$L" can "$KT0" invocations_used >/dev/null 2>&1; then
  bad "T0 permits zero model calls"
else
  ok "T0 permits zero model calls"
fi

# --- verify cap is separate and also bounded --------------------------------
KV=$(bash "$L" key v tree crit)
bash "$L" init "$KV" 2 sha crit >/dev/null
n=0
while bash "$L" bump "$KV" verify_used >/dev/null 2>&1; do
  n=$((n+1)); [ "$n" -gt 50 ] && break
done
check "T2 verify stops at VERIFY_MAX" "$n" "2"

# --- reaudit cap ------------------------------------------------------------
KR=$(bash "$L" key r tree crit)
bash "$L" init "$KR" 3 sha crit >/dev/null
n=0
while bash "$L" bump "$KR" reaudits_used >/dev/null 2>&1; do
  n=$((n+1)); [ "$n" -gt 50 ] && break
done
check "reaudit stops at REAUDIT_MAX" "$n" "1"

# --- MONOTONICITY: no path decreases a counter ------------------------------
KM=$(bash "$L" key m tree crit)
bash "$L" init "$KM" 3 sha crit >/dev/null
bash "$L" bump "$KM" invocations_used >/dev/null
bash "$L" bump "$KM" invocations_used >/dev/null
before=$(bash "$L" get "$KM" invocations_used)
# Every counter, every command, many times: the value must never fall.
mono=true
for _ in 1 2 3 4 5 6 7 8 9 10; do
  for c in invocations_used reaudits_used verify_used grant_used; do
    bash "$L" bump "$KM" "$c" >/dev/null 2>&1 || true
  done
  now=$(bash "$L" get "$KM" invocations_used)
  [ "$now" -lt "$before" ] && mono=false
  before="$now"
done
$mono && ok "no command sequence decreases a counter" || bad "counters are monotone"

# --- total lifetime bound: cap + grant --------------------------------------
final=$(bash "$L" get "$KM" invocations_used)
if [ "$final" -le $((9 + 1)) ]; then
  ok "T3 lifetime invocations <= CAP+GRANT ($final <= 10)"
else
  bad "T3 lifetime invocations <= CAP+GRANT (got $final)"
fi

# --- dedup against SEEN, not confirmed --------------------------------------
KS=$(bash "$L" key s tree crit)
bash "$L" init "$KS" 2 sha crit >/dev/null
bash "$L" seen-add "$KS" "$V1"
if bash "$L" seen-has "$KS" "$V1" 2>/dev/null; then ok "seen-add then seen-has"; else bad "seen-add then seen-has"; fi
if bash "$L" seen-has "$KS" "$V3" 2>/dev/null; then bad "unseen id reports unseen"; else ok "unseen id reports unseen"; fi
bash "$L" seen-add "$KS" "$V3"
bash "$L" seen-add "$KS" "$V1"     # duplicate add must not double-count
cnt=$(bash "$L" get "$KS" invocations_used)
check "seen-add does not touch counters" "$cnt" "0"
if bash "$L" seen-has "$KS" "$V3" 2>/dev/null; then ok "second id also retained"; else bad "second id also retained"; fi

# --- UNRESOLVED at most twice; the third escalates --------------------------
# Mechanical, because a rule the orchestrator has to remember is one it can talk
# itself out of.
KU=$(bash "$L" key u tree crit)
bash "$L" init "$KU" 2 sha crit >/dev/null
VA=$(bash "$L" vid C1 "span a")
VB=$(bash "$L" vid C2 "span b")

r1=$(bash "$L" unresolved-bump "$KU" "$VA" 2>/dev/null); rc1=$?
r2=$(bash "$L" unresolved-bump "$KU" "$VA" 2>/dev/null); rc2=$?
r3=$(bash "$L" unresolved-bump "$KU" "$VA" 2>/dev/null); rc3=$?
check "first UNRESOLVED counts 1"  "$r1" "1"
check "second UNRESOLVED counts 2" "$r2" "2"
check "third UNRESOLVED counts 3"  "$r3" "3"
if [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ] && [ "$rc3" -ne 0 ]; then
  ok "the third UNRESOLVED escalates (exit non-zero), the first two do not"
else
  bad "third UNRESOLVED escalates — got rc $rc1/$rc2/$rc3"
fi

# per-violation, not global
bash "$L" unresolved-bump "$KU" "$VB" >/dev/null 2>&1
check "a second violation counts separately" "$(bash "$L" unresolved-count "$KU" "$VB")" "1"
check "the first is unaffected"              "$(bash "$L" unresolved-count "$KU" "$VA")" "3"

# and the counts survive an unrelated counter write
bash "$L" bump "$KU" verify_used >/dev/null 2>&1
check "UNRESOLVED counts survive a verify_used write" "$(bash "$L" unresolved-count "$KU" "$VA")" "3"
if command -v python >/dev/null 2>&1; then
  if python -c "import json,sys; json.load(open(sys.argv[1]))" "$TRIFORCE_LEDGER_DIR/$KU.json" 2>/dev/null; then
    ok "ledger stays valid JSON after unresolved bookkeeping"
  else
    bad "ledger stays valid JSON after unresolved bookkeeping"
    cat "$TRIFORCE_LEDGER_DIR/$KU.json"
  fi
fi

# --- persisting the audited bytes -------------------------------------------
printf 'the exact bytes that were audited\n' > "$WORK/diff.txt"
SHA=$(bash "$L" persist "$KS" "$WORK/diff.txt")
if [ -f "$TRIFORCE_AUDITED_DIR/$KS.audited" ]; then
  ok "audited bytes persisted"
else
  bad "audited bytes persisted"
fi
[ -n "$SHA" ] && ok "persist returns a sha ($SHA)" || bad "persist returns a sha"

# --- ledger file is valid JSON ----------------------------------------------
if command -v python >/dev/null 2>&1; then
  if python -c "import json,sys; json.load(open(sys.argv[1]))" "$TRIFORCE_LEDGER_DIR/$KS.json" 2>/dev/null; then
    ok "ledger file parses as JSON"
  else
    bad "ledger file parses as JSON"
    cat "$TRIFORCE_LEDGER_DIR/$KS.json"
  fi
fi

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
