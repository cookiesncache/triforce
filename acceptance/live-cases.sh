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
# shellcheck source=acceptance/headless.sh
. "$ROOT/acceptance/headless.sh"
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

# Pin the seeded-defect range NOW, by SHA, before any case commits on top of
# $FIX. Cases 13 and 15 both add commits, so HEAD-relative names do not mean the
# same thing depending on which cases ran -- and standalone they may not resolve
# at all. Case 17 used `HEAD~2..HEAD~1`, which needs three commits where the
# fixture has two: run as `--case 17` it died with "unknown revision", wrote an
# EMPTY diff, and every arm audited nothing.
SEED_BASE="$(git rev-parse HEAD~1)"
SEED_HEAD="$(git rev-parse HEAD)"
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
  local prompt raw pre
  # Each call keeps its OWN pre-gate array, named after its output file. It used
  # to write every call to the same $WORK/raw.json, so each overwrote the last
  # and the two arms of an ablation could not be compared before gating. Case 15
  # could not then distinguish "the floor produced nothing" from "the floor
  # produced findings the gate removed" -- and those are opposite conclusions.
  pre="${out%.json}.raw.json"
  prompt="You are ganondorf-t$tier. Audit the diff below against the frozen criteria. Emit the criteria roll-call first, then a JSON array of surviving violations between the markers <<<VIOLATIONS and VIOLATIONS>>>. If nothing survives your gate, emit an empty array.
$extra

FROZEN CRITERIA:
$(cat "$WORK/criteria.tsv")

MERGED DIFF (git diff -W):
$(cat "$WORK/diff.txt")"
  raw=$(printf '%s' "$prompt" | hl_claude --plugin-dir "$ROOT" \
          --agent "ganondorf-t$tier" --allowedTools "")
  # Extraction MUST be range-oriented — see the note in clean-corpus.sh. A
  # line-oriented `sed -n 's/.*<<<VIOLATIONS//p'` captures only the remainder of
  # the marker's own line, so every multi-line violations array was discarded
  # and every arm scored zero findings.
  #
  # INVARIANT 10: a truncated, crashed or timed-out reviewer can never PASS.
  # Here that matters twice over: a degenerate zero-finding arm would silently
  # corrupt the very comparisons these cases exist to make — case 17's F1 in
  # particular cannot falsify anything if every arm finds nothing.
  if ! printf '%s' "$raw" | grep -q '<<<VIOLATIONS' \
     || ! printf '%s' "$raw" | grep -q 'VIOLATIONS>>>'; then
    echo
    echo "  UNREVIEWABLE — the reviewer returned no parseable verdict for $out."
    echo "  A case that could not be read must never be counted as one that passed."
    echo "  Reporting UNMEASURED, not passing."
    exit 2
  fi
  printf '%s' "$raw" | hl_first_block > "$pre"
  grep -q '[^[:space:]]' "$pre" 2>/dev/null || echo '[]' > "$pre"
  bash "$GATE" --criteria "$WORK/criteria.tsv" --diff "$WORK/diff.txt" \
       --violations "$pre" --tier "$tier" > "$out" 2>/dev/null
}

# `grep -c` prints 0 AND exits 1 when it matches nothing, so the old
# `|| echo 0` fallback appended a SECOND zero and nviol returned two lines,
# each holding a 0. Every numeric test against that -- `[ "$nf" -eq 0 ]` -- died
# with "integer expression expected" and fell through to its else branch, which
# is the FAILING branch. Case 15's success condition (a clean diff returns zero
# violations) could therefore never be reported as a pass, and the UNMEASURED
# guards in cases 12 and 13 could never fire on the emptiness they exist to
# catch. One integer, always.
nviol()  { local n; n=$(grep -c '"criterion_id"' "$1" 2>/dev/null || true); printf '%s' "${n:-0}"; }
crits()  { grep -oE '"criterion_id": *"[^"]*"' "$1" 2>/dev/null | sed 's/.*"\([^"]*\)"$/\1/' | sort -u; }

# Find an interpreter that actually RUNS -- the same probe as gate.sh, for the
# same reason: on Windows `python3` is often a Store alias stub that exists on
# PATH and fails on execution.
PY=""
for cand in python python3 py; do
  if command -v "$cand" >/dev/null 2>&1 && "$cand" -c "print(1)" >/dev/null 2>&1; then
    PY="$cand"; break
  fi
