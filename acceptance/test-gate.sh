#!/usr/bin/env bash
# test-gate.sh — the four checks, each with a candidate that must die on it.
#
# Assertions here are POSITIVE. Each negative case asserts the gate exited 0,
# dropped the candidate, AND named the specific check that killed it. Asserting
# "zero survivors" alone is satisfied by a gate that crashed and never ran —
# which is exactly what happened on the first run of this suite, going green on
# five checks against a broken interpreter.
#
# Also runs the ablation (acceptance case 14): with --disable every candidate
# survives. If the gate is load-bearing, that gap is large.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
G="$ROOT/skills/triforce/scripts/gate.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }

# --- a real repo, so the diff is a real `git diff -W` -----------------------
R="$WORK/repo"; mkdir -p "$R/src"; cd "$R" || exit 1
git init -q -b main >/dev/null 2>&1
git config user.email t@e.com; git config user.name t
cat > src/pay.js <<'JS'
function refund(order, amount) {
  if (amount <= 0) {
    throw new Error('bad amount');
  }
  const receipt = buildReceipt(order);
  audit(receipt);
  return gateway.refund(order.id, amount);
}

function unrelated() {
  return 1;
}
JS
git add -A >/dev/null 2>&1; git commit -qm base >/dev/null 2>&1

# Two defects in one commit:
#   a DELETION defect  — the guard is removed (nothing added)
#   an ADDITION defect — a new off-by-one line
cat > src/pay.js <<'JS'
function refund(order, amount) {
  const receipt = buildReceipt(order);
  audit(receipt);
  return gateway.refund(order.id, amount);
}

function unrelated() {
  const last = items[items.length];
  return last;
}
JS
git commit -qam "remove refund guard, index items" >/dev/null 2>&1
git diff -W HEAD~1..HEAD > "$WORK/diff.txt"

printf 'C1\tRefunds must reject non-positive amounts\n'  >  "$WORK/criteria.tsv"
printf 'S2\tdata loss or irreversible destruction\n'     >> "$WORK/criteria.tsv"

DEL_LINE=$(awk '/const receipt = buildReceipt/{print NR; exit}' src/pay.js)
ADD_LINE=$(awk '/items.length/{print NR; exit}' src/pay.js)

run()   { bash "$G" --criteria "$WORK/criteria.tsv" --diff "$WORK/diff.txt" \
                    --violations "$1" --tier "${2:-2}" 2>"$WORK/err.txt"; }
count() { tr -d ' \n' < "$1" | grep -o 'criterion_id' | wc -l | tr -d ' '; }

# killed_by <label> <violations-file> <CHECK>
killed_by() {
  local label="$1" file="$2" check="$3" rc
  run "$file" > "$WORK/out.json"; rc=$?
  if [ "$rc" -ne 0 ]; then
    bad "$label — gate exited $rc (never ran)"; sed -n '1,3p' "$WORK/err.txt"; return
  fi
  if [ "$(count "$WORK/out.json")" != "0" ]; then
    bad "$label — candidate survived"; return
  fi
  if ! grep -q "discarded \[$check\]" "$WORK/err.txt"; then
    bad "$label — dropped, but not by $check"; sed -n '1,4p' "$WORK/err.txt"; return
  fi
  ok "$label"
}

mkcand() {  # mkcand <out> <criterion_id> <quote> <file> <line> <verb> <severity>
  cat > "$1" <<JSON
[{"criterion_id":"$2","criterion_quote":"$3","severity":"$7",
  "file":"$4","line":$5,"cited_text":"x","fix_verb":"$6",
  "short_summary":"s","summary":"s","failure_scenario":"s"}]
JSON
}

echo "gate"
echo

Q1="Refunds must reject non-positive amounts"
Q2="data loss or irreversible destruction"

# --- 1. the DELETION defect must be citable ---------------------------------
mkcand "$WORK/del.json" C1 "$Q1" src/pay.js "$DEL_LINE" add-guard blocking
run "$WORK/del.json" > "$WORK/out.json"
if [ "$(count "$WORK/out.json")" = "1" ]; then
  ok "deletion defect is citable (removed guard)"
else
  bad "deletion defect is citable"; cat "$WORK/err.txt"
fi

# --- 2. the ADDITION defect must be citable ---------------------------------
mkcand "$WORK/add.json" C1 "$Q1" src/pay.js "$ADD_LINE" correct-bound major
run "$WORK/add.json" > "$WORK/out.json"
if [ "$(count "$WORK/out.json")" = "1" ]; then
  ok "addition defect is citable (new off-by-one)"
else
  bad "addition defect is citable"; cat "$WORK/err.txt"
fi

# --- 3. CRITERION: unknown id ------------------------------------------------
mkcand "$WORK/c1.json" C99 "$Q1" src/pay.js "$DEL_LINE" add-guard blocking
killed_by "CRITERION kills an unknown criterion id" "$WORK/c1.json" CRITERION

