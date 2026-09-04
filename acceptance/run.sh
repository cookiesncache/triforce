#!/usr/bin/env bash
# run.sh — the triforce acceptance suite.
#
#   bash acceptance/run.sh
#
# Runs every case that can run without a live model, reports the rest as
# DEFERRED with a reason. A deferred case is never counted as a pass. If you
# see a green run, read the deferred list before believing it.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

SUITES=0; SUITES_OK=0
DEFERRED=()

run_suite() {
  local name="$1" script="$2"
  SUITES=$((SUITES + 1))
  echo
  echo "=============================================================="
  echo " $name"
  echo "=============================================================="
  if bash "$script"; then
    SUITES_OK=$((SUITES_OK + 1))
  fi
}

defer() { DEFERRED+=("$1"); }

echo "triforce acceptance"

# --- static checks ----------------------------------------------------------
echo
echo "=============================================================="
echo " static"
echo "=============================================================="
SPASS=0; SFAIL=0
sok()  { printf '  ok    %s\n' "$1"; SPASS=$((SPASS+1)); }
sbad() { printf '  FAIL  %s\n' "$1"; SFAIL=$((SFAIL+1)); }

# manifests
if claude plugin validate .claude-plugin/plugin.json >/dev/null 2>&1; then
  sok "plugin.json validates"; else sbad "plugin.json validates"; fi
if claude plugin validate .claude-plugin/marketplace.json >/dev/null 2>&1; then
  sok "marketplace.json validates"; else sbad "marketplace.json validates"; fi
if python -c "import json,sys;json.load(open('hooks/hooks.json'))" 2>/dev/null; then
  sok "hooks.json is valid JSON"; else sbad "hooks.json is valid JSON"; fi