done

# bcrits <gated.json> -- criterion ids of BLOCKING entries only, sorted unique.
#
# Cases 12 and 13 are both specified over blocking entries ("ZERO new BLOCKING
# entries"), but `crits` above is severity-blind, so a second-run `minor`
# finding tripped a check that was written about blockers. The gate emits each
# surviving candidate object unchanged, so `severity` IS present and filterable.
# Absent severity counts as `minor` -- exactly as gate.sh's own sort treats it --
# because a reviewer that omitted the field has not claimed a blocker.
#
# INVARIANT 10 applies to the filter itself. If it cannot parse, it must not
# quietly return an empty set: empty on both runs makes case 12's `comm -13`
# return 0 and manufactures a PASS out of a non-execution. Hence the hard exit,
# and hence every call site writes to a FILE -- never a process substitution,
# where `exit` would kill only the subshell and hand `comm` an empty stream.
#
# The `tr -d` strips the CR that Python's text-mode stdout adds on Windows;
# without it these ids sort and compare as "C1\r" against grep's plain "C1".
# `set -o pipefail` at the top of this file is load-bearing here: it is what
# lets a parse failure inside the pipeline still reach the `|| exit 2`.
bcrits() {
  if [ -z "$PY" ]; then
    echo "live-cases: no working python interpreter; blocking severity cannot be read" >&2
    echo "live-cases: refusing to emit an empty set, which would fake a clean result" >&2
    exit 2
  fi
  "$PY" -c '
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception as e:
    sys.stderr.write("live-cases: cannot parse %s: %s\n" % (sys.argv[1], e))
    sys.exit(2)
for i in sorted({c.get("criterion_id") or "" for c in data
                 if (c.get("severity") or "minor").lower() == "blocking"} - {""}):
    print(i)
' "$1" | tr -d '\r' || exit 2
}

# ============================================================================
# CASE 12 — idempotence
# ============================================================================
if want 12; then
  echo "case 12 — idempotence"
  audit "$WORK/r1.json" 2
  audit "$WORK/r1b.json" 2
  a=$(nviol "$WORK/r1.json"); b=$(nviol "$WORK/r1b.json")

  # The spec is written over BLOCKING entries. Count that population -- and
  # report the all-severity delta beside it rather than silently swapping
  # populations, so the next reader can see both numbers and judge for himself.
  bcrits "$WORK/r1.json"  > "$WORK/blk-r1.txt"
  bcrits "$WORK/r1b.json" > "$WORK/blk-r2.txt"
  crits  "$WORK/r1.json"  > "$WORK/all-r1.txt"
  crits  "$WORK/r1b.json" > "$WORK/all-r2.txt"
  new=$(comm -13 "$WORK/blk-r1.txt" "$WORK/blk-r2.txt" | wc -l | tr -d ' ')
  anynew=$(comm -13 "$WORK/all-r1.txt" "$WORK/all-r2.txt" | wc -l | tr -d ' ')
  nblk1=$(wc -l < "$WORK/blk-r1.txt" | tr -d ' ')

  # A run that found nothing at all on a seeded diff has no finding set whose
  # stability could be tested. Zero new blockers out of zero blockers is not
  # idempotence; it is a non-execution. INVARIANT 10.
  if [ "${a:-0}" -eq 0 ]; then
    echo "  UNMEASURED  case 12: round 1 returned no findings at all on a seeded diff,"
    echo "              so there is no finding set whose stability could be tested."
  elif [ "${new:-0}" -eq 0 ]; then
    ok "re-running round 1 on an unchanged diff yields zero NEW blocking criteria (r1=$a r1'=$b, blocking r1=$nblk1, all-severity new=$anynew)"
  else
    bad "idempotence: $new blocking criterion(s) appeared only on the second run — the schema is leaking"
    comm -13 "$WORK/blk-r1.txt" "$WORK/blk-r2.txt" | sed 's/^/        /'
  fi
  echo
fi