# --- 4. CRITERION: paraphrased quote ----------------------------------------
mkcand "$WORK/c2.json" C1 "Refunds should probably check amounts" src/pay.js "$DEL_LINE" add-guard blocking
killed_by "CRITERION kills a paraphrased quote" "$WORK/c2.json" CRITERION

# --- 5. BEHAVIOR-DELTA: cosmetic verb ---------------------------------------
mkcand "$WORK/c3.json" C1 "$Q1" src/pay.js "$DEL_LINE" clarify blocking
killed_by "BEHAVIOR-DELTA kills a cosmetic fix_verb" "$WORK/c3.json" BEHAVIOR-DELTA

# --- 6. RING: a file this diff never touched --------------------------------
mkcand "$WORK/c4.json" C1 "$Q1" src/elsewhere.js "$DEL_LINE" add-guard blocking
killed_by "RING kills a citation outside the diff" "$WORK/c4.json" RING

# --- 7. NOVELTY: a line the diff did not change -----------------------------
# `return gateway.refund(...)` sits inside refund(), which this diff DID modify,
# so it is inside the -W ring — but the line itself was never touched. This is
# the case RING alone cannot catch, and the reason NOVELTY is a separate check.
UNTOUCHED=$(awk '/return gateway.refund/{print NR; exit}' src/pay.js)
if [ -n "$UNTOUCHED" ]; then
  mkcand "$WORK/c5.json" C1 "$Q1" src/pay.js "$UNTOUCHED" add-guard blocking
  killed_by "NOVELTY kills an unchanged line inside the ring" "$WORK/c5.json" NOVELTY
else
  bad "NOVELTY fixture — could not locate an untouched in-ring line"
fi

# --- 8. severity ordering: SAFETY blocking sorts above a coverage minor ------
cat > "$WORK/order.json" <<JSON
[{"criterion_id":"C1","criterion_quote":"$Q1","severity":"minor",
  "file":"src/pay.js","line":$ADD_LINE,"fix_verb":"correct-bound",
  "short_summary":"nit","summary":"a nit","failure_scenario":"x"},
 {"criterion_id":"S2","criterion_quote":"$Q2","severity":"blocking",
  "file":"src/pay.js","line":$DEL_LINE,"fix_verb":"add-guard",
  "short_summary":"data loss","summary":"destructive","failure_scenario":"y"}]
JSON
run "$WORK/order.json" > "$WORK/out.json"
FIRST=$(tr -d ' \n' < "$WORK/out.json" | grep -o '"criterion_id":"[^"]*"' | head -1)
if [ "$FIRST" = '"criterion_id":"S2"' ]; then
  ok "severity-first ordering (SAFETY blocking sorts above coverage minor)"
else
  bad "severity-first ordering — first was $FIRST"; cat "$WORK/out.json"
fi

# --- 9. malformed JSON is a hard stop, never a silent PASS ------------------
printf 'not json at all' > "$WORK/bad.json"
if run "$WORK/bad.json" > "$WORK/out.json"; then
  bad "malformed output must exit non-zero"
else
  ok "malformed output exits non-zero (caller reports UNREVIEWABLE)"
fi

# --- 10. THE ABLATION (acceptance case 14) ----------------------------------
cat > "$WORK/ablate.json" <<JSON
[{"criterion_id":"C99","criterion_quote":"$Q1","severity":"minor","file":"src/pay.js","line":$DEL_LINE,"fix_verb":"add-guard","short_summary":"s","summary":"s","failure_scenario":"s"},
 {"criterion_id":"C1","criterion_quote":"paraphrased","severity":"minor","file":"src/pay.js","line":$DEL_LINE,"fix_verb":"add-guard","short_summary":"s","summary":"s","failure_scenario":"s"},
 {"criterion_id":"C1","criterion_quote":"$Q1","severity":"minor","file":"src/pay.js","line":$DEL_LINE,"fix_verb":"clarify","short_summary":"s","summary":"s","failure_scenario":"s"},
 {"criterion_id":"C1","criterion_quote":"$Q1","severity":"minor","file":"src/elsewhere.js","line":$DEL_LINE,"fix_verb":"add-guard","short_summary":"s","summary":"s","failure_scenario":"s"}]
JSON
run "$WORK/ablate.json" > "$WORK/gated.json"
GATED=$(count "$WORK/gated.json")
bash "$G" --criteria "$WORK/criteria.tsv" --diff "$WORK/diff.txt" \
          --violations "$WORK/ablate.json" --tier 2 --disable > "$WORK/ungated.json" 2>/dev/null
UNGATED=$(count "$WORK/ungated.json")
if [ "$GATED" = "0" ] && [ "$UNGATED" = "4" ]; then
  ok "ABLATION: gated=$GATED ungated=$UNGATED — the gate is load-bearing"
else
  bad "ABLATION: gated=$GATED ungated=$UNGATED (want 0 and 4)"
fi

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
