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
# Case 17's corpus. `hard` is the self-contained fixture and the default, so the
# case stays runnable with no external repo. `django` seeds the same defect
# classes into a REAL commit, so the surrounding code is realistic noise -- see
# the note in case 17.
CORPUS="hard"
DJ_HOST=""
# --verify-host: the evidence case 17's django corpus was always assuming.
#
# That corpus scores every citation outside {S1 S2 S4 S6} as a false positive,
# which is only sound if the reviewer returns CLEAN on the host commit's own
# change. The first attempt at that guard audited `git diff SHA^..SHA -- *.py`
# -- every python file, tests included, no seeds -- while case 17 audits
# library files only WITH seeds appended. A clean result on a superset does not
# certify the subset, and the guard was recorded as if it did. This mode audits
# the EXACT diff case 17 audits, minus the seeded commit, through the same
# audit(), the same criteria file and the same tier.
VERIFY_HOST=0
RUNS=3

while [ $# -gt 0 ]; do
  case "$1" in
    --case) ONLY="$2"; shift 2 ;;
    # ABSOLUTISED IMMEDIATELY. The shared fixture cds into a temp dir before
    # case 17 runs, so a relative --repo resolves against THAT and the corpus
    # check reports "'../django' is not a git repository" -- true where it
    # looked, and the wrong cause to hand a reader. Same class of misdiagnosis
    # as answering a missing `claude` with /login.
    --repo)
      if [ -d "$2" ]; then CORPUS_REPO="$(cd "$2" && pwd)"; else CORPUS_REPO="$2"; fi
      shift 2 ;;
    --corpus) CORPUS="$2"; shift 2 ;;
    --host) DJ_HOST="$2"; shift 2 ;;
    --verify-host) VERIFY_HOST=1; shift ;;
    --runs) RUNS="$2"; shift 2 ;;
    *) echo "live-cases: unknown argument $1" >&2; exit 2 ;;
  esac
done

# A ZERO-RUN VERIFICATION WOULD PASS. `seq 1 0` is empty, so the loop below
# would audit nothing, cite nothing, and report the host CLEAN -- a green that
# could not have been red, certifying a corpus nobody looked at.
case "$RUNS" in
  ''|*[!0-9]*) echo "live-cases: --runs needs a positive integer, got '$RUNS'." >&2; exit 2 ;;
esac
if [ "$RUNS" -lt 1 ]; then
  echo "live-cases: --runs must be at least 1. A verification that audits nothing" >&2
  echo "would report the host clean without looking at it." >&2
  exit 2
fi

if [ "$VERIFY_HOST" = 1 ] && [ "$CORPUS" != "django" ]; then
  echo "live-cases: --verify-host only means something with --corpus django." >&2
  echo "The 'hard' corpus has no host -- its diff is seeded defects and nothing else." >&2
  exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }

want() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }

echo "triforce live cases (12, 13, 15, 17)"
echo

# --- usability gate ---------------------------------------------------------
# TWO FAILURES LIVE HERE AND THEY ARE NOT THE SAME. This gate used to answer
# both with "Authenticate an interactive session first (/login)", which is a
# misdiagnosis whenever `claude` simply is not on PATH -- and that cost a real
# round trip on 2026-09-06.
#
#   NOT FOUND       PowerShell's `bash` is C:\WINDOWS\system32\bash.exe, which
#                   is WSL. claude.exe lives under the Windows profile and is
#                   not on WSL's PATH, so `timeout` reports "failed to execute
#                   process: No such file or directory". Nothing is wrong with
#                   the credentials. Run this from GIT BASH instead. Adding the
#                   Windows directory to WSL's PATH does NOT fix it: claude.exe
#                   cannot resolve /mnt/c/... paths.
#   NOT AUTHORISED  claude ran and refused. Git Bash says "Not logged in";
#                   PowerShell says "OAuth session expired and could not be
#                   refreshed". The second is the true diagnosis, and /login is
#                   the fix.
#
# Both are non-executions, and INVARIANT 10 makes them UNMEASURED either way --
# but a harness that names the wrong cause sends the reader to fix the wrong
# thing, which is its own kind of false report.
if ! command -v claude >/dev/null 2>&1; then
  echo "  CANNOT RUN: 'claude' is not on PATH in this shell."
  echo "  This is NOT an authentication problem."
  echo "  uname=$(uname -s 2>/dev/null || echo unknown)"
  echo
  echo "  If you launched this from PowerShell, its 'bash' is WSL"
  echo "  (C:\\WINDOWS\\system32\\bash.exe) and claude.exe is not on WSL's PATH."
  echo "  Run it from Git Bash instead:"
  echo "    & 'C:\\Program Files\\Git\\bin\\bash.exe' -lc 'cd /c/Users/simsc/Documents/Claude/Code/repos/triforce && bash acceptance/live-cases.sh --case 17'"
  echo
  echo "Cases 12, 13, 15 and 17 are UNMEASURED, not passing."
  exit 2
fi
probe=$(timeout 90 claude -p "Reply with exactly: READY" --model haiku 2>&1)
if ! printf '%s' "$probe" | grep -q "READY"; then
  echo "  CANNOT RUN: headless claude is not usable here."
  echo "  got: $(printf '%s' "$probe" | head -2)"
  echo
  case "$probe" in
    *"No such file or directory"*|*"not found"*|*"cannot execute"*)
      echo "  That is an EXECUTION failure, not an auth failure -- 'timeout' found"
      echo "  no claude to run. Re-read the shell note above; /login will not help." ;;
    *)
      echo "  Authenticate an interactive session first (/login), then re-run." ;;
  esac
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

# The corpus audit() reads. Cases 12, 13 and 15 use the shared fixture above.
# Case 17 points these at its own harder fixture instead of overwriting the
# shared files, so hardening the falsifier's corpus cannot silently change what
# the other three cases measure.
CRIT_FILE="$WORK/criteria.tsv"
DIFF_FILE="$WORK/diff.txt"

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
$(cat "$CRIT_FILE")

