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

# --- dispositions: resolve and waive are append-only, idempotent, preserved --
# Case 16 (effective false positives) reads these. A disposition recorded twice
# must count once, and a counter write must not drop it.
KD=$(bash "$L" key d tree crit)
bash "$L" init "$KD" 2 sha crit >/dev/null
D1=$(bash "$L" vid C1 "d span 1"); D2=$(bash "$L" vid S2 "d span 2"); D3=$(bash "$L" vid S4 "d span 3")
bash "$L" seen-add "$KD" "$D1"; bash "$L" seen-add "$KD" "$D2"; bash "$L" seen-add "$KD" "$D3"
bash "$L" resolve "$KD" "$D1"; bash "$L" resolve "$KD" "$D1"
bash "$L" waive   "$KD" "$D2"; bash "$L" waive   "$KD" "$D2"
nres=$(sed -n 's/^  "resolved": \(.*\)$/\1/p' "$TRIFORCE_LEDGER_DIR/$KD.json" | grep -o '"[^"]*"' | grep -c .)
nwai=$(sed -n 's/^  "waived": \(.*\)$/\1/p'   "$TRIFORCE_LEDGER_DIR/$KD.json" | grep -o '"[^"]*"' | grep -c .)
check "resolve twice records one disposition" "$nres" "1"
check "waive twice records one disposition"   "$nwai" "1"
bash "$L" bump "$KD" verify_used >/dev/null 2>&1
nres2=$(sed -n 's/^  "resolved": \(.*\)$/\1/p' "$TRIFORCE_LEDGER_DIR/$KD.json" | grep -o '"[^"]*"' | grep -c .)
check "resolved survives a counter write" "$nres2" "1"
if command -v python >/dev/null 2>&1; then
  if python -c "import json,sys; json.load(open(sys.argv[1]))" "$TRIFORCE_LEDGER_DIR/$KD.json" 2>/dev/null; then
    ok "ledger stays valid JSON after resolve and waive"
  else
    bad "ledger stays valid JSON after resolve and waive"; cat "$TRIFORCE_LEDGER_DIR/$KD.json"
  fi
fi
# a ledger written before "resolved" existed gets the line inserted, not a rewrite
KO=$(bash "$L" key o tree crit)
bash "$L" init "$KO" 2 sha crit >/dev/null
sed -i '/"resolved":/d' "$TRIFORCE_LEDGER_DIR/$KO.json"
O1=$(bash "$L" vid C1 "old span"); bash "$L" seen-add "$KO" "$O1"; bash "$L" resolve "$KO" "$O1"
if grep -q "^  \"resolved\": \[\"$O1\"\],$" "$TRIFORCE_LEDGER_DIR/$KO.json" \
   && python -c "import json,sys; json.load(open(sys.argv[1]))" "$TRIFORCE_LEDGER_DIR/$KO.json" 2>/dev/null; then
  ok "a pre-disposition ledger gains the resolved line in place and stays valid JSON"
else
  bad "a pre-disposition ledger is not upgraded cleanly"; cat "$TRIFORCE_LEDGER_DIR/$KO.json"
fi

# --- rate: the case 16 reader ------------------------------------------------
# Its own directory, so the counts are exactly the fixture's. Three ledgers:
#   R1  3 cited, 1 resolved, 1 waived, 1 open, one violation escalated
#   R2  2 cited, 2 resolved
#   R3  0 cited                      (newest)
# Window 10 sees all three: cited 5, resolved 3, waived 1, open 1 -> 20% .. 40%.
# Window 1 sees only R3: nothing cited, so the rate must be UNDEFINED, not 0%.
RD="$WORK/ratedir"; mkdir -p "$RD"
export TRIFORCE_LEDGER_DIR="$RD"
R1=$(bash "$L" key r1 tree crit); bash "$L" init "$R1" 2 sha crit >/dev/null
A1=$(bash "$L" vid C1 "r1 a"); A2=$(bash "$L" vid S2 "r1 b"); A3=$(bash "$L" vid S4 "r1 c")
bash "$L" seen-add "$R1" "$A1"; bash "$L" seen-add "$R1" "$A2"; bash "$L" seen-add "$R1" "$A3"
bash "$L" resolve "$R1" "$A1"; bash "$L" waive "$R1" "$A2"
bash "$L" unresolved-bump "$R1" "$A3" >/dev/null 2>&1; bash "$L" unresolved-bump "$R1" "$A3" >/dev/null 2>&1; bash "$L" unresolved-bump "$R1" "$A3" >/dev/null 2>&1
sleep 1
R2=$(bash "$L" key r2 tree crit); bash "$L" init "$R2" 2 sha crit >/dev/null
B1=$(bash "$L" vid C1 "r2 a"); B2=$(bash "$L" vid S2 "r2 b")
bash "$L" seen-add "$R2" "$B1"; bash "$L" seen-add "$R2" "$B2"; bash "$L" resolve "$R2" "$B1"; bash "$L" resolve "$R2" "$B2"
sleep 1
R3=$(bash "$L" key r3 tree crit); bash "$L" init "$R3" 2 sha crit >/dev/null
before=$(cat "$RD"/*.json | sha1sum)
out=$(bash "$L" rate)
after=$(cat "$RD"/*.json | sha1sum)
check "rate: audits in window"  "$(printf '%s\n' "$out" | awk '/^audits/{print $2}')"    "3"
check "rate: cited"             "$(printf '%s\n' "$out" | awk '/^cited/{print $2}')"     "5"
check "rate: resolved"          "$(printf '%s\n' "$out" | awk '/^resolved/{print $2}')"  "3"
check "rate: waived"            "$(printf '%s\n' "$out" | awk '/^waived/{print $2}')"    "1"
check "rate: open"              "$(printf '%s\n' "$out" | awk '/^open/{print $2}')"      "1"
check "rate: escalated"         "$(printf '%s\n' "$out" | awk '/^escalated/{print $2}')" "1"
if printf '%s' "$out" | grep -qF 'not-useful 20.0% (waived only) .. 40.0% (waived + open)'; then
  ok "rate: lower bound is waived/cited, upper bound adds open"
else
  bad "rate: bounds wrong"; printf '%s\n' "$out"
fi
if printf '%s' "$out" | grep -qF 'PARTIAL' && printf '%s' "$out" | grep -qF 'NOT WIRED'; then
  ok "rate: says the window is partial and that the 5%/10% rule is not wired"
else
  bad "rate: silent about a partial window or about not acting"
fi
[ "$before" = "$after" ] && ok "rate reads and writes nothing" || bad "rate modified a ledger"
out1=$(bash "$L" rate 1)
if printf '%s' "$out1" | grep -qF 'rate       UNDEFINED' && ! printf '%s' "$out1" | grep -q '%'; then
  ok "rate: a window with nothing cited is UNDEFINED, never 0%"
else
  bad "rate: printed a percentage over zero citations"; printf '%s\n' "$out1"
fi
check "rate: window 1 is the NEWEST ledger (mtime order)" "$(printf '%s\n' "$out1" | awk '/^cited/{print $2}')" "0"
if TRIFORCE_LEDGER_DIR="$WORK/no-such-dir" bash "$L" rate | grep -qF 'nothing has been audited here'; then
  ok "rate: no ledger directory is reported as no data, not as a clean rate"
else
  bad "rate: an absent ledger directory was read as something"
fi
bash "$L" rate 0 >/dev/null 2>&1 && bad "rate 0 accepted" || ok "rate refuses a zero window"
export TRIFORCE_LEDGER_DIR="$WORK/.triforce/ledger"


echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
