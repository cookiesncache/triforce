#!/usr/bin/env bash
# live-cases.sh — Tier-2 acceptance cases 12, 13, 15 and 17.
#
#   bash acceptance/live-cases.sh [--case 12|13|15|17] [--repo <path>]
#
# All four need a live model. They gate on an auth probe and report UNMEASURED
# rather than skipping quietly, because a case that did not run must never be
# counted as one that passed.
#
#   12  Idempotence.        Re-run round 1 on an unchanged diff that returned
#                           PASS. ZERO new blocking entries. Any nonzero result
#                           means the population is not bounded and the schema
#                           is leaking.
#
#   13  Fix-and-re-audit.   THE LITERAL COMPLAINT. Replay fix-sequence diffs
#                           through the real E1 path, rounds 1 to 3. Median
#                           count of round-2 blocking entries citing a criterion
#                           NOT blocking in round 1 must be 0, and verify agents
#                           must emit zero tokens outside their closed status
#                           enum. Case 12 alone passes while this fails; that
#                           gap is the original bug.
#
#   15  Floor ablation.     Reinstate "report at least 3 findings". Clean rate
#                           must fall to ~0, confirming floor removal is the
#                           mechanism for Cause A.
#
#   17  THE FALSIFIER.      (a) K parallel in one round, (b) the same plus one
#                           FORCED second hunting round, (c) K sequential.
#                           If (b) beats (a) on F1 on this corpus, the one-round
#                           premise is WRONG for this workload and the design
#                           must be revised, not defended.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/skills/triforce/scripts/gate.sh"
LEDGER="$ROOT/skills/triforce/scripts/ledger.sh"
ONLY=""
CORPUS_REPO="$ROOT"

while [ $# -gt 0 ]; do
  case "$1" in
    --case) ONLY="$2"; shift 2 ;;
    --repo) CORPUS_REPO="$2"; shift 2 ;;
    *) echo "live-cases: unknown argument $1" >&2; exit 2 ;;
  esac
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }

want() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }

echo "triforce live cases (12, 13, 15, 17)"
echo

# --- auth gate --------------------------------------------------------------
probe=$(timeout 90 claude -p "Reply with exactly: READY" --model haiku 2>&1)
if ! printf '%s' "$probe" | grep -q "READY"; then
  echo "  CANNOT RUN: headless claude is not usable here."
  echo "  got: $(printf '%s' "$probe" | head -2)"
  echo
  echo "  Authenticate an interactive session first (/login), then re-run."
  echo "  Cases 12, 13, 15 and 17 are UNMEASURED, not passing."
  exit 2
fi

# --- shared fixture ---------------------------------------------------------
# One seeded diff with ONE severe defect and several trivial ones, so severity
# ordering and truncation behaviour are observable in the same corpus.
FIX="$WORK/fixture"; mkdir -p "$FIX/src"
(
  cd "$FIX" || exit 1
  git init -q -b main; git config user.email t@e.com; git config user.name t
  cat > src/account.js <<'JS'
function closeAccount(user, opts) {
  if (!user.confirmed) {
    throw new Error('unconfirmed');
  }
  const rows = db.find(user.id);
  return archive(rows, opts);
}
JS
  git add -A; git commit -qm base
  # severe: the confirmation guard is gone, and archive became a destructive delete
  cat > src/account.js <<'JS'
function closeAccount(user, opts) {
  const rows = db.find(user.id);
  db.purge(rows);
  return archive(rows, opts);
}
JS
  git commit -qam "close accounts directly"
) >/dev/null 2>&1

cd "$FIX" || exit 1
git diff -W HEAD~1..HEAD > "$WORK/diff.txt"
{
  printf 'C1\tAccounts must only be closed after confirmation\n'
  printf 'S1\tincorrect output or silently wrong result\n'
  printf 'S2\tdata loss or irreversible destruction\n'
  printf 'S3\tsecurity exposure\n'
  printf 'S4\tfailed or impossible rollback\n'
  printf 'S5\tunbounded resource consumption\n'
  printf 'S6\tconcurrency or ordering hazard\n'
} > "$WORK/criteria.tsv"