MERGED DIFF (git diff -W):
$(cat "$DIFF_FILE")"
  raw=$(printf '%s' "$prompt" | hl_claude --plugin-dir "${AUDIT_PLUGIN_DIR:-$ROOT}" \
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
  bash "$GATE" --criteria "$CRIT_FILE" --diff "$DIFF_FILE" \
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

# spans <gated.json> -- "criterion_id<TAB>file:line" for every entry.
#
# Case 12's FAIL says a criterion appeared only on the second run. That has two
# readings and the ids alone cannot separate them: the reviewer found something
# NEW, or it relabelled a defect it had already cited. Measured 2026-09-06 on an
# S4-only fixture, the reviewer emits ONE criterion per defect and which label
# it picks varies between runs -- so a relabel is the likelier reading and it is
# not a schema leak at all. The span is what tells them apart.
spans() {
  [ -n "$PY" ] || return 0
  "$PY" -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
if isinstance(d, dict):
    for v in d.values():
        if isinstance(v, list):
            d = v
            break
for v in (d if isinstance(d, list) else []):
    if isinstance(v, dict):
        print("%s\t%s:%s" % (v.get("criterion_id", ""), v.get("file", ""), v.get("line", "")))
' "$1" 2>/dev/null | tr -d '\r'
}

# cite <criterion_id> <gated.json...> -- the first matching entry, rendered as
# "file:line -- summary".
#
# Case 17's false positives were uninterpretable without this. On django host
# f30acb18 the FP in 2 of 3 runs was C1 -- the HOST COMMIT'S OWN SUBJECT -- and
# "FP=1" cannot say whether the reviewer invented something or made a defensible
# call about the seeded code. Precision drives every F1 gap between the arms
# once FPs exist, so an unreadable FP makes the whole comparison unreadable.
#
# If those citations turn out defensible, the truth set is penalising whichever
# arm searched hardest, which is the bias this corpus was built to avoid.
cite() {
  local id="$1"; shift
  [ -n "$PY" ] || return 0
  "$PY" -c '
import json, sys
want = sys.argv[1]
for path in sys.argv[2:]:
    try:
        d = json.load(open(path))
    except Exception:
        continue
    if isinstance(d, dict):
        for v in d.values():
            if isinstance(v, list):
                d = v
                break
    for v in (d if isinstance(d, list) else []):
        if isinstance(v, dict) and v.get("criterion_id") == want:
            txt = v.get("short_summary") or v.get("summary") or v.get("cited_text") or ""
            print("%s:%s -- %s" % (v.get("file", ""), v.get("line", ""), txt))
            sys.exit(0)
' "$id" "$@" 2>/dev/null | tr -d '\r'
}

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
    bad "idempotence: $new blocking criterion(s) appeared only on the second run"
    comm -13 "$WORK/blk-r1.txt" "$WORK/blk-r2.txt" | sed 's/^/        /'

    # WHICH KIND OF LEAK. "The schema is leaking" was asserted from the ids
    # alone, and the ids cannot support it. A criterion new to round 2 is either
    # a new citation, or the SAME defect relabelled -- and the reviewer was
    # measured emitting one criterion per defect, with the label varying between
    # runs. Those are different findings about the design: an unbounded
    # population versus non-deterministic labelling of a bounded one.
    spans "$WORK/r1.json"  > "$WORK/sp1.txt"
    spans "$WORK/r1b.json" > "$WORK/sp2.txt"
    if ! grep -q '[^[:space:]]' "$WORK/sp2.txt" 2>/dev/null; then
      echo "        (spans unavailable — cannot say whether this is a relabel or a"
      echo "        new citation. The FAIL stands; its CHARACTER is unmeasured.)"
    else
      _flip=0; _fresh=0
      while IFS= read -r _id; do
        [ -n "$_id" ] || continue
        _loc=$(awk -F'\t' -v i="$_id" '$1==i {print $2; exit}' "$WORK/sp2.txt")
        _prev=$(awk -F'\t' -v l="$_loc" '$2==l {print $1}' "$WORK/sp1.txt" | sort -u | tr '\n' ' ')
        if [ -n "$_loc" ] && [ -n "$_prev" ]; then
          echo "        $_id at $_loc — round 1 already cited that span as [$_prev]."
          echo "          SAME DEFECT, DIFFERENT LABEL. Not a new finding."
          _flip=$((_flip + 1))
        else
          echo "        $_id at ${_loc:-unknown} — round 1 cited nothing at that span."
          echo "          A genuinely new citation."
          _fresh=$((_fresh + 1))
        fi
      done < <(comm -13 "$WORK/blk-r1.txt" "$WORK/blk-r2.txt")
      echo "        character: $_flip relabel(s), $_fresh new citation(s)."
      if [ "$_fresh" -eq 0 ]; then
        echo "        Every leaked criterion sits on a span round 1 had ALREADY cited."
        echo "        The population is bounded and the LABELS are unstable. That is a"
        echo "        different defect from the one this case was written about, and a"
        echo "        smaller one — but it is still a FAIL, because a re-audit that"
        echo "        renames a finding makes the same defect look new to the user."
      else
        echo "        At least one leaked criterion cites a span round 1 never touched."
        echo "        That is the schema leak this case was written to catch."
      fi
    fi
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
  #
  # The clean state also has to be BIG ENOUGH to be worth inventing about. The
  # 2026-09-06 ablation came back floor=0 vs no-floor=0, pre-gate AND post-gate:
  # the floor manufactured nothing, so floor removal was not shown to be the
  # mechanism for Cause A. That is a statement about the corpus. A six-line
  # function offers a reviewer under "report at least 3 findings" nowhere to go
  # -- there is no surface to invent against, so the arm that should have
  # produced junk produced silence, and the ablation had nothing to compare.
  #
  # Every function below is deliberately, boringly correct: loops start at 0,
  # nothing is destructive, nothing is unbounded, nothing is order-dependent,
  # and C1 stays live rather than irrelevant -- closeAccount keeps its guard and
  # the new helpers respect confirmation. A reviewer that finds nothing here is
  # right. A reviewer under a floor has to invent to reach three.
  cd "$FIX" || exit 1
  cat > src/account.js <<'JS'
function closeAccount(user, opts) {
  if (!user.confirmed) {
    throw new Error('unconfirmed');
  }
  const rows = db.find(user.id);
  return archive(rows, opts);
}

function isClosable(user) {
  return user.confirmed === true;
}

function describeAccount(user) {
  if (user.confirmed) {
    return 'account ' + user.id + ' (confirmed)';
  }
  return 'account ' + user.id + ' (unconfirmed)';
}

function countClosable(users) {
  let n = 0;
  for (let i = 0; i < users.length; i++) {
    if (isClosable(users[i])) {
      n = n + 1;
    }
  }
  return n;
}

function partitionByConfirmation(users) {
  const confirmed = [];
  const pending = [];
  for (let i = 0; i < users.length; i++) {
    if (isClosable(users[i])) {
      confirmed.push(users[i]);
    } else {
      pending.push(users[i]);
    }
  }
  return { confirmed: confirmed, pending: pending };
}

module.exports = {
  closeAccount: closeAccount,
  isClosable: isClosable,
  describeAccount: describeAccount,
  countClosable: countClosable,
  partitionByConfirmation: partitionByConfirmation
};
JS
  git commit -qam "restore the guard, stop purging, add account helpers" >/dev/null 2>&1
  git diff -W HEAD~1..HEAD > "$WORK/diff.txt"
  if ! grep -q '[^[:space:]]' "$WORK/diff.txt" 2>/dev/null; then
    echo
    echo "  ABORT — case 15's clean diff is EMPTY. A reviewer handed nothing will"
    echo "  return nothing, and 'clean diff returns zero violations' would hold by"
    echo "  construction. Fix the fixture, do not report a pass."
    exit 2
  fi
  # Non-empty is not enough. The ABLATION needs surface, not just a diff: the
  # floor arm can only be shown to manufacture findings if there is something to
  # manufacture them about. Too small and floor=0 vs no-floor=0 is guaranteed
  # before the model is called, which is what 2026-09-06 measured.
  _c15add=$(grep -c '^+[^+]' "$WORK/diff.txt" 2>/dev/null || true)
  if [ "${_c15add:-0}" -lt 25 ]; then
    echo
    echo "  ABORT — case 15's clean diff adds only ${_c15add:-0} lines. A floor arm"
    echo "  has nothing to invent about at that size, so floor=0 vs no-floor=0 is"
    echo "  guaranteed by the corpus before the model is asked. That is not an"
    echo "  ablation. Enlarge the clean state, do not report the tie."
    exit 2
  fi

  # ---- THE ABLATION, applied where the instruction actually lives --------
  #
  # Appending "Report at least 3 findings." to the USER prompt is not an
  # ablation of the floor. The reviewer's own contract -- loaded into every one
  # of these audits by --agent ganondorf-t2 --plugin-dir -- says the opposite in
  # four separate places, and it wins. Measured floor=0 PRE-GATE on a six-line
  # clean diff (2026-09-03) and again on a fifty-line one (2026-09-06): the
  # reviewer did not invent findings and have them gated away, it refused the
  # floor outright. No corpus change can fix that, which is why enlarging the
  # corpus eightfold changed nothing.
  #
  # So the treatment replaces the CONTRACT, in a throwaway copy of the plugin.
  # INVARIANT 1 forbids a finding floor anywhere in the shipped plugin; building
  # the counterfactual you measure against is not shipping it, and $WORK is
  # removed on exit. Only agents/, hooks/, skills/, commands/ and the manifest
  # are copied -- .git and the corpus clone are large and irrelevant.
  FLOOR_DIR="$WORK/floor-plugin"
  mkdir -p "$FLOOR_DIR"
  for _d in .claude-plugin agents commands hooks skills; do
    [ -e "$ROOT/$_d" ] && cp -r "$ROOT/$_d" "$FLOOR_DIR/"
  done

  if [ -z "$PY" ]; then
    echo
    echo "  UNMEASURED  case 15: no working python interpreter, so the floor variant"
    echo "  cannot be built. The ablation is NOT run, and is not reported as a tie."
    exit 2
  fi
  "$PY" - "$FLOOR_DIR/agents/ganondorf-t2.md" <<'ABLATE'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8", newline="").read()

# The whole Anti-fabrication section is the no-floor contract. Replacing only
# its first sentence would leave "generating a candidate you cannot ground in
# the diff is the single worst outcome available to you" standing, which is the
# same instruction wearing a different hat -- the arm would still be untreated.
start = s.find("## Anti-fabrication")
end = s.find("## Terminals")
if start < 0 or end < 0 or end <= start:
    sys.exit("ABLATION ANCHOR MISSING")
s = s[:start] + """## Finding floor

Report **at least 3 findings**. A review returning fewer than three findings has
not looked hard enough. If you have fewer than three, go back over the diff and
keep looking until you have three.

A low finding count reflects on the quality of your review.

""" + s[end:]

old = ("The finding cap is a ceiling, not a target. Reaching it means the diff was\n"
       "unusually bad, not that you did the job properly. Nothing about this number\n"
       "implies a floor, and there is no floor.")
if old not in s:
    sys.exit("ABLATION CAP ANCHOR MISSING")
s = s.replace(old, "The finding cap is a ceiling. The floor above is a floor: three findings\nis the minimum, not a suggestion.")

io.open(p, "w", encoding="utf-8", newline="").write(s)
ABLATE
  _abl_rc=$?

  # A SILENTLY UNAPPLIED TREATMENT IS THE WHOLE FAILURE MODE OF THIS CASE.
  # If the anchors move, the "floor" arm becomes byte-identical to the control
  # and the ablation reports a tie that means nothing -- which is exactly the
  # result this case has produced twice already for a different reason. Verify
  # the treatment landed before spending a single audit on it.
  if [ "$_abl_rc" -ne 0 ] \
     || ! grep -q 'Report \*\*at least 3 findings\*\*' "$FLOOR_DIR/agents/ganondorf-t2.md" \
     || grep -q 'there is no floor' "$FLOOR_DIR/agents/ganondorf-t2.md"; then
    echo
    echo "  ABORT — case 15's ablation did not apply. The floor arm would be"
    echo "  byte-identical to the control and the two would tie for reasons that"
    echo "  say nothing about finding floors. An unapplied treatment must never be"
    echo "  reported as a null result."
    exit 2
  fi
  # and the control must be untouched, or this is a two-variable experiment.
  if ! grep -q 'there is no floor' "$ROOT/agents/ganondorf-t2.md"; then
    echo
    echo "  ABORT — the SHIPPED contract no longer forbids a floor. INVARIANT 1 is"
    echo "  violated and the ablation has no control. Revert before measuring."
    exit 2
  fi

  # Set and clear explicitly rather than as a `VAR=x audit ...` prefix: for a
  # FUNCTION, that assignment persists after the call in bash, so a later audit
  # would silently keep loading the floor variant.
  audit "$WORK/nofloor.json" 2
  AUDIT_PLUGIN_DIR="$FLOOR_DIR"
  audit "$WORK/floor.json" 2
  AUDIT_PLUGIN_DIR=""

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

  # ---- case 17's OWN corpus -----------------------------------------------
  # The shared fixture is a six-line function with three seeded defects, and on
  # 2026-09-03 all three arms scored TP=3/3, FP=0, F1=1.000 on it. The reviewer
  # saturates that corpus, so `b > a` was arithmetically unreachable and the
  # falsifier had no power to falsify anything. Hardening the SHARED fixture
  # would have changed what cases 12, 13 and 15 measure at the same time, so
  # case 17 builds its own and those three are left untouched.
  #
  # Five defects spread thin across three files, scored against the SAME seven
  # criteria, with S3 and S5 deliberately left CLEAN. That asymmetry is
  # load-bearing. If every criterion were violated, truth would equal the
  # criteria list, no citation could ever be a false positive, precision would
  # be pinned at 1.000, and F1 would collapse to pure recall -- under which arm
  # (b), a superset of arm (a) by construction, can only match or BEAT it. That
  # rigs the experiment FOR falsification, the mirror image of the ceiling that
  # rigged it against. Precision has to be able to fall, because the trade a
  # second round really makes is more recall against more invention.
  #
  # The untouched code is kept deliberately boring for the same reason: an
  # accidental sixth defect would score as a false positive and penalise
  # whichever arm searched hardest.
  if [ "$CORPUS" = "django" ]; then
    # ---- the django-seeded corpus ---------------------------------------
    # The hand-built fixture below is fully found by the reviewer: 5/5 with
    # FP=0 on three runs, so `b > a` is unreachable and the falsifier has no
    # power. That is a statement about hand-seeded fixtures, not about rounds,
    # and adding more defects of the same kind does not help -- each new one
    # gets found too.
    #
    # This corpus keeps the ground truth knowable (the defects are still mine)
    # while making the diff realistic: base is a real django commit's parent
    # state, head is that commit PLUS the seeded defects. django's own changes
    # become the noise a single round has to search through.
    #
    # THE HOST COMMIT MUST BE ONE THE REVIEWER RETURNS CLEAN ON, unseeded. If
    # it legitimately flags something in django's own diff, the truth set scores
    # that correct finding as a false positive, penalising whichever arm
    # searched hardest -- the same bias that adding S4 removed from the fixture
    # below. Verify a candidate before making it the host; do not adjust for it.
    [ -d "$CORPUS_REPO/.git" ] || {
      echo
      echo "  UNMEASURED  case 17: --corpus django needs --repo <django clone>."
      echo "  Resolved '$CORPUS_REPO', which has no .git directory."
      exit 2
    }
    [ -n "$DJ_HOST" ] || {
      echo
      echo "  UNMEASURED  case 17: --corpus django needs --host <sha>, and the sha"
      echo "  must be a commit the reviewer returns CLEAN on unseeded."
      exit 2
    }
    # THE HOST REQUIREMENT IS ENFORCED, NOT WRITTEN DOWN.
    #
    # It was prose for three days -- "THE HOST COMMIT MUST BE ONE THE REVIEWER
    # RETURNS CLEAN ON, unseeded" -- and prose does not stop a run. Two of the
    # three django runs used f30acb18, including the only one that fired the
    # falsifier, and nobody had checked it. A comment cannot notice that. The
    # allowlist can only be written by a --verify-host run, so the evidence and
    # the permission are the same artifact.
    VHOSTS="$ROOT/acceptance/verified-hosts.tsv"
    DJ_SHA="$(cd "$CORPUS_REPO" && git rev-parse "$DJ_HOST" 2>/dev/null)"
    if [ "$VERIFY_HOST" != 1 ]; then
      # A DISQUALIFICATION OUTRANKS A VERDICT, and no run can clear one.
      #
      # Verification only asks whether a citation survives WITHOUT the seeds.
      # That is necessary and not sufficient: on f30acb18 the reviewer cited S3
      # at options.py:2087 only in seeded runs, and reading django settled it as
      # a REAL scoping bypass -- the change-form action path builds its queryset
      # from _default_manager, bypassing ModelAdmin.get_queryset(), then filters
      # pk__in on pks taken straight from POST. A true finding the truth set
      # scores as a false positive, and no number of clean control runs can see
      # it. So a human judgement about the host outranks the machine verdict and
      # lives in a "#!DQ" line that the verification writer preserves and cannot
      # clear.
      _dq=$(awk -F'\t' -v s="$DJ_SHA" '$1=="#!DQ" && $2==s {print $3; exit}' "$VHOSTS" 2>/dev/null)
      if [ -n "$_dq" ]; then
        echo
        echo "  UNMEASURED  case 17: host $DJ_HOST is DISQUALIFIED."
        echo "  $_dq"
        echo "  Its truth set cannot be knowable, so no F1 from it is readable."
        exit 2
      fi
      _vrow=$(awk -F'\t' -v s="$DJ_SHA" '$1==s {print; exit}' "$VHOSTS" 2>/dev/null)
      _vverd=$(printf '%s' "$_vrow" | cut -f2)
      if [ -z "$_vrow" ]; then
        echo
        echo "  UNMEASURED  case 17: host $DJ_HOST has never been verified."
        echo "  Its arms score every citation outside {S1 S2 S4 S6} as a false"
        echo "  positive, which is only sound if the reviewer returns CLEAN on the"
        echo "  host's own change. Nobody has checked. Run the same command with"
        echo "  --verify-host before asking this corpus for a number."
        exit 2
      fi
      if [ "$_vverd" != "CLEAN" ]; then
        echo
        echo "  UNMEASURED  case 17: host $DJ_HOST is recorded $_vverd, not CLEAN."
        echo "  $(printf '%s' "$_vrow" | cut -f4) was cited on the host's OWN diff with nothing"
        echo "  seeded, so scoring it as a false positive penalises whichever arm"
        echo "  searched hardest -- the bias this corpus exists to avoid."
        echo "  Pick another host, or put that criterion in the truth set and"
        echo "  RECOMPUTE. Refusing to produce a number from this corpus."
        exit 2
      fi
    fi
    HFIX="$WORK/dj"; mkdir -p "$HFIX"
    DJ_SUBJ=$(cd "$CORPUS_REPO" && git log -1 --format=%s "$DJ_HOST" 2>/dev/null)
    # Library code only. django commits touch tests/ heavily, and a reviewer
    # auditing test changes is noise of a different kind than the noise wanted
    # here -- it invites findings about the tests rather than about the code.
    DJ_FILES=$(cd "$CORPUS_REPO" && git show --name-only --format="" "$DJ_HOST" \
               | grep '\.py$' | grep -v '^tests/' | head -6)
    if [ -z "$DJ_SUBJ" ] || [ -z "$DJ_FILES" ]; then
      echo
      echo "  UNMEASURED  case 17: host $DJ_HOST has no non-test python files, or"
      echo "  does not resolve in $CORPUS_REPO. Nothing was audited."
      exit 2
    fi
    (
      cd "$HFIX" || exit 1
      git init -q -b main; git config user.email t@e.com; git config user.name t
      for _f in $DJ_FILES; do
        mkdir -p "$(dirname "$_f")"
        (cd "$CORPUS_REPO" && git show "$DJ_HOST^:$_f" 2>/dev/null) > "$_f" || : > "$_f"
      done
      git add -A; git commit -qm "base"
      for _f in $DJ_FILES; do
        (cd "$CORPUS_REPO" && git show "$DJ_HOST:$_f" 2>/dev/null) > "$_f" || : > "$_f"
      done
      # THE HOST CHANGE AND THE SEEDS ARE SEPARATE COMMITS.
      #
      # They used to be one, and --verify-host would then have had to rebuild
      # the fixture a second way to get an unseeded diff -- reintroducing the
      # exact defect it exists to close, since a control built by different code
      # is not a control. Split, base..HEAD is byte-identical to what case 17
      # always audited (a diff between two trees does not care how many commits
      # separate them) and base..HEAD~1 is that same diff minus the seeds, from
      # the same base over the same files. The containment check below proves
      # the second is a subset of the first rather than assuming it.
      git commit -qam "host change"
      # ITERATE OVER THE DEFECTS, NOT THE FILES.
      #
      # This used to seed one defect per file, cycling. On a host with 2 library
      # files that seeded 2 defects while the ground truth claimed 4, so S4 and
      # S6 were unreachable and recall was capped at 2/4 BY THE FIXTURE. That is
      # the same class of mistake as scoring two criteria against one defect,
      # and it would have looked like the reviewer missing things.
      #
      # All four are always seeded; files are the cycling dimension, so with
      # fewer files some carry more than one. Each is an idiomatic django
      # antipattern mapping to exactly one criterion. C1 (the host commit's own
      # subject), S3 and S5 stay CLEAN, so precision can still fall.
      set -- $DJ_FILES
      _nf=$#
      _i=0
      for _def in S1 S2 S4 S6; do
        _i=$((_i + 1))
        _idx=$(( (_i - 1) % _nf + 1 ))
        eval "_tf=\${$_idx}"
        case "$_def" in
          S1) cat >> "$_tf" <<'PYDEF'


def _summarize_field_names(fields):
    total = 0
    for i in range(1, len(fields)):
        total += len(fields[i].name)
    return total
PYDEF
             ;;
          S2) cat >> "$_tf" <<'PYDEF'