# filename == frontmatter name
mism=0
for f in agents/*.md; do
  n=$(sed -n 's/^name: //p' "$f" | head -1); b=$(basename "$f" .md)
  [ "$n" = "$b" ] || { mism=1; echo "      $b != $n"; }
done
[ "$mism" -eq 0 ] && sok "every agent filename matches its frontmatter name" \
                  || sbad "every agent filename matches its frontmatter name"

# forbidden frontmatter keys — these fail SILENTLY at runtime (unknown keys are
# telemetried, not rejected), so a static check is the only place they surface.
if grep -q "allowed-tools" agents/*.md 2>/dev/null; then
  sbad "no 'allowed-tools' in agents (it is a skill/command field)"
else
  sok "no 'allowed-tools' in agents (it is a skill/command field)"
fi
if grep -qE "^effort:[[:space:]]*xhigh" agents/*.md 2>/dev/null; then
  sbad "no 'xhigh' effort in agents (enum is low|medium|high|max)"
else
  sok "no 'xhigh' effort in agents (enum is low|medium|high|max)"
fi

# model pins are ALIASES, never dated ids — dated ids do not survive a release
if grep -hE "^model:" agents/*.md | grep -qE "[0-9]{8}|-[0-9]{4}-"; then
  sbad "model pins are aliases, not dated ids"
else
  sok "model pins are aliases, not dated ids"
fi
for pin in "zelda:opus" "link:sonnet" "verifier:sonnet"            "ganondorf-t1:sonnet" "ganondorf-t2:opus" "ganondorf-t3:fable"; do
  a="${pin%%:*}"; m="${pin##*:}"
  if grep -qE "^model: $m\$" "agents/$a.md" 2>/dev/null; then
    sok "$a pinned to $m"
  else
    sbad "$a pinned to $m (got '$(sed -n 's/^model: //p' "agents/$a.md" | head -1)')"
  fi
done
if grep -hE "^model:" agents/*.md | grep -q "inherit"; then
  sbad "no agent resolves to 'inherit'"; else sok "no agent resolves to 'inherit'"; fi

# the skill entry point
if grep -q "^agent: zelda" skills/triforce/SKILL.md; then
  sok "/triforce pins zelda via agent:"; else sbad "/triforce pins zelda via agent:"; fi

# ganondorf tier variants stay in sync with the shared contract
if bash acceptance/gen-ganondorf.sh --check >/dev/null 2>&1; then
  sok "ganondorf tier variants in sync with the shared contract"
else
  sbad "ganondorf tier variants in sync with the shared contract"
fi

# ACCEPTANCE CASE 9, second half: the orchestrator contains no loop over the
# generator. A `while` around a reviewer dispatch is the failure this design
# exists to prevent, so it is checked mechanically rather than trusted.
if grep -nE '^\s*while .*(audit|ganondorf|review|Agent)' agents/zelda.md skills/triforce/SKILL.md 2>/dev/null; then
  sbad "no while-loop over the generator in the orchestrator"
else
  sok "no while-loop over the generator in the orchestrator"
fi

# no finding floor anywhere, in any tier — Cause A in one grep
if grep -rniE "at least [0-9]+ (finding|issue)|minimum of [0-9]+ finding|target of [0-9]+ finding" \
     agents/ skills/ 2>/dev/null; then
  sbad "no finding floor in any agent or reference"
else
  sok "no finding floor in any agent or reference"
fi

# verify() must be structurally incapable of generating. Its schema has no
# findings array, and the closed status enum is the whole contract.
if grep -qE '"(findings|violations)"' agents/verifier.md 2>/dev/null; then
  sbad "verifier has no findings/violations array in its schema"
else
  sok "verifier has no findings/violations array in its schema"
fi
missing=""
for st in RESOLVED UNRESOLVED RELOCATION_FAILED; do
  grep -q "$st" agents/verifier.md 2>/dev/null || missing="$missing $st"
done
[ -z "$missing" ] && sok "verifier carries all three statuses"                   || sbad "verifier is missing:$missing"
if grep -q "explicitly not \`RESOLVED\`" agents/verifier.md 2>/dev/null; then
  sok "RELOCATION_FAILED is explicitly not RESOLVED"
else
  sbad "RELOCATION_FAILED is explicitly not RESOLVED"
fi
# the verifier must not be handed the diff
if grep -q "You do not receive the diff" agents/verifier.md 2>/dev/null; then
  sok "the diff is withheld from the verifier"
else
  sbad "the diff is withheld from the verifier"
fi
# tools: [] on both non-writing agents makes the firewall a type, not a request
for a in verifier ganondorf-t1 ganondorf-t2 ganondorf-t3; do
  if grep -qE '^tools: \[\]$' "agents/$a.md" 2>/dev/null; then
    sok "$a has no file tools"
  else
    sbad "$a has no file tools"
  fi
done
# the /triforce:verify entry point forks and defaults to the cheap mode
if grep -q "^context: fork" commands/verify.md 2>/dev/null; then
  sok "verify command uses context: fork (self-contained, no user input)"
else
  sbad "verify command uses context: fork"
fi
if grep -q -- "--re-audit" commands/verify.md 2>/dev/null; then
  sok "the generative mode requires an explicit --re-audit"
else
  sbad "the generative mode requires an explicit --re-audit"
fi

# TIER-1: the plugin installs from the pinned SHA and reports its full inventory.
# Only meaningful when it is actually installed; skipped, never faked, otherwise.
if claude plugin list 2>/dev/null | grep -q "triforce@"; then
  inv=$(claude plugin details triforce 2>/dev/null)
  miss=""
  for c in ganondorf-t1 ganondorf-t2 ganondorf-t3 link verifier zelda triforce verify; do
    printf '%s' "$inv" | grep -q "$c" || miss="$miss $c"
  done
  [ -z "$miss" ] && sok "Tier-1: installed plugin lists every agent and skill"                  || sbad "Tier-1: inventory is missing:$miss"
else
  echo "  skip  Tier-1 inventory — triforce is not installed in this environment"
fi

# The README carries SHAPE, not figures: "No dollar figures, benchmark
# percentages, or context-window numbers: those go stale and the README is not
# where they should live." The project's own acceptance bars (70/50) are spec
# constants, not benchmarks, so they are allowed.
stale=$(grep -oE "[0-9]+(\.[0-9]+)?%|\$[0-9]" README.md 2>/dev/null         | grep -vE "^(70|50)%$" || true)
if [ -z "$stale" ]; then
  sok "README carries no benchmark figures (they go stale; the issue holds them)"
else
  sbad "README carries figures that will go stale: $(printf '%s' "$stale" | tr '
' ' ')"
fi

# the disclosure sentence must survive verbatim
if grep -q "They were not audited." skills/triforce/references/terminals.md; then
  sok "PASS_FIX_DELTA_UNAUDITED carries its disclosure sentence verbatim"
else
  sbad "PASS_FIX_DELTA_UNAUDITED carries its disclosure sentence verbatim"
fi

# --- the live harnesses' violation extraction -------------------------------
# A line-oriented extraction captures only the remainder of the marker's own
# line, silently discards every multi-line violations array, and turns each
# audit into a PASS. That defect made clean-corpus.sh report 100% regardless of
# what any auditor found. These checks are offline on purpose: they exercise the
# idiom itself, so the class cannot regress without a live model to notice it.
_xtr="$(mktemp)"
printf 'roll-call\n<<<VIOLATIONS\n[\n  {"criterion_id": "S3", "severity": "blocking"}\n]\nVIOLATIONS>>>\nCOMPLETE\n' > "$_xtr"
_got=$(sed -n '/<<<VIOLATIONS/,/VIOLATIONS>>>/p' "$_xtr" | sed '1d;$d' | grep -c '"criterion_id"')
if [ "${_got:-0}" -eq 1 ]; then
  sok "extraction recovers a MULTI-LINE violations array (the 100% bug)"
else
  sbad "extraction lost a multi-line violations array — every audit becomes a false PASS"
fi

# and neither harness may still carry the line-oriented idiom in LIVE CODE.
# Comment lines are stripped first: both harnesses quote the old idiom verbatim
# to document why it was wrong, and that documentation must not trip the check.
_live=0
for _h in acceptance/clean-corpus.sh acceptance/live-cases.sh; do
  grep -vE '^[[:space:]]*#' "$_h" 2>/dev/null \
    | grep -qF "s/.*<<<VIOLATIONS//p" && _live=1
done
if [ "$_live" -eq 0 ]; then
  sok "no live harness executes the line-oriented extraction"
else
  sbad "a live harness still executes the line-oriented extraction"
fi

# INVARIANT 10: markerless output must not be readable as an empty array
for _h in acceptance/clean-corpus.sh acceptance/live-cases.sh; do
  if grep -q "grep -q '<<<VIOLATIONS'" "$_h" 2>/dev/null; then
    sok "$(basename "$_h") treats a markerless reviewer reply as UNREVIEWABLE, not PASS"
  else
    sbad "$(basename "$_h") can still read a crashed/truncated reply as zero findings"
  fi
done
rm -f "$_xtr"

# --- the probe harness's own fixture ----------------------------------------
# probe-harness.sh case 3 is the highest-value live test: it asserts an executor
# branches from the ORCHESTRATOR's HEAD, not the default branch. It is also the
# easiest test in the repo to pass for the wrong reason -- if the orchestrator's
# commit is reachable from main, the assertion holds no matter where the
# executor branched. That is exactly what happened: the fixture wrote src/app.js
# into a directory it never created, the commit silently never happened, and
# ORCH_COMMIT was main's own tip. Cases 3-4 were green and meaningless.
#
# So this runs the harness's REAL fixture block, lifted from the file rather
# than restated here, and checks the two properties case 3 depends on. A
# restated copy could drift back into agreement with a broken original; this
# cannot.
_fx="$(mktemp)"
sed -n '/^# --- a scratch repo with the prerequisite set correctly/,/^MAIN_BEFORE=/p'   acceptance/probe-harness.sh | sed '$d' > "$_fx"
if [ -s "$_fx" ] && grep -q 'ORCH_COMMIT=' "$_fx"; then
  _fxout=$(
    WORK="$(mktemp -d)"
    # shellcheck disable=SC1090
    . "$_fx" >/dev/null 2>&1 || { echo "SETUP_ABORTED"; rm -rf "$WORK"; exit 0; }
    printf 'TRACKED=%s ' "$(git ls-files | tr '
' ',')"
    if git merge-base --is-ancestor "$ORCH_COMMIT" main 2>/dev/null; then
      printf 'ORCH_ON_MAIN=yes'
    else
      printf 'ORCH_ON_MAIN=no'
    fi
    cd / && rm -rf "$WORK"
  )
  case "$_fxout" in
    *"src/app.js"*) sok "probe fixture actually creates the file its commits depend on" ;;
    *)              sbad "probe fixture does not track src/app.js (got: $_fxout)" ;;
  esac
  case "$_fxout" in
    *ORCH_ON_MAIN=no) sok "probe fixture: case 3 cannot pass vacuously (orch commit is off main)" ;;
    *)               sbad "probe fixture: orchestrator commit is reachable from main -- case 3 is vacuous" ;;
  esac
else
  sbad "could not lift the probe harness fixture block (its markers moved)"
fi
rm -f "$_fx"

# and the guard that makes the above a hard stop rather than a silent green.
if grep -q 'merge-base --is-ancestor "\$ORCH_COMMIT" main' acceptance/probe-harness.sh; then
  sok "probe-harness aborts rather than report a vacuous case 3"
else
  sbad "probe-harness has no guard against a vacuous case 3"
fi

# A NON-EXECUTION IS NOT A DEFECT. Both live cases in probe-harness dispatch an
# agent that can decline, be sandbox-refused, or crash. Case 3 once reported
# "executors are building on the DEFAULT BRANCH" because a compound command was
# refused, and case 6 once reported indiscriminate cleanup because the executor
# was never dispatched at all. Each needs a branch that says UNMEASURED.
# `|| true`, not `|| echo 0`: grep -c already prints 0 when it matches nothing,
# and exits 1 doing it, so `|| echo 0` appends a SECOND zero and the arithmetic
# test below dies on a two-line value. See the nviol check above.
_unmeas=$(grep -c 'UNMEASURED  case' acceptance/probe-harness.sh 2>/dev/null || true)
if [ "${_unmeas:-0}" -ge 3 ]; then
  sok "probe-harness reports UNMEASURED for a non-execution instead of a defect"
else
  sbad "probe-harness can still score a declined or refused dispatch as a defect ($_unmeas guards)"
fi

# and case 3's assertion must not depend on shell plumbing the sandbox refuses.
# Comment lines are stripped first: the file quotes the refused idiom verbatim
# to record why it was replaced, and that documentation must not trip the check.
if grep -vE '^[[:space:]]*#' acceptance/probe-harness.sh | grep -q 'ANCESTOR=\$?'; then
  sbad "case 3 still asks for a compound command; the sandbox refuses it intermittently"
else
  sok "case 3 asserts via a bare command, with no exit-code plumbing to refuse"
fi

# --- the counter every one of those guards is built on -----------------------
# nviol() decides whether a round found anything. `grep -c` prints 0 and exits
# 1 on no match, so a `|| echo 0` fallback emits a SECOND zero and the function
# returns two lines. `[ "$n" -eq 0 ]` then dies with "integer expression
# expected" and takes the else branch -- the FAILING one. That made case 15's
# success condition unreportable and made the UNMEASURED guards inert on
# exactly the emptiness they exist to catch. Lifted and RUN, not grepped.
_nv="$(mktemp)"
sed -n '/^nviol()/p' acceptance/live-cases.sh > "$_nv"
if [ -s "$_nv" ]; then
  _nvd="$(mktemp -d)"
  echo '[]' > "$_nvd/empty.json"
  # shaped like real gate output -- `json.dump(kept, ..., indent=2)`, one field
  # per line -- because nviol counts matching LINES, not matches.
  cat > "$_nvd/two.json" <<'JSON'
[
  {
    "criterion_id": "C1",
    "severity": "blocking"
  },
  {
    "criterion_id": "S2",
    "severity": "minor"
  }
]
JSON
  # shellcheck disable=SC1090
  _n0=$( . "$_nv"; nviol "$_nvd/empty.json" )
  _n2=$( . "$_nv"; nviol "$_nvd/two.json" )
  if [ "$_n0" = "0" ] && [ "$_n2" = "2" ]; then
    sok "nviol returns one integer (empty=0, two=2), so the numeric guards can fire"
  else
    sbad "nviol does not return a single integer (empty='$_n0' two='$_n2')"
  fi
  rm -rf "$_nvd"
else
  sbad "could not lift nviol from live-cases.sh"
fi
rm -f "$_nv"

# --- cases 12 and 13 must count the population they are specified over -------
# Both are written about BLOCKING entries ("ZERO new blocking entries"), but the
# harness extracted every criterion_id regardless of severity, so a second-run
# `minor` finding tripped a check about blockers. Case 12's first non-degenerate
# run FAILED on exactly that. The filter is lifted from the file and RUN here,
# not grepped for, because a filter that exists but does not filter is the same
# false green as no filter at all.
_bc="$(mktemp)"
sed -n '/^PY=""$/,/^}$/p' acceptance/live-cases.sh > "$_bc"
if [ -s "$_bc" ] && grep -q 'bcrits()' "$_bc"; then
  _bcd="$(mktemp -d)"
  cat > "$_bcd/g.json" <<'JSON'
[
  {"criterion_id": "S2", "severity": "blocking"},
  {"criterion_id": "C1", "severity": "blocking"},
  {"criterion_id": "S1", "severity": "minor"},
  {"criterion_id": "S3"},
  {"criterion_id": "C1", "severity": "blocking"}
]
JSON
  # shellcheck disable=SC1090
  _got=$( . "$_bc" >/dev/null 2>&1; bcrits "$_bcd/g.json" 2>/dev/null | tr '\n' ',' )
  if [ "$_got" = "C1,S2," ]; then
    sok "bcrits keeps blocking only -- minor and severity-absent entries are dropped"
  else
    sbad "bcrits does not filter by severity (got '$_got', want 'C1,S2,')"
  fi
  # and it must refuse rather than hand back an empty set it did not earn
  echo 'not json' > "$_bcd/bad.json"
  if ( . "$_bc" >/dev/null 2>&1; bcrits "$_bcd/bad.json" ) >/dev/null 2>&1; then
    sbad "bcrits returns an empty set on unparseable input -- that fakes idempotence"
  else
    sok "bcrits refuses unparseable input instead of returning an empty set"
  fi
  rm -rf "$_bcd"
else
  sbad "could not lift the blocking-severity filter from live-cases.sh (its markers moved)"
fi
rm -f "$_bc"

# The blocking files must be written by the filtered helper, in both cases.
if grep -vE '^[[:space:]]*#' acceptance/live-cases.sh \
   | grep -qE '^[[:space:]]*crits[[:space:]].*(blocking-r|blk-r)'; then
  sbad "a blocking population is still written by the severity-blind crits()"
else
  sok "cases 12 and 13 both read their blocking population through bcrits"
fi

# bcrits hard-exits when it cannot parse. Inside <(...) that exit kills only the
# subshell and hands comm an empty stream -- the refusal becomes a silent pass.
if grep -vE '^[[:space:]]*#' acceptance/live-cases.sh | grep -qF '<(bcrits'; then
  sbad "bcrits is called in a process substitution; its refusal cannot escape a subshell"
else
  sok "bcrits is never called in a process substitution, so a refusal stops the run"
fi

# Case 12 previously printed only a count, which told the next session nothing.
if sed -n '/^# CASE 12/,/^# CASE 13/p' acceptance/live-cases.sh | grep -qF 'comm -13 "$WORK/blk-r1.txt" "$WORK/blk-r2.txt" | sed'; then
  sok "case 12 names the criteria that leaked, not just how many"
else
  sbad "case 12 still reports a bare count with no leaked ids"
fi

# A NON-EXECUTION IS NOT A DEFECT, here too: zero new blockers out of zero
# findings is not idempotence, and drift=0 between two empty rounds is not a
# clean re-audit. Both need a branch that says UNMEASURED.
_lunm=$(grep -c 'UNMEASURED  case' acceptance/live-cases.sh 2>/dev/null || true)
if [ "${_lunm:-0}" -ge 2 ]; then
  sok "cases 12 and 13 report UNMEASURED when a round returned nothing at all"
else
  sbad "live-cases can still read an empty finding set as a clean result ($_lunm guards)"
fi

echo
echo "  $SPASS passed, $SFAIL failed"
SUITES=$((SUITES + 1)); [ "$SFAIL" -eq 0 ] && SUITES_OK=$((SUITES_OK + 1))

# --- unit suites ------------------------------------------------------------
run_suite "risk score / tiering"        acceptance/test-risk-score.sh
run_suite "preflight (case 1)"          acceptance/test-preflight.sh
run_suite "invocation ledger (cases 8, 9)" acceptance/test-ledger.sh
run_suite "the four-check gate (cases 10, 14)" acceptance/test-gate.sh

# --- cases that need a live model or a newer CLI ----------------------------
defer "case 2,3,4,5,6 (isolation, base-targets-orchestrator, sole merge point, cleanup, retention) — need a live model to dispatch link. Run acceptance/probe-harness.sh when authenticated."
defer "case 7 (navi degradation, two arms) — navi is CUT pending its A/B. The CLI blocker is gone (CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH is present from 2.1.219; this machine runs 2.1.258), so what remains is a decision, not an environment limit."
defer "case 11 (clean-return rate, THE HEADLINE METRIC) — needs a live model. Run acceptance/clean-corpus.sh when authenticated."
defer "case 12,13 (idempotence; fix-and-re-audit rounds 1-3) — need a live model. Run acceptance/live-cases.sh --case 12 / --case 13 when authenticated."
defer "case 15 (floor ablation) — needs a live model; the floor-free static check above is its cheap proxy, not a substitute. Run acceptance/live-cases.sh --case 15."
defer "case 16 (effective false positives over rolling windows) — needs production audits to accumulate."
defer "case 17 (the one-round falsifier: parallel vs forced-second-round vs sequential) — needs a live model. Run acceptance/live-cases.sh --case 17. If it falsifies, the design is revised, not defended."

echo
echo "=============================================================="
echo " summary"
echo "=============================================================="
echo "  suites: $SUITES_OK/$SUITES green"
echo
echo "  DEFERRED — not run, and NOT counted as passing:"
for d in "${DEFERRED[@]}"; do
  echo "    - $d"
done
echo
if [ "$SUITES_OK" -eq "$SUITES" ]; then
  echo "  All runnable suites green. The deferred list above is the honest remainder."
  exit 0
else
  echo "  FAILURES ABOVE."
  exit 1
fi