# ============================================================================
# CASE 13 — the fix-and-re-audit sequence, through the real E1 path
# ============================================================================
if want 13; then
  echo "case 13 — fix-and-re-audit (rounds 1..3)"
  audit "$WORK/s1.json" 2
  bcrits "$WORK/s1.json" > "$WORK/blocking-r1.txt"

  # Apply a real fix, producing a NEW commit — this is what makes E1 legal.
  #
  # The fix must NOT restore the base tree. It used to write back the base
  # content byte for byte, so `git diff HEAD~2..HEAD` was EMPTY: round 2 audited
  # nothing, found nothing, and drift=0 held by construction. That is a pass
  # that could not have failed — the same vacuity that once made case 3
  # meaningless. So the fix repairs C1 (the confirmation guard returns) and
  # deliberately LEAVES the destructive purge, which keeps S2 and S4 live and
  # keeps the round-2 diff non-empty. Drift can then actually be observed.
  cd "$FIX" || exit 1
  cat > src/account.js <<'JS'
function closeAccount(user, opts) {
  if (!user.confirmed) {
    throw new Error('unconfirmed');
  }
  const rows = db.find(user.id);
  db.purge(rows);
  return archive(rows, opts);
}
JS
  git commit -qam "restore confirmation guard" >/dev/null 2>&1
  git diff -W HEAD~2..HEAD > "$WORK/diff.txt"

  # and prove it, every run. An empty round-2 diff measures nothing at all.
  if ! grep -q '[^[:space:]]' "$WORK/diff.txt" 2>/dev/null; then
    echo
    echo "  ABORT — case 13's round-2 diff is EMPTY, so round 2 has nothing to audit."
    echo "  drift=0 would hold by construction. The fixture's fix has drifted back"
    echo "  into reproducing the base tree. Fix the fixture, do not report a pass."
    exit 2
  fi

  audit "$WORK/s2.json" 2
  bcrits "$WORK/s2.json" > "$WORK/blocking-r2.txt"

  # The metric: round-2 blocking entries citing a criterion NOT blocking in
  # round 1. Drift, not volume, is what this case measures.
  n1=$(nviol "$WORK/s1.json"); n2=$(nviol "$WORK/s2.json")
  drift=$(comm -13 "$WORK/blocking-r1.txt" "$WORK/blocking-r2.txt" | wc -l | tr -d ' ')
  if [ "${n1:-0}" -eq 0 ] && [ "${n2:-0}" -eq 0 ]; then
    echo "  UNMEASURED  case 13: neither round returned a finding on a seeded diff,"
    echo "              so drift=0 measures nothing. INVARIANT 10."
  elif [ "${drift:-0}" -eq 0 ]; then
    ok "round 2 cites no criterion that was not blocking in round 1 (drift=0)"
  else
    bad "round 2 drifted onto $drift criterion(s) not blocking in round 1 — THE ORIGINAL BUG"
    comm -13 "$WORK/blocking-r1.txt" "$WORK/blocking-r2.txt" | sed 's/^/        /'
  fi

  # Verify agents must emit ZERO tokens outside their closed status enum.
  vid=$(bash "$LEDGER" vid C1 "db.purge(rows);")
  vout=$(printf 'violation_id: %s\ncriterion: C1 "Accounts must only be closed after confirmation"\noriginal evidence quote: "db.purge(rows);"\ncurrent span:\n%s\n' \
          "$vid" "$(sed -n '1,8p' src/account.js)" \
        | HL_TIMEOUT=300 hl_claude --plugin-dir "$ROOT" --agent verifier --allowedTools "")
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
  # A genuinely clean diff -- built HERE, not inherited.
  #
  # This used to read `git diff HEAD~1..HEAD` and rely on case 13 having already
  # committed the fix. Run as `--case 15`, case 13 has NOT run: $FIX's HEAD is
  # the DEFECTIVE commit, so HEAD~1..HEAD is the defect-INTRODUCING diff and the
  # case audits a dirty diff while asserting the diff is clean. Every standalone
  # run measured the wrong thing. So case 15 now commits its own clean state.
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
  git commit -qam "restore the guard and stop purging" >/dev/null 2>&1
  git diff -W HEAD~1..HEAD > "$WORK/diff.txt"
  if ! grep -q '[^[:space:]]' "$WORK/diff.txt" 2>/dev/null; then
    echo
    echo "  ABORT — case 15's clean diff is EMPTY. A reviewer handed nothing will"
    echo "  return nothing, and 'clean diff returns zero violations' would hold by"
    echo "  construction. Fix the fixture, do not report a pass."
    exit 2
  fi

  # The floor arm must reinstate THE FLOOR. It used to say "Target at least 3
  # findings ... do not invent to hit the floor", which is a suggestion with an
  # escape hatch, not the quota invariant 1 forbids. Ablating a softened floor
  # cannot show that the floor is the mechanism. This is the literal text.
  audit "$WORK/nofloor.json" 2
  audit "$WORK/floor.json" 2 "Report at least 3 findings."

  nf=$(nviol "$WORK/nofloor.json");     wf=$(nviol "$WORK/floor.json")
  nfp=$(nviol "$WORK/nofloor.raw.json"); wfp=$(nviol "$WORK/floor.raw.json")
  echo "        post-gate: no-floor=$nf floor=$wf   |   pre-gate: no-floor=$nfp floor=$wfp"

  if [ "${nf:-0}" -eq 0 ]; then
    ok "no floor: clean diff returns zero violations"
  else
    bad "no floor: clean diff returned $nf violation(s)"
  fi

  # Post-gate is the right population for CLEAN RATE. It is the wrong population
  # for the causal claim, because the gate can delete exactly the inventions the
  # floor provoked. Read both, and name which of the two conclusions holds.
  if [ "${wf:-0}" -gt "${nf:-0}" ]; then
    ok "ABLATION: reinstating the floor raised the surviving count ($nf -> $wf) — floor removal is the mechanism"
  elif [ "${wfp:-0}" -gt "${nfp:-0}" ]; then
    bad "ABLATION, pre-gate only: the floor DID manufacture findings ($nfp -> $wfp pre-gate) and the GATE removed them ($nf -> $wf post-gate)."
    echo "        That is not an inconclusive result. The floor is harmful and the"
    echo "        gate is what contains it. Both facts belong in the write-up."
  else
    bad "ABLATION inconclusive: floor=$wf vs no-floor=$nf post-gate, $wfp vs $nfp PRE-gate."
    echo "        The floor produced nothing to gate away, so floor removal is NOT"
    echo "        shown to be the mechanism for Cause A on this corpus."
  fi
  echo