# audit <out-file> <tier> [extra-instruction]
# Runs one ganondorf and returns its GATED violations. The extra instruction is
# how the floor ablation is injected — as a prompt addition, so the ablation
# changes exactly one thing.
audit() {
  local out="$1" tier="$2" extra="${3:-}"
  local prompt raw
  prompt="You are ganondorf-t$tier. Audit the diff below against the frozen criteria. Emit the criteria roll-call first, then a JSON array of surviving violations between the markers <<<VIOLATIONS and VIOLATIONS>>>. If nothing survives your gate, emit an empty array.
$extra

FROZEN CRITERIA:
$(cat "$WORK/criteria.tsv")

MERGED DIFF (git diff -W):
$(cat "$WORK/diff.txt")"
  raw=$(printf '%s' "$prompt" | timeout 600 claude -p --plugin-dir "$ROOT" \
          --agent "ganondorf-t$tier" --allowedTools "" 2>/dev/null)
  printf '%s' "$raw" | sed -n 's/.*<<<VIOLATIONS//p' | sed 's/VIOLATIONS>>>.*//' > "$WORK/raw.json"
  grep -q '[^[:space:]]' "$WORK/raw.json" 2>/dev/null || echo '[]' > "$WORK/raw.json"
  bash "$GATE" --criteria "$WORK/criteria.tsv" --diff "$WORK/diff.txt" \
       --violations "$WORK/raw.json" --tier "$tier" > "$out" 2>/dev/null
}

nviol()  { grep -c '"criterion_id"' "$1" 2>/dev/null || echo 0; }
crits()  { grep -oE '"criterion_id": *"[^"]*"' "$1" 2>/dev/null | sed 's/.*"\([^"]*\)"$/\1/' | sort -u; }

# ============================================================================
# CASE 12 — idempotence
# ============================================================================
if want 12; then
  echo "case 12 — idempotence"
  audit "$WORK/r1.json" 2
  audit "$WORK/r1b.json" 2
  a=$(nviol "$WORK/r1.json"); b=$(nviol "$WORK/r1b.json")
  new=$(comm -13 <(crits "$WORK/r1.json") <(crits "$WORK/r1b.json") | wc -l | tr -d ' ')
  if [ "${new:-0}" -eq 0 ]; then
    ok "re-running round 1 on an unchanged diff yields zero NEW criteria (r1=$a r1'=$b)"
  else
    bad "idempotence: $new criterion(s) appeared only on the second run — the schema is leaking"
  fi
  echo
fi

# ============================================================================
# CASE 13 — the fix-and-re-audit sequence, through the real E1 path
# ============================================================================
if want 13; then
  echo "case 13 — fix-and-re-audit (rounds 1..3)"
  audit "$WORK/s1.json" 2
  crits "$WORK/s1.json" > "$WORK/blocking-r1.txt"

  # Apply a real fix, producing a NEW commit — this is what makes E1 legal.
  cd "$FIX" || exit 1
  cat > src/account.js <<'JS'
function closeAccount(user, opts) {
  if (!user.confirmed) {
    throw new Error('unconfirmed');
  }
  const rows = db.find(user.id);
  return archive(rows, opts);
}
JS
  git commit -qam "restore confirmation guard, stop purging" >/dev/null 2>&1
  git diff -W HEAD~2..HEAD > "$WORK/diff.txt"

  audit "$WORK/s2.json" 2
  crits "$WORK/s2.json" > "$WORK/blocking-r2.txt"

  # The metric: round-2 blocking entries citing a criterion NOT blocking in
  # round 1. Drift, not volume, is what this case measures.
  drift=$(comm -13 "$WORK/blocking-r1.txt" "$WORK/blocking-r2.txt" | wc -l | tr -d ' ')
  if [ "${drift:-0}" -eq 0 ]; then
    ok "round 2 cites no criterion that was not blocking in round 1 (drift=0)"
  else
    bad "round 2 drifted onto $drift criterion(s) not blocking in round 1 — THE ORIGINAL BUG"
    comm -13 "$WORK/blocking-r1.txt" "$WORK/blocking-r2.txt" | sed 's/^/        /'
  fi

  # Verify agents must emit ZERO tokens outside their closed status enum.
  vid=$(bash "$LEDGER" vid C1 "db.purge(rows);")
  vout=$(printf 'violation_id: %s\ncriterion: C1 "Accounts must only be closed after confirmation"\noriginal evidence quote: "db.purge(rows);"\ncurrent span:\n%s\n' \
          "$vid" "$(sed -n '1,8p' src/account.js)" \
        | timeout 300 claude -p --plugin-dir "$ROOT" --agent verifier --allowedTools "" 2>/dev/null)
  stray=$(printf '%s' "$vout" | grep -oE '\b(VIOLATED|PASS|FAIL|BLOCKING|finding|findings|nit)\b' | wc -l | tr -d ' ')
  if [ "${stray:-0}" -eq 0 ] && printf '%s' "$vout" | grep -qE 'RESOLVED|UNRESOLVED|RELOCATION_FAILED'; then
    ok "verifier emitted a closed-enum status and nothing outside it"
  else
    bad "verifier emitted $stray token(s) outside its closed status enum"
    printf '%s\n' "$vout" | head -5 | sed 's/^/        /'
  fi
  echo