def _purge_stale_entries(model, keys):
    model.objects.all().delete()
PYDEF
             ;;
          S4) cat >> "$_tf" <<'PYDEF'


def _migrate_profile(profile, settings_obj):
    profile.save()
    settings_obj.save()
    return True
PYDEF
             ;;
          S6) cat >> "$_tf" <<'PYDEF'


def _bump_usage(counter):
    current = counter.hits
    counter.hits = current + 1
    counter.save()
PYDEF
             ;;
        esac
      done
      git commit -qam "seeded defects"
    ) >/dev/null 2>&1

    cd "$HFIX" || exit 1
    HARD_BASE="$(git rev-parse HEAD~2)"
    HARD_SEEDED="$(git rev-parse HEAD)"
    HARD_HEAD="$HARD_SEEDED"
    # Verification audits the host change ALONE -- same base, same files, same
    # criteria, same audit(), one commit short. Resolved to SHAs immediately:
    # HEAD-relative names in the diff range are what killed the old case 17.
    [ "$VERIFY_HOST" = 1 ] && HARD_HEAD="$(git rev-parse HEAD~1)"
    {
      printf 'C1\t%s\n' "$DJ_SUBJ"
      printf 'S1\tincorrect output or silently wrong result\n'
      printf 'S2\tdata loss or irreversible destruction\n'
      printf 'S3\tsecurity exposure\n'
      printf 'S4\tfailed or impossible rollback\n'
      printf 'S5\tunbounded resource consumption\n'
      printf 'S6\tconcurrency or ordering hazard\n'
    } > "$WORK/hard-criteria.tsv"
    git diff -W "$HARD_BASE".."$HARD_HEAD" > "$WORK/hard-diff.txt"
    git diff -W "$HARD_BASE".."$HARD_SEEDED" > "$WORK/seeded-diff.txt"
    CRIT_FILE="$WORK/hard-criteria.tsv"
    DIFF_FILE="$WORK/hard-diff.txt"
    # Truth is the SEEDED defects only. C1 is the host commit's own subject and
    # the host was chosen because the reviewer returns clean on it, so C1, S3
    # and S5 are the criteria a citation can fall foul of.
    DJ_TRUTH=1
    _dloc=$(grep -c '^[+-][^+-]' "$WORK/hard-diff.txt" 2>/dev/null || true)
    echo "        corpus: django $DJ_HOST, ${_dloc:-0} changed lines, $(printf '%s' "$DJ_FILES" | wc -w | tr -d ' ') files"
    echo "        host subject (C1): $DJ_SUBJ"
  else
  HFIX="$WORK/hard"; mkdir -p "$HFIX/src"
  (
    cd "$HFIX" || exit 1
    git init -q -b main; git config user.email t@e.com; git config user.name t

    cat > src/session.js <<'JS'
const store = require('./store');

function createSession(user, token) {
  store.put(user.id, { token: token, createdAt: Date.now() });
  return { id: user.id };
}

function loadSession(id) {
  return store.get(id);
}

function touchSession(id) {
  const s = store.get(id);
  store.put(id, { token: s.token, createdAt: s.createdAt, seenAt: Date.now() });
}

module.exports = { createSession, loadSession, touchSession };
JS

    cat > src/export.js <<'JS'
const db = require('./db');

function collect(userId) {
  return db.find(userId);
}

function archiveRows(rows, opts) {
  return db.archive(rows, opts);
}

function exportForUser(userId, opts) {
  const rows = collect(userId);
  return archiveRows(rows, opts);
}

module.exports = { collect, archiveRows, exportForUser };
JS

    cat > src/billing.js <<'JS'
function lineTotal(item) {
  return item.price * item.qty;
}

function invoiceTotal(items) {
  let sum = 0;
  for (let i = 0; i < items.length; i++) {
    sum += lineTotal(items[i]);
  }
  return sum;
}

function applyRefund(invoice, amount) {
  if (amount > invoice.total) {
    throw new Error('refund exceeds invoice');
  }
  return invoice.total - amount;
}

module.exports = { lineTotal, invoiceTotal, applyRefund };
JS

    cat > src/migrate.js <<'JS'
const profiles = require('./profiles');
const settings = require('./settings');

function loadUser(id) {
  return profiles.get(id);
}

module.exports = { loadUser };
JS

    git add -A; git commit -qm base

    # ---- the seeded commit: SIX defects, over five of the seven criteria ----
    cat > src/session.js <<'JS'
const store = require('./store');

function createSession(user, token) {
  store.put(user.id, { token: token, createdAt: Date.now() });
  return { id: user.id };
}

function loadSession(id) {
  return store.get(id);
}

function touchSession(id) {
  const s = store.get(id);
  store.put(id, { token: s.token, createdAt: s.createdAt, seenAt: Date.now() });
}

function bumpUses(id) {
  const s = store.get(id);
  const n = s.uses;
  store.put(id, { token: s.token, createdAt: s.createdAt, uses: n + 1 });
}

module.exports = { createSession, loadSession, touchSession, bumpUses };
JS

    cat > src/export.js <<'JS'
const db = require('./db');

function collect(userId) {
  return db.find(userId);
}

function archiveRows(rows, opts) {
  return db.archive(rows, opts);
}

function exportForUser(userId, opts) {
  const rows = collect(userId);
  db.deleteRows(userId);
  return archiveRows(rows, opts);
}

function purgeAll(userId) {
  db.deleteRows(userId);
}

module.exports = { collect, archiveRows, exportForUser, purgeAll };
JS

    cat > src/billing.js <<'JS'
function lineTotal(item) {
  return item.price * item.qty;
}

function invoiceTotal(items) {
  let sum = 0;
  for (let i = 1; i < items.length; i++) {
    sum += lineTotal(items[i]);
  }
  return sum;
}

function applyRefund(invoice, amount) {
  return invoice.total - amount;
}

module.exports = { lineTotal, invoiceTotal, applyRefund };
JS

    cat > src/migrate.js <<'JS'
const profiles = require('./profiles');
const settings = require('./settings');

function loadUser(id) {
  return profiles.get(id);
}

function migrateUser(user) {
  profiles.insert(user.id, user.profile);
  settings.insert(user.id, user.settings);
  return true;
}

module.exports = { loadUser, migrateUser };
JS

    git commit -qam "add session bump, export purge helper, refund path, user migration"
  ) >/dev/null 2>&1

  cd "$HFIX" || exit 1
  # Pin the seeded range by SHA. HEAD-relative names are what killed the old
  # case 17: it read `HEAD~2..HEAD~1`, which needs three commits where that
  # fixture had two, so standalone it died with "unknown revision", wrote an
  # EMPTY diff, and every arm audited nothing.
  HARD_BASE="$(git rev-parse HEAD~1)"
  HARD_HEAD="$(git rev-parse HEAD)"
  {
    printf 'C1\tA refund must never exceed the invoice total\n'
    printf 'S1\tincorrect output or silently wrong result\n'
    printf 'S2\tdata loss or irreversible destruction\n'
    printf 'S3\tsecurity exposure\n'
    printf 'S4\tfailed or impossible rollback\n'
    printf 'S5\tunbounded resource consumption\n'
    printf 'S6\tconcurrency or ordering hazard\n'
  } > "$WORK/hard-criteria.tsv"
  git diff -W "$HARD_BASE".."$HARD_HEAD" > "$WORK/hard-diff.txt"
  CRIT_FILE="$WORK/hard-criteria.tsv"
  DIFF_FILE="$WORK/hard-diff.txt"
  DJ_TRUTH=0
  fi

  if ! grep -q '[^[:space:]]' "$DIFF_FILE" 2>/dev/null; then
    echo
    echo "  ABORT — case 17's seeded diff is EMPTY. Every arm would score zero and"
    echo "  the F1 comparison would be a tie between three nothings. THE FALSIFIER"
    echo "  MUST NOT REPORT A TIE IT DID NOT EARN."
    exit 2
  fi
  # ---- HOST VERIFICATION ---------------------------------------------------
  # Runs instead of the arms, never alongside them: this asks a question ABOUT
  # the corpus, and a number produced from a corpus that has not answered it
  # would be exactly the reading that has to stop.
  if [ "$VERIFY_HOST" = 1 ]; then
    echo "        VERIFYING THE HOST. Auditing $HARD_BASE..$HARD_HEAD -- the diff"
    echo "        case 17 audits, minus the seeded commit. $RUNS runs, tier 2."

    # The control has to be a SUBSET of the audited diff, or it is not a control
    # for it. Changed lines only: -W context can legitimately differ once the
    # seeds extend a file.
    _miss=$(comm -23 <(grep '^[+-][^+-]' "$DIFF_FILE" | sort -u) \
                     <(grep '^[+-][^+-]' "$WORK/seeded-diff.txt" | sort -u) | head -3)
    if [ -n "$_miss" ]; then
      echo
      echo "  ABORT — the control diff is NOT contained in the diff case 17 audits."
      echo "  A finding here would say nothing about a finding there. First missing:"
      printf '%s\n' "$_miss" | sed 's/^/    /'
      exit 2
    fi
    ok "control diff is a subset of the diff case 17 audits (same base, same files)"

    _dirty=""
    _clean=0
    for i in $(seq 1 "$RUNS"); do
      audit "$WORK/v$i.json" 2
      _c=$(crits "$WORK/v$i.json" | tr '\n' ' ')
      if [ -z "$_c" ]; then
        _clean=$((_clean + 1))
        echo "        run $i: CLEAN"
      else
        echo "        run $i: $_c"
        for _id in $(crits "$WORK/v$i.json"); do
          echo "          $_id  $(cite "$_id" "$WORK/v$i.json")"
          _dirty="$_dirty $_id"
        done
      fi
    done

    _uniq=$(printf '%s\n' $_dirty | grep -v '^[[:space:]]*$' | sort -u | tr '\n' ' ' | sed 's/ *$//')

    # ROWS ACCUMULATE, AND A CITATION IS STICKY.
    #
    # Overwriting was measured wrong on 2026-09-07: f30acb18 cited C1 on a
    # single-run verification and then returned clean three times in a row. A
    # writer that kept only the last result would have erased the one run that
    # carried the finding and published CLEAN 3/3. Cleanliness is the claim
    # needing evidence, one citation refutes it, and three quiet runs afterwards
    # do not restore it. So citations union, runs sum, and DIRTY never decays.
    _prow=$(awk -F'\t' -v s="$DJ_SHA" '$1==s {print; exit}' "$VHOSTS" 2>/dev/null)
    _pruns=$(printf '%s' "$_prow" | cut -f3); [ -n "$_pruns" ] || _pruns=0
    _pcit=$(printf '%s' "$_prow" | cut -f4); [ "$_pcit" = "-" ] && _pcit=""
    _allcit=$(printf '%s %s' "$_pcit" "$_uniq" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ *$//')
    _verd=CLEAN; [ -n "$_allcit" ] && _verd=DIRTY
    _truns=$((_pruns + RUNS))
    [ -f "$VHOSTS" ] || printf '%s\n' \
      '# Host verification for case 17 --corpus django. Data rows are written ONLY' \
      '# by --verify-host, and accumulate: runs sum, citations union, DIRTY is sticky.' \
      '# A "#!DQ" line is a HUMAN disqualification. It outranks any verdict and no' \
      '# run clears it -- verification cannot see a finding that needs the seeds.' \
      '# sha	verdict	runs	cited	date	fixture range (throwaway repo, NOT django shas)' > "$VHOSTS"
    # Two verifications running at once can LOSE a row -- each rewrites from
    # its own snapshot. Deliberately unlocked: the loss is fail-safe in one
    # direction only. A dropped row reads as "never verified" and aborts the
    # arms, and a dropped DIRTY row cannot resurface as CLEAN, because a clean
    # writer that never saw the citation drops the whole row rather than
    # rewriting its verdict. Re-run the verification; never hand-edit a verdict.
    awk -F'\t' -v s="$DJ_SHA" '$1 != s' "$VHOSTS" > "$WORK/vh.tmp"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$DJ_SHA" "$_verd" "$_truns" "${_allcit:--}" \
      "$(date +%Y-%m-%d)" "$HARD_BASE..$HARD_HEAD" >> "$WORK/vh.tmp"
    cp "$WORK/vh.tmp" "$VHOSTS"
    echo "        recorded $_verd over $_truns cumulative runs in acceptance/verified-hosts.tsv"

    if [ -z "$_allcit" ]; then
      ok "host $DJ_HOST returns CLEAN on the exact diff case 17 audits ($_clean/$RUNS this run, $_truns cumulative)"
      echo "        NECESSARY, NOT SUFFICIENT. This says the reviewer cites nothing"
      echo "        when the seeds are absent. It cannot see a citation that only"
      echo "        appears WITH them and is still true of the host's own code --"
      echo "        S3 at options.py:2087 on f30acb18 was exactly that. A clean"
      echo "        verification permits the host; it does not vouch for it."
    elif [ -z "$_uniq" ]; then
      bad "host $DJ_HOST returned clean $_clean/$RUNS here but has cited $_allcit before"
      echo "        A quiet run does not retire a citation. The row stays DIRTY."
    else
      bad "host $DJ_HOST is NOT clean on the exact diff: cited $_allcit"
      echo "        Case 17 scores truth as {S1 S2 S4 S6}, so every criterion above"
      echo "        is counted a FALSE POSITIVE while being a property of the HOST,"
      echo "        not of the seeded code. That penalises whichever arm searched"
      echo "        hardest -- the precise bias this corpus was built to avoid, and"
      echo "        the bias that decides every F1 gap between the arms."
      echo "        DISQUALIFY the host, or put these criteria in the truth set and"
      echo "        RECOMPUTE. Never annotate the F1 and keep it."
    fi
    echo
    echo "  $PASS passed, $FAIL failed"
    [ "$FAIL" -eq 0 ]
    exit $?
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

  # (c) K SEQUENTIAL rounds -- each round sees what the previous one cited.
  #
  # This was byte-identical to arm (a) -- K independent audits unioned -- and
  # was reported as such rather than silently passed off as sequential. What
  # makes it sequential is the chaining: round n+1 is told what round n found
  # and asked to look for what it missed.
  #
  # THE EMPTY-ARRAY ESCAPE IS LOAD-BEARING. "Report only what the previous
  # reviewer missed" is one careless sentence away from a finding floor, which
  # INVARIANT 1 forbids in any prompt, and a floor was measured manufacturing
  # false positives on a clean diff in case 15. The instruction says plainly
  # that missing nothing is an acceptable answer.
  #
  # Only chaining changes here. Whether a later round should be able to WITHDRAW
  # an earlier finding is a different intervention -- it changes authority as
  # well as chaining, and confounds the two -- so it is held as a separate arm
  # (d), gated on a corpus that actually produces false positives to withdraw.
  # Every arm of every run so far has scored FP=0, so arm (d) has nothing to
  # measure yet.
  : > "$WORK/c.txt"
  audit "$WORK/c1.json" 2
  crits "$WORK/c1.json" >> "$WORK/c.txt"
  for i in $(seq 2 $K); do
    _prev=$(sort -u "$WORK/c.txt" | tr '\n' ' ')
    audit "$WORK/c$i.json" 2 "A previous reviewer audited this exact diff and cited these criteria: ${_prev:-none}. Look for violations that reviewer missed, and do not restate the ones it already cited. If it missed nothing, emit an empty array — that is a complete and correct answer here."
    crits "$WORK/c$i.json" >> "$WORK/c.txt"
  done
  sort -u "$WORK/c.txt" > "$WORK/arm-c.txt"

  # (d) A REVISION round: it may DROP an earlier finding as well as add one.
  #
  # Deferred until now on purpose. Its only mechanism that (c) lacks is removing
  # a false positive, and until 2026-09-06 every arm of every run had scored
  # FP=0 -- so it would have measured nothing. The django corpus produced false
  # positives (C1 in 2 of 3 runs, S3 in 1), so the gate condition it was waiting
  # on is met and it has become measurable.
  #
  # STRUCTURALLY DIFFERENT FROM (c): arm (c) UNIONS its rounds, so a later round
  # can only add. Arm (d) REPLACES -- its score is the revision round's output
  # alone. Union it back in and withdrawal becomes unobservable, which would
  # make (d) a slower copy of (c).
  #
  # It changes authority as well as chaining, so it is a SEPARATE arm and never
  # a variant of (c): beating (a) as one combined change would not say which
  # half did it.
  #
  # The prompt must not read as a floor OR as pressure to withdraw. It offers
  # both directions and states plainly that an unchanged set and an empty set
  # are both complete answers. INVARIANT 1 is about floors, but a prompt that
  # leans on deletion would manufacture false CLEANS, which INVARIANT 10 cares
  # about at least as much.
  _prevd=$(tr '\n' ' ' < "$WORK/arm-a.txt")
  audit "$WORK/d1.json" 2 "A previous reviewer audited this exact diff and cited these criteria: ${_prevd:-none}. Check each of those citations against the diff yourself, then report the CORRECTED set: keep the ones the diff supports, drop any it does not, and add any the previous reviewer missed. If the previous set is exactly right, restate it unchanged — that is a complete answer. If nothing in this diff is a violation, emit an empty array — that is also a complete answer."
  crits "$WORK/d1.json" | sort -u > "$WORK/arm-d.txt"

  # Ground truth for this corpus, judged from the CODE and nothing else. Five
  # of the seven criteria are violated:
  #
  #   C1  applyRefund's `amount > invoice.total` guard was deleted, so a refund
  #       can now exceed the invoice it refunds.
  #   S1  invoiceTotal's loop starts at i = 1, silently dropping the first line
  #       item out of every total it returns.
  #   S2  exportForUser calls db.deleteRows BEFORE archiving, and purgeAll
  #       deletes unconditionally. Both destroy rows irreversibly.
  #   S4  migrateUser writes two stores with no transaction: if the second
  #       insert fails the first stands, with no compensating action and
  #       nothing to roll back to.
  #
  # S4 HAS ITS OWN DEFECT, and that is a correction, not decoration. It used to
  # be scored against the same delete-before-archive lines that violate S2 --
  # two criteria over one defect. Measured 2026-09-06 on an S4-only fixture, the
  # reviewer cites ONE criterion per defect: it reached S4 in 1 of 3 runs and
  # the competing domain criterion in 3 of 3. So when a defect satisfies both S2
  # and S4 and the reviewer labels it S2, S4 becomes unreachable and recall is
  # capped at 4/5 BY THE TRUTH SET rather than by the reviewer. Case 17's first
  # run on this corpus tied at F1=0.889 with exactly that cap in force -- a
  # ceiling again, subtler than the saturation ceiling it replaced, and just as
  # fatal to the comparison. Every criterion in truth now has a defect that is
  # uniquely its own.
  #   S6  bumpUses reads s.uses and writes n + 1 as two separate steps, so two
  #       concurrent bumps lose an increment. exportForUser's delete-before-
  #       archive ordering is legitimately citable here too.
  #
  # S3 and S5 are NOT violated, and a citation of either is a real false
  # positive. That is deliberate -- see the corpus note above. Nothing in the
  # untouched code is a defect, so precision can fall without punishing an arm
  # merely for reading carefully.
  #
  # The previous fixture's truth omitted S4 and scored a correct finding as a
  # false positive, penalising whichever arm searched hardest. Every criterion
  # a careful reviewer can defend from this diff is in the set above.
  if [ "${DJ_TRUTH:-0}" = "1" ]; then
    # django corpus: the seeded defects are S1, S2, S4 and S6. C1 is the host
    # commit's own subject, which the host satisfies -- that is why it was
    # chosen -- so C1, S3 and S5 are all clean and citing any of them is a real
    # false positive.
    printf 'S1\nS2\nS4\nS6\n' | sort > "$WORK/truth.txt"
  else
    printf 'C1\nS1\nS2\nS4\nS6\n' | sort > "$WORK/truth.txt"
  fi

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
  score "$WORK/arm-d.txt" "(d) revision round, may drop"; F1D="$SCORE_F1"
  TPD="$SCORE_TP"; FPD="$SCORE_FP"
  echo "        arm (c) chains: round n+1 is told what round n cited and asked"
  echo "        for what it missed, with an explicit empty-array escape so the"
  echo "        instruction is not a finding floor. Arm (d) is a REVISION round:"
  echo "        it may drop an earlier finding as well as add one, and its score"
  echo "        is that round's output ALONE, so a withdrawal is observable."
  echo "        (c) and (d) stay separate arms because (d) changes authority as"
  echo "        well as chaining, and one combined change would not say which"
  echo "        half of it moved the result."

  # WHICH criteria each arm cited, and which the reviewer never reached.
  # Without this the F1 column is uninterpretable. A three-way tie at the same
  # F1 can mean the arms agreed on the same set, or that they found DIFFERENT
  # sets of the same size -- and those support opposite conclusions about what a
  # second round buys. The equal numbers cannot tell them apart; the sets can.
  sort -u "$WORK/arm-a.txt" "$WORK/arm-b.txt" "$WORK/arm-c.txt" > "$WORK/anyarm.txt"
  comm -13 "$WORK/anyarm.txt" "$WORK/truth.txt" > "$WORK/missed.txt"
  printf '        cited by (a): %s\n' "$(tr '\n' ' ' < "$WORK/arm-a.txt")"
  printf '        cited by (b): %s\n' "$(tr '\n' ' ' < "$WORK/arm-b.txt")"
  printf '        cited by (c): %s\n' "$(tr '\n' ' ' < "$WORK/arm-c.txt")"
  printf '        cited by (d): %s\n' "$(tr '\n' ' ' < "$WORK/arm-d.txt")"
  # What the revision round actually DID to (a)'s set -- the only thing that
  # distinguishes this arm. Dropping nothing makes (d) a restatement of (a), and
  # its F1 then says nothing about withdrawal either way.
  comm -23 "$WORK/arm-a.txt" "$WORK/arm-d.txt" > "$WORK/d-dropped.txt"
  comm -13 "$WORK/arm-a.txt" "$WORK/arm-d.txt" > "$WORK/d-added.txt"
  printf '        (d) dropped from (a): [%s]  added: [%s]\n' \
    "$(tr '\n' ' ' < "$WORK/d-dropped.txt")" "$(tr '\n' ' ' < "$WORK/d-added.txt")"
  if ! grep -q '[^[:space:]]' "$WORK/d-dropped.txt" 2>/dev/null; then
    echo "        (d) withdrew NOTHING, so on this run it is a restatement of (a)"
    echo "        plus any additions. Its F1 is reported, but this run says nothing"
    echo "        about whether a revision round can remove a false positive."
  fi
  # NAME THE FALSE POSITIVES. The F1 gaps between arms are driven by precision
  # once FPs appear, and an id alone does not say whether a citation was really
  # wrong. Measured 2026-09-06 on django host f30acb18, C1 was cited in 2 of 3
  # runs and scored FP both times -- but C1 there is the HOST COMMIT'S OWN
  # SUBJECT, and whether a reviewer citing it is inventing or making a defensible
  # call about the seeded code cannot be told from "FP=1".
  #
  # If those citations are defensible, the truth set is penalising whichever arm
  # searched hardest, which is the bias this corpus was built to avoid. Printing
  # the ids is the minimum; a future run should retain the citation text.
  for _arm in a b c d; do
    [ -f "$WORK/arm-$_arm.txt" ] || : > "$WORK/arm-$_arm.txt"
    comm -23 "$WORK/arm-$_arm.txt" "$WORK/truth.txt" > "$WORK/fp-$_arm.txt"
  done
  if grep -q '[^[:space:]]' "$WORK/fp-a.txt" "$WORK/fp-b.txt" "$WORK/fp-c.txt" "$WORK/fp-d.txt" 2>/dev/null; then
    printf '        FALSE POSITIVES — (a): %s | (b): %s | (c): %s | (d): %s\n' \
      "$(tr '\n' ' ' < "$WORK/fp-a.txt")" \
      "$(tr '\n' ' ' < "$WORK/fp-b.txt")" \
      "$(tr '\n' ' ' < "$WORK/fp-c.txt")" \
      "$(tr '\n' ' ' < "$WORK/fp-d.txt")"
    echo "        These drive the precision term, so they drive the F1 gaps. An id"
    echo "        alone does not establish a citation was WRONG, so each is printed"
    echo "        with what it actually cited — judge it before reading a"
    echo "        low-precision arm as an inventing one."
    _afiles=""; _cfiles=""
    for i in $(seq 1 $K); do
      _afiles="$_afiles $WORK/a$i.json"; _cfiles="$_cfiles $WORK/c$i.json"
    done
    for _arm in a b c d; do
      case "$_arm" in
        a) _src="$_afiles" ;;
        b) _src="$_afiles $WORK/b-extra.json" ;;
        c) _src="$_cfiles" ;;
        d) _src="$WORK/d1.json" ;;
      esac
      while IFS= read -r _fpid; do
        [ -n "$_fpid" ] || continue
        # shellcheck disable=SC2086
        printf '          (%s) %-4s %s\n' "$_arm" "$_fpid" "$(cite "$_fpid" $_src)"
      done < "$WORK/fp-$_arm.txt"
    done
  fi
  if grep -q '[^[:space:]]' "$WORK/missed.txt" 2>/dev/null; then
    printf '        in truth, reached by NO arm: %s\n' "$(tr '\n' ' ' < "$WORK/missed.txt")"
    echo "        A criterion no arm reached is a SYSTEMATIC blind spot, not a"
    echo "        sampling miss. Extra rounds cannot recover what the reviewer"
    echo "        never finds, so this bounds what any (b) could have won."
  fi
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
  elif [ "$F1A" = "$F1B" ]; then
    # A TIE IS NOT A WIN, and reporting both as "holds" hides which one happened.
    # A tie is the outcome the premise predicts, so it does not falsify. But it
    # says the forced round changed NOTHING on this corpus -- neither recall nor
    # invention -- which is a narrower claim than (a) being better, and it is
    # the claim a cold session must be handed.
    ok "one-round premise holds on this corpus, as a TIE: (a) F1=$F1A = (b) F1=$F1B"
    echo "        The forced second round changed nothing: same criteria, no gain"
    echo "        in recall and no added invention. That is what the premise"
    echo "        predicts, but it is WEAKER than (a) winning outright. It shows"
    echo "        the extra round bought nothing HERE, not that it never can."
  else
    ok "one-round premise holds on this corpus: (a) F1=$F1A > (b) F1=$F1B"
  fi

  # THE SEQUENTIAL ARM, WHICH THE ISSUE'S CLAUSE DOES NOT COVER.
  #
  # The falsifier clause is written about arm (b): "if (b) beats (a) on F1, the
  # one-round premise is WRONG for this workload". That is quoted, not
  # paraphrased, and the chain above implements it unchanged.
  #
  # But arm (c) only became a real arm on 2026-09-06. Until then it was
  # byte-identical to (a), so there was nothing for a (c) comparison to say and
  # the verdict never made one. Now that (c) genuinely chains, it is ALSO a
  # multi-round arrangement, and if it beats (a) that is the same class of
  # evidence against "one round suffices" -- arrived at by a route the clause
  # happens not to name.
  #
  # Measured 2026-09-06, django host 804660d6: (a) and (b) both scored F1=0.857
  # citing S1 S2 S6, and (c) scored F1=1.000 citing S1 S2 S4 S6. The forced
  # extra INDEPENDENT round added nothing; the CHAINED round found the defect
  # both others missed, on the same audit budget as (a) and one fewer than (b).
  # The chain above printed "the premise holds, as a TIE" and was blind to it.
  #
  # Reported as its own finding rather than folded into the clause, because
  # answering a question the issue did not ask while using the words of the one
  # it did is the failure mode this file exists to avoid.
  if [ -n "$F1A" ] && [ -n "${F1C:-}" ] \
     && ! { [ "${TPA:-0}" -eq "${_truthn:-0}" ] && [ "${FPA:-0}" -eq 0 ]; }; then
    if awk -v a="$F1A" -v c="$F1C" 'BEGIN{exit !(c>a)}'; then
      bad "FALSIFIED BY THE SEQUENTIAL ARM: (c) F1=$F1C beats (a) F1=$F1A."
      echo "        Arm (c) uses the SAME number of audits as (a) and fewer than (b)."
      echo "        So this is not 'more compute wins' -- it is CHAINING winning."
      echo "        This is not the issue's literal clause, which names (b), but it is"
      echo "        the same class of evidence against the one-round premise. If it"
      echo "        replicates, the design is REVISED, not defended."
      echo "        cited by (a): $(tr '\n' ' ' < "$WORK/arm-a.txt")"
      echo "        cited by (c): $(tr '\n' ' ' < "$WORK/arm-c.txt")"
    else
      echo "  note  the sequential arm did not beat (a): (c) F1=$F1C vs (a) F1=$F1A."
    fi
    # The revision arm, on the same footing. It is the only arm that can RAISE
    # precision, so it is the one with a mechanism to beat (a) on a corpus where
    # extra rounds otherwise buy invention.
    if [ -n "${F1D:-}" ] && awk -v a="$F1A" -v d="$F1D" 'BEGIN{exit !(d>a)}'; then
      bad "FALSIFIED BY THE REVISION ARM: (d) F1=$F1D beats (a) F1=$F1A."
      echo "        A round that may WITHDRAW beat one round. That is evidence against"
      echo "        the one-round premise by the one mechanism (b) and (c) lack:"
      echo "        removing a false positive rather than adding a finding."
      echo "        Not the issue's literal clause, which names (b). Same class of"
      echo "        evidence. If it replicates, the design is REVISED, not defended."
    elif [ -n "${F1D:-}" ]; then
      echo "  note  the revision arm did not beat (a): (d) F1=$F1D vs (a) F1=$F1A."
    fi
  fi
  echo
fi

echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