fi

# ============================================================================
# CASE 17 — the falsifier
# ============================================================================
if want 17; then
  echo "case 17 — the one-round premise, against its own falsifier"
  cd "$FIX" || exit 1
  git diff -W "$SEED_BASE".."$SEED_HEAD" > "$WORK/diff.txt"   # seeded-defect diff, by SHA
  if ! grep -q '[^[:space:]]' "$WORK/diff.txt" 2>/dev/null; then
    echo
    echo "  ABORT — case 17's seeded diff is EMPTY. Every arm would score zero and"
    echo "  the F1 comparison would be a tie between three nothings. THE FALSIFIER"
    echo "  MUST NOT REPORT A TIE IT DID NOT EARN."
    exit 2
  fi
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

  # Ground truth for this fixture, judged from the CODE and nothing else:
  #   C1  the confirmation guard was removed.
  #   S2  db.purge is destructive and irreversible.
  #   S4  purge runs BEFORE archive, so a failing archive leaves the rows
  #       already deleted with nothing to roll back to.
  # S4 was missing, and its absence scored a correct finding as a FALSE
  # POSITIVE. That penalised whichever arm searched hardest -- arm (b), the one
  # with an extra audit. Adding it makes falsification EASIER, not harder, so
  # this correction cannot be read as protecting the premise.
  printf 'C1\nS2\nS4\n' | sort > "$WORK/truth.txt"

  # score <arm-file> <label> -- prints the row, sets SCORE_F1.
  #
  # It used to printf the row AND the f1 to stdout and be called as
  # `F1A=$(score ...)`, so F1A captured the ENTIRE ROW plus the number. awk then
  # compared two non-numeric strings, which is a STRING comparison: "(b) ..."
  # sorts after "(a) ...", so `b>a` was TRUE unconditionally and this case
  # reported FALSIFIED on every run regardless of what the audits found. A
  # design would have been revised on the lexical order of two labels.
  score() {
    local f="$1" label="$2" tp fp fn prec rec f1
    tp=$(comm -12 "$f" "$WORK/truth.txt" | wc -l | tr -d ' ')
    fp=$(comm -23 "$f" "$WORK/truth.txt" | wc -l | tr -d ' ')
    fn=$(comm -13 "$f" "$WORK/truth.txt" | wc -l | tr -d ' ')
    prec=$(awk -v t="$tp" -v f="$fp" 'BEGIN{printf "%.3f", (t+f)?t/(t+f):0}')
    rec=$(awk  -v t="$tp" -v f="$fn" 'BEGIN{printf "%.3f", (t+f)?t/(t+f):0}')
    f1=$(awk   -v p="$prec" -v r="$rec" 'BEGIN{printf "%.3f", (p+r)?2*p*r/(p+r):0}')
    printf '  %-34s findings=%-3s TP=%-3s FP=%-3s precision=%-6s F1=%s\n' \
           "$label" "$(wc -l < "$f" | tr -d ' ')" "$tp" "$fp" "$prec" "$f1"
    SCORE_F1="$f1"; SCORE_TP="$tp"; SCORE_FP="$fp"
  }

  score "$WORK/arm-a.txt" "(a) K parallel, one round"; F1A="$SCORE_F1"
  TPA="$SCORE_TP"; FPA="$SCORE_FP"
  score "$WORK/arm-b.txt" "(b) + forced second round"; F1B="$SCORE_F1"
  score "$WORK/arm-c.txt" "(c) K sequential rounds";   F1C="$SCORE_F1"
  echo "        NOTE: arm (c) is NOT yet distinct from arm (a) — both are K"
  echo "        independent audits unioned, with no round-to-round chaining."
  echo "        Its number is reported, but it is not a sequential arm yet."
  echo

  # A tie between empty arms is not a corroboration, and a non-numeric F1 is
  # not a comparison. Refuse both rather than render a verdict either way.
  _na=$(wc -l < "$WORK/arm-a.txt" | tr -d ' ')
  _nb=$(wc -l < "$WORK/arm-b.txt" | tr -d ' ')
  case "$F1A$F1B" in
    ""|*[!0-9.]*)
      echo "  UNMEASURED  case 17: F1 did not evaluate to numbers (a='$F1A' b='$F1B')."
      echo "              No verdict is rendered. THE FALSIFIER MUST NOT GUESS."
      echo
      F1A="" ;;
  esac
  # A CEILING IS NOT A CORROBORATION.
  #
  # Arm (b) is arm (a) plus one extra audit, so b is a superset of a by
  # construction. If arm (a) already scored every ground-truth criterion with no
  # false positives, b cannot raise TP and can only add FPs -- `b > a` is
  # mathematically impossible and the comparison has zero power to falsify.
  # Observed 2026-09-03: all three arms returned TP=3/3, FP=0, F1=1.000 on a
  # six-line fixture with three seeded defects. The reviewer saturates this
  # corpus, so the falsifier cannot run on it. That is a statement about the
  # corpus, not about the one-round premise.
  _truthn=$(wc -l < "$WORK/truth.txt" | tr -d ' ')
  if [ -z "$F1A" ]; then
    :
  elif [ "${TPA:-0}" -eq "${_truthn:-0}" ] && [ "${FPA:-0}" -eq 0 ]; then
    echo "  UNINFORMATIVE  case 17: arm (a) already scored perfectly (TP=$TPA/$_truthn, FP=0)."
    echo "                 Arm (b) is arm (a) plus one audit, so b ⊇ a: it cannot beat a"
    echo "                 perfect score, only add false positives. The comparison had NO"
    echo "                 POWER TO FALSIFY. A ceiling is not a corroboration."
    echo "                 Harden the corpus before reading anything into (a) >= (b)."
    echo
  elif [ "${_na:-0}" -eq 0 ] && [ "${_nb:-0}" -eq 0 ]; then
    echo "  UNMEASURED  case 17: arms (a) and (b) both returned ZERO findings, so the"
    echo "              F1 comparison is a tie between two nothings. That is a"
    echo "              non-execution, not a corroboration of the one-round premise."
    echo
  elif awk -v a="$F1A" -v b="$F1B" 'BEGIN{exit !(b>a)}'; then
    bad "FALSIFIED: (b) F1=$F1B beats (a) F1=$F1A. The one-round premise is WRONG for this workload."
    echo "        The design must be REVISED, not defended. See the issue's own falsifier clause."
  else
    ok "one-round premise holds on this corpus: (a) F1=$F1A >= (b) F1=$F1B"
  fi
  echo
fi

echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