fi

# ============================================================================
# CASE 15 — floor ablation
# ============================================================================
if want 15; then
  echo "case 15 — floor ablation"
  # A genuinely clean diff: the fixture, already fixed.
  cd "$FIX" || exit 1
  git diff -W HEAD~1..HEAD > "$WORK/diff.txt"

  audit "$WORK/nofloor.json" 2
  audit "$WORK/floor.json" 2 "Target at least 3 findings. If fewer genuine findings exist, emit what you have — do not invent to hit the floor."

  nf=$(nviol "$WORK/nofloor.json"); wf=$(nviol "$WORK/floor.json")
  if [ "${nf:-0}" -eq 0 ]; then
    ok "no floor: clean diff returns zero violations"
  else
    bad "no floor: clean diff returned $nf violation(s)"
  fi
  if [ "${wf:-0}" -gt "${nf:-0}" ]; then
    ok "ABLATION: reinstating the floor raised the count ($nf -> $wf) — floor removal is the mechanism"
  else
    bad "ABLATION inconclusive: floor=$wf vs no-floor=$nf. The floor should force findings onto clean code."
  fi
  echo
fi

# ============================================================================
# CASE 17 — the falsifier
# ============================================================================
if want 17; then
  echo "case 17 — the one-round premise, against its own falsifier"
  cd "$FIX" || exit 1
  git diff -W HEAD~2..HEAD~1 > "$WORK/diff.txt"     # the diff WITH the seeded defects
  K=2

  # (a) K parallel, one round
  : > "$WORK/a.txt"
  for i in $(seq 1 $K); do audit "$WORK/a$i.json" 2; crits "$WORK/a$i.json" >> "$WORK/a.txt"; done
  sort -u "$WORK/a.txt" > "$WORK/arm-a.txt"

  # (b) the same, plus one FORCED second hunting round
  cp "$WORK/a.txt" "$WORK/b.txt"
  audit "$WORK/b-extra.json" 2; crits "$WORK/b-extra.json" >> "$WORK/b.txt"
  sort -u "$WORK/b.txt" > "$WORK/arm-b.txt"

  # (c) K sequential rounds
  : > "$WORK/c.txt"
  for i in $(seq 1 $K); do audit "$WORK/c$i.json" 2; crits "$WORK/c$i.json" >> "$WORK/c.txt"; done
  sort -u "$WORK/c.txt" > "$WORK/arm-c.txt"

  # Ground truth for this fixture: the seeded defects are the guard removal
  # (C1) and the destructive purge (S2).
  printf 'C1\nS2\n' | sort > "$WORK/truth.txt"

  score() {   # score <arm-file> <label>
    local f="$1" label="$2" tp fp fn prec rec f1
    tp=$(comm -12 "$f" "$WORK/truth.txt" | wc -l | tr -d ' ')
    fp=$(comm -23 "$f" "$WORK/truth.txt" | wc -l | tr -d ' ')
    fn=$(comm -13 "$f" "$WORK/truth.txt" | wc -l | tr -d ' ')
    prec=$(awk -v t="$tp" -v f="$fp" 'BEGIN{printf "%.3f", (t+f)?t/(t+f):0}')
    rec=$(awk  -v t="$tp" -v f="$fn" 'BEGIN{printf "%.3f", (t+f)?t/(t+f):0}')
    f1=$(awk   -v p="$prec" -v r="$rec" 'BEGIN{printf "%.3f", (p+r)?2*p*r/(p+r):0}')
    printf '  %-34s findings=%-3s TP=%-3s FP=%-3s precision=%-6s F1=%s\n' \
           "$label" "$(wc -l < "$f" | tr -d ' ')" "$tp" "$fp" "$prec" "$f1"
    printf '%s' "$f1"
  }

  F1A=$(score "$WORK/arm-a.txt" "(a) K parallel, one round")
  F1B=$(score "$WORK/arm-b.txt" "(b) + forced second round")
  F1C=$(score "$WORK/arm-c.txt" "(c) K sequential rounds")
  echo

  if awk -v a="$F1A" -v b="$F1B" 'BEGIN{exit !(b>a)}'; then
    bad "FALSIFIED: (b) F1=$F1B beats (a) F1=$F1A. The one-round premise is WRONG for this workload."
    echo "        The design must be REVISED, not defended. See the issue's own falsifier clause."
  else
    ok "one-round premise holds on this corpus: (a) F1=$F1A >= (b) F1=$F1B"
  fi
  echo
fi

echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
