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

# Each suite's own tally is summed so the ONE number the README carries can be
# checked against reality. The README claimed "89 checks green" while the suite
# had grown to 178 -- and the existing staleness check could not see it, because
# it only looks for percentages and dollar figures. A README that understates
# its own project is lying just as much as one that overstates it.
CHECKS=0
run_suite() {
  local name="$1" script="$2" out rc n
  SUITES=$((SUITES + 1))
  echo
  echo "=============================================================="
  echo " $name"
  echo "=============================================================="
  out=$(bash "$script"); rc=$?
  printf '%s\n' "$out"
  [ "$rc" -eq 0 ] && SUITES_OK=$((SUITES_OK + 1))
  n=$(printf '%s' "$out" | sed -n 's/^  \([0-9][0-9]*\) passed,.*/\1/p' | tail -1)
  CHECKS=$((CHECKS + ${n:-0}))
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
# shellcheck source=acceptance/headless.sh
. acceptance/headless.sh
_xtr="$(mktemp)"
printf 'roll-call\n<<<VIOLATIONS\n[\n  {"criterion_id": "S3", "severity": "blocking"}\n]\nVIOLATIONS>>>\nCOMPLETE\n' > "$_xtr"
_got=$(hl_first_block < "$_xtr" | grep -c '"criterion_id"')
if [ "${_got:-0}" -eq 1 ]; then
  sok "extraction recovers a MULTI-LINE violations array (the 100% bug)"
else
  sbad "extraction lost a multi-line violations array — every audit becomes a false PASS"
fi

# --- THE STOP-HOOK TRANSPORT DEFECT, REPRODUCED OFFLINE ----------------------
# `claude -p` in text mode prints only the FINAL assistant message. This plugin
# ships a Stop hook, and --plugin-dir loads it into every headless audit, so the
# reviewer emits its violations block, the hook fires, and the reviewer writes a
# SECOND message answering it -- which is all text mode hands back. The audit is
# produced correctly and thrown away by the transport.
#
# That silently destroyed measurements: probe-harness case 6's "2 of 4 runs",
# case 13's first run, and clean-corpus's two UNREVIEWABLE rows recorded as
# "transient infrastructure failures" that "reproduce clean in isolation".
# Reproduced here from a synthetic transcript so it cannot regress unnoticed.
_sjf="$(mktemp)"
# A quoted heredoc, not printf: printf would interpret the JSON's own \n and \"
# escapes and split each record across lines, leaving nothing parseable.
cat > "$_sjf" <<'SJ'
{"type":"system","subtype":"init"}
{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"..."}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"roll-call\n<<<VIOLATIONS\n[\n  {\"criterion_id\": \"S2\"}\n]\nVIOLATIONS>>>\nCOMPLETE"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Audit already terminated; I will not re-open it."}]}}
{"type":"result","result":"Audit already terminated; I will not re-open it."}
SJ
_txt=$(hl_transcript < "$_sjf")
if printf '%s' "$_txt" | grep -q '<<<VIOLATIONS'; then
  sok "hl_transcript recovers the audit from a hook-extended transcript, not just the last message"
else
  sbad "the transport still reads only the final message — a Stop hook reply discards the audit"
fi
_ids=$(printf '%s' "$_txt" | hl_first_block | grep -c '"criterion_id"')
if [ "${_ids:-0}" -eq 1 ]; then
  sok "hl_first_block extracts the audit array out of a multi-message transcript"
else
  sbad "hl_first_block lost the array in a multi-message transcript (got $_ids)"
fi
rm -f "$_sjf"

# Two blocks must not be spliced: a hook exchange can make the reviewer restate
# its array, and a range match across both yields one malformed document.
_two=$(printf 'a\n<<<VIOLATIONS\n[{"criterion_id": "S1"}]\nVIOLATIONS>>>\nb\n<<<VIOLATIONS\n[{"criterion_id": "S9"}]\nVIOLATIONS>>>\n' | hl_first_block | tr -d ' \n')
if [ "$_two" = '[{"criterion_id":"S1"}]' ]; then
  sok "hl_first_block takes the FIRST array only, never splices two"
else
  sbad "hl_first_block spliced or mis-extracted a restated array (got '$_two')"
fi

# and no harness may go back to text mode, which is where the audit gets lost.
for _h in acceptance/clean-corpus.sh acceptance/live-cases.sh acceptance/probe-harness.sh; do
  if grep -vE '^[[:space:]]*#' "$_h" | grep -qE 'claude -p' \
     && ! grep -vE '^[[:space:]]*#' "$_h" | grep -qE 'claude -p "Reply with exactly: READY"'; then
    sbad "$(basename "$_h") calls claude -p directly; a Stop hook reply would discard its result"
  else
    sok "$(basename "$_h") goes through the shared transport, not bare claude -p"
  fi
done

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
  # Case 6 tells link to add a helper to src/account.js. When that file was
  # absent the task was ill-posed, and link is instructed to stop rather than
  # reconstruct a missing file by guessing -- so whether it invented the file
  # was a model judgement call. One measured dispatch created it and committed;
  # an identical one reported BLOCKED and changed nothing. The second leaves an
  # unchanged worktree, which the harness auto-removes by design, and case 6
  # scored that as indiscriminate cleanup. A coin flip between PASS and a false
  # FAIL, decided by something the fixture controls.
  case "$_fxout" in
    *"src/account.js"*) sok "probe fixture creates src/account.js, the file case 6's task edits" ;;
    *)                  sbad "probe fixture omits src/account.js -- case 6's task asks link to edit a file that does not exist (got: $_fxout)" ;;
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

# "claude is missing" and "claude refused" are different non-executions, and a
# harness that answers both with "/login" sends the reader to fix the wrong
# thing. That cost a real round trip on 2026-09-06: PowerShell's `bash` is WSL
# (C:\WINDOWS\system32\bash.exe), claude.exe is not on WSL's PATH, `timeout`
# reported "failed to execute process", and the harness said to authenticate --
# while the credentials were a separate, genuinely expired matter in a different
# shell. Both are UNMEASURED under INVARIANT 10; only one is fixed by /login.
for _h in acceptance/live-cases.sh acceptance/probe-harness.sh acceptance/clean-corpus.sh; do
  _hn="$(basename "$_h")"
  if grep -q 'command -v claude' "$_h" 2>/dev/null      && grep -q 'NOT an authentication problem' "$_h" 2>/dev/null; then
    sok "$_hn separates 'claude not on PATH' from 'claude not authenticated'"
  else
    sbad "$_hn answers a missing claude with /login, which cannot fix it"
  fi
done

# A NON-EXECUTION IS NOT A DEFECT. Both live cases in probe-harness dispatch an
# agent that can decline, be sandbox-refused, or crash. Case 3 once reported
# "executors are building on the DEFAULT BRANCH" because a compound command was
# refused, and case 6 once reported indiscriminate cleanup because the executor
# was never dispatched at all. Each needs a branch that says UNMEASURED.
# `|| true`, not `|| echo 0`: grep -c already prints 0 when it matches nothing,
# and exits 1 doing it, so `|| echo 0` appends a SECOND zero and the arithmetic
# test below dies on a two-line value. See the nviol check above.
_unmeas=$(grep -c 'UNMEASURED  case' acceptance/probe-harness.sh 2>/dev/null || true)
if [ "${_unmeas:-0}" -ge 4 ]; then
  sok "probe-harness reports UNMEASURED for a non-execution instead of a defect"
else
  sbad "probe-harness can still score a declined or refused dispatch as a defect ($_unmeas guards)"
fi

# Case 6 scores retention from an ABSENT worktree, and absent has two causes
# that look identical: removed although it held work (the defect), or removed
# because it held none (documented behaviour -- the harness auto-removes
# unchanged agent worktrees). On 2026-09-06 a dispatch cleared both of case 6's
# existing guards, reporting DISPATCHED= and TESTS_RC=1, while committing
# nothing. Case 6 would have convicted the design of doing what it documents.
if grep -qF 'git cat-file -e "$EXEC_COMMIT"' acceptance/probe-harness.sh; then
  sok "case 6 verifies the executor's commit against the object store before scoring retention"
else
  sbad "case 6 reads an absent worktree as a cleanup defect without checking any work existed"
fi
# and the sha must be VERIFIED, not believed. The executor reports it, and a
# self-report is data, not ground truth. The object outlives the worktree and
# branch that cleanup removes, so the object store can settle it independently.
if grep -qF 'COMMIT=<the full sha' acceptance/probe-harness.sh; then
  sok "case 6 asks the executor for a commit sha it can then check independently"
else
  sbad "case 6 has no independently checkable evidence that the executor did work"
fi

# Case 2 must NOT resolve its own ambiguity in the design's favour. A toplevel
# equal to the main checkout means either isolation was lost or no executor was
# dispatched. Downgrading that to UNMEASURED would mask the exact defect case 2
# exists to catch, and the two errors are not symmetric: a false alarm costs a
# re-run, a masked isolation failure costs the property.
_c2="$(sed -n '/^# --- P2\/P3 + case 2/,/^# --- P4 + case 3/p' acceptance/probe-harness.sh)"
if [ -z "$_c2" ]; then
  sbad "could not lift case 2 from probe-harness.sh"
elif printf '%s' "$_c2" | grep -qF 'bad "case 2: executor is isolated'; then
  if printf '%s' "$_c2" | grep -qF 'AMBIGUOUS'; then
    sok "case 2 fails on a main-checkout toplevel and names the ambiguity rather than hiding it"
  else
    sbad "case 2 fails on a main-checkout toplevel without saying a non-dispatch produces the same line"
  fi
else
  sbad "case 2 no longer fails on a main-checkout toplevel -- a lost worktree would go unreported"
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

# --- case 13's fix must not restore the base tree ----------------------------
# Case 13 audits round 1 on base..broken, applies a fix, then audits round 2 on
# base..fixed. Its fix used to write the base content back byte for byte, so the
# round-2 diff was EMPTY: round 2 audited nothing, returned nothing, and drift=0
# held by construction. A green that could not have been red -- exactly what
# made case 3 meaningless before its fixture was repaired. Both bodies are
# lifted from live-cases.sh, never restated, so a copy here cannot drift into
# agreement with a broken original.
_b13="$(sed -n '/^# --- shared fixture/,/^} > "\$WORK\/criteria.tsv"/p' acceptance/live-cases.sh \
        | awk "/<<'JS'/{n++; if(n==1){c=1; next}} c&&/^JS\$/{exit} c")"
_f13="$(sed -n '/^# CASE 13/,/^# CASE 15/p' acceptance/live-cases.sh \
        | awk "/<<'JS'/{c=1; next} c&&/^JS\$/{exit} c")"
if [ -z "$_b13" ] || [ -z "$_f13" ]; then
  sbad "could not lift case 13's base and fix bodies from live-cases.sh"
elif [ "$_b13" = "$_f13" ]; then
  sbad "case 13's fix reproduces the base tree -- its round-2 diff is empty and drift=0 is vacuous"
else
  sok "case 13's fix is a forward change, so round 2 has a non-empty diff to audit"
fi

# and the case refuses at runtime if that ever regresses.
if grep -q "case 13's round-2 diff is EMPTY" acceptance/live-cases.sh; then
  sok "case 13 aborts rather than report drift=0 against an empty diff"
else
  sbad "case 13 has no guard against auditing an empty round-2 diff"
fi

# --- case 15 must build its own clean diff, and ablate a REAL floor ----------
# It used to `git diff HEAD~1..HEAD` and rely on case 13 having committed the fix
# first. Run as `--case 15`, case 13 has not run, HEAD is the DEFECTIVE commit,
# and the case audits the defect-introducing diff while asserting it is clean.
# Comments are stripped first. The block quotes the old escape-hatch wording
# verbatim to record why it was replaced, and that documentation must not trip
# the check below -- the same trap the extraction and ANCESTOR checks fell into.
_c15="$(sed -n '/^# CASE 15/,/^# CASE 17/p' acceptance/live-cases.sh | grep -vE '^[[:space:]]*#')"

# ---- THE ABLATION MUST APPLY ITS TREATMENT -------------------------------
# Case 15 reported floor=0 vs no-floor=0 twice, on corpora eight times apart in
# size. The floor arm produced ZERO findings PRE-GATE both times: the reviewer
# did not invent findings and have them gated away, it refused the floor. Its
# own contract, loaded by --agent/--plugin-dir into every audit, forbids floors
# in four places, and a line appended to the USER prompt does not outrank it.
# So the arm was never treated, and a tie between two untreated arms says
# nothing about finding floors. These checks are about whether the treatment
# reaches the reviewer at all.
_c15full="$(sed -n '/^# CASE 15/,/^# CASE 17/p' acceptance/live-cases.sh)"
if printf '%s' "$_c15" | grep -qF 'audit "$WORK/floor.json" 2 "Report at least 3 findings."'; then
  sbad "case 15 still ablates by appending a floor to the prompt, which the agent contract overrides"
else
  sok "case 15 does not try to install a floor the reviewer's own contract forbids"
fi
if printf '%s' "$_c15" | grep -qF 'AUDIT_PLUGIN_DIR="$FLOOR_DIR"'; then
  sok "case 15's floor arm loads a patched contract, so the treatment sits where the instruction lives"
else
  sbad "case 15's two arms load the same contract -- there is no treatment to measure"
fi
if printf '%s' "$_c15" | grep -qF 'ABORT — case 15'"'"'s ablation did not apply'; then
  sok "case 15 aborts rather than report a tie between two untreated arms"
else
  sbad "case 15 can report an unapplied treatment as a null result"
fi
# INVARIANT 1's control: the SHIPPED contract must still forbid a floor. The
# variant is built in $WORK and removed on exit; if the floor ever leaked into
# agents/, the ablation would have no control AND the plugin would ship a floor.
if grep -qF 'there is no floor' agents/ganondorf-t2.md; then
  sok "the shipped contract still forbids a finding floor (INVARIANT 1, and the ablation's control)"
else
  sbad "the shipped ganondorf contract no longer forbids a floor -- INVARIANT 1 violated"
fi

# and the patch itself, LIFTED AND RUN against the real agent file. Anchors
# drift; a treatment that silently stops applying turns the floor arm back into
# a second control, which is the exact failure this case has already produced
# twice for other reasons.
_abl="$(sed -n '/^  "\$PY" - "\$FLOOR_DIR\/agents\/ganondorf-t2.md" <<'"'"'ABLATE'"'"'$/,/^ABLATE$/p' acceptance/live-cases.sh | sed '1d;$d')"
if [ -z "$_abl" ]; then
  sbad "could not lift case 15's ablation patch"
else
  # Same probe as gate.sh and live-cases.sh, for the same reason: on Windows
  # `python3` is often a Store alias stub that exists on PATH and fails to run.
  _rpy=""
  for _cand in python python3 py; do
    if command -v "$_cand" >/dev/null 2>&1 && "$_cand" -c "print(1)" >/dev/null 2>&1; then
      _rpy="$_cand"; break
    fi
  done
  _ad="$(mktemp -d)"; mkdir -p "$_ad/agents"
  cp agents/ganondorf-t2.md "$_ad/agents/" 2>/dev/null
  printf '%s\n' "$_abl" > "$_ad/ablate.py"
  if [ -n "$_rpy" ] && "$_rpy" "$_ad/ablate.py" "$_ad/agents/ganondorf-t2.md" >/dev/null 2>&1 \
     && grep -qF 'Report **at least 3 findings**' "$_ad/agents/ganondorf-t2.md" \
     && ! grep -qF 'there is no floor' "$_ad/agents/ganondorf-t2.md" \
     && ! grep -qF 'There is no minimum number of findings' "$_ad/agents/ganondorf-t2.md"; then
    sok "case 15's ablation runs against the real contract and installs a floor where the no-floor text was"
  else
    sbad "case 15's ablation no longer applies to the real contract -- its anchors have drifted"
  fi
  rm -rf "$_ad"
fi
if [ -z "$_c15" ]; then
  sbad "could not lift case 15 from live-cases.sh"
else
  if printf '%s' "$_c15" | grep -qE '^[[:space:]]*git commit .*&&|^[[:space:]]*git commit -qam'; then
    sok "case 15 commits its own clean state instead of inheriting case 13's"
  else
    sbad "case 15 inherits \$FIX's HEAD -- run standalone it audits the DEFECTIVE diff"
  fi
  # invariant 1 is "no finding floor ANYWHERE"; the ablation arm is the one
  # place it is deliberately reinstated, and it must reinstate the real thing.
  if printf '%s' "$_c15" | grep -qF 'do not invent to hit the floor'; then
    sbad "case 15's floor arm carries an escape hatch -- it ablates a suggestion, not a floor"
  else
    sok "case 15's floor arm reinstates the literal floor, with no escape hatch"
  fi
  if printf '%s' "$_c15" | grep -qF "case 15's clean diff is EMPTY"; then
    sok "case 15 aborts rather than call an empty diff a clean one"
  else
    sbad "case 15 has no guard against auditing an empty diff"
  fi
fi

# --- THE FALSIFIER MUST BE ABLE TO FALSIFY, AND ABLE NOT TO --------------------
# Case 17 decides whether the one-round premise survives. Three defects made its
# verdict independent of its audits:
#   1. `git diff HEAD~2..HEAD~1` needs three commits; the fixture has two. Run
#      standalone it died with "unknown revision" and every arm audited an EMPTY
#      diff -- three nothings, a tie, reported as the premise holding.
#   2. score() printf'd the row AND the f1 to stdout and was called as
#      `F1A=$(score ...)`, so F1A held the whole row. awk then compared two
#      NON-NUMERIC strings, which is a string comparison: "(b) ..." sorts after
#      "(a) ...", so b>a was TRUE always and the case reported FALSIFIED on every
#      run. The design would have been revised on the lexical order of a label.
#   3. Ground truth omitted S4, which the seeded code genuinely violates (purge
#      before archive), scoring a correct finding as a false positive and
#      penalising the arm that searches hardest -- arm (b).
# ---- the allowlist itself --------------------------------------------------
# Rows are evidence about a corpus, so a malformed one is worse than a missing
# one: it would silently gate on a verdict nobody can read.
_VH=acceptance/verified-hosts.tsv
if [ -f "$_VH" ]; then
  _vhbad=$(awk -F'\t' '/^#/ {next} NF==0 {next}
    { if (NF != 6 || $1 !~ /^[0-9a-f]{40}$/ || ($2 != "CLEAN" && $2 != "DIRTY") || $3 !~ /^[0-9]+$/ || $3+0 < 1) print NR }' "$_VH")
  if [ -z "$_vhbad" ]; then
    sok "every verified-hosts row is a full sha, a CLEAN/DIRTY verdict and a run count of at least 1"
  else
    sbad "verified-hosts.tsv has malformed rows (line $(printf '%s' "$_vhbad" | tr '\n' ' '))"
  fi
  # A CLEAN row must cite nothing and a DIRTY row must cite something. Either
  # inverse is a verdict that disagrees with its own evidence.
  _vhinc=$(awk -F'\t' '/^#/ {next} NF==6 { if (($2=="CLEAN" && $4 != "-") || ($2=="DIRTY" && $4 == "-")) print NR }' "$_VH")
  if [ -z "$_vhinc" ]; then
    sok "no verified-hosts row contradicts its own citation column"
  else
    sbad "verified-hosts.tsv has a verdict that disagrees with its citations (line $(printf '%s' "$_vhinc" | tr '\n' ' '))"
  fi
  # A disqualification that names no reason is an unexplained veto, and the next
  # reader has no way to judge or retire it.
  _vhdq=$(awk -F'\t' '$1=="#!DQ" { if (NF != 3 || $2 !~ /^[0-9a-f]{40}$/ || length($3) < 20) print NR }' "$_VH")
  if [ -z "$_vhdq" ]; then
    sok "every disqualification names a full sha and states its reason"
  else
    sbad "verified-hosts.tsv has a disqualification with no sha or no reason (line $(printf '%s' "$_vhdq" | tr '\n' ' '))"
  fi
else
  sbad "acceptance/verified-hosts.tsv is missing -- case 17's django arms cannot be gated"
fi

_s17="$(sed -n '/^# CASE 17/,$p' acceptance/live-cases.sh)"
_l17="$(printf '%s' "$_s17" | grep -vE '^[[:space:]]*#')"
if [ -z "$_s17" ]; then
  sbad "could not lift case 17 from live-cases.sh"
else
  if printf '%s' "$_l17" | grep -qF 'HEAD~2..HEAD~1'; then
    sbad "case 17 still uses HEAD~2..HEAD~1 -- standalone that is an empty diff"
  else
    sok "case 17 pins its seeded diff by SHA, not by HEAD-relative names"
  fi
  if printf '%s' "$_l17" | grep -qF 'F1A=$(score'; then
    sbad "case 17 captures score()'s printed row as its F1 -- the verdict is a string compare"
  else
    sok "case 17 reads F1 from SCORE_F1, not from score()'s printed output"
  fi
  if printf '%s' "$_l17" | grep -qF "printf 'C1"; then
    printf '%s' "$_l17" | grep -qF 'S4' \
      && sok "case 17's ground truth includes S4, which the seeded code really violates" \
      || sbad "case 17's ground truth omits S4 -- a correct finding scores as a false positive"
  else
    sbad "could not find case 17's ground truth line"
  fi
  if printf '%s' "$_l17" | grep -qF 'MUST NOT GUESS'; then
    sok "case 17 reports UNMEASURED rather than a verdict when F1 is not numeric"
  else
    sbad "case 17 can still render a verdict from a non-numeric F1"
  fi
  if printf '%s' "$_l17" | grep -qF 'tie between two nothings'; then
    sok "case 17 refuses to read two empty arms as the premise holding"
  else
    sbad "case 17 can still report a tie between empty arms as a corroboration"
  fi

  # and the scorer itself, lifted and RUN: F1 must come back a bare number.
  _sc="$(printf '%s' "$_s17" | sed -n '/^  score() {/,/^  }$/p')"
  if [ -z "$_sc" ]; then
    sbad "could not lift case 17's score() function"
  else
    _scd="$(mktemp -d)"
    printf 'C1\nS2\nS4\n' | sort > "$_scd/truth.txt"
    printf 'C1\nS2\n'     | sort > "$_scd/arm.txt"
    _f1=$( WORK="$_scd"; eval "$_sc"; score "$_scd/arm.txt" "probe" >/dev/null; printf '%s' "$SCORE_F1" )
    case "$_f1" in
      0.800) sok "score() returns a bare number (tp=2 fp=0 fn=1 -> F1=0.800)" ;;
      *[!0-9.]*|"") sbad "score() returns a non-numeric F1 ('$_f1') -- awk would compare strings" ;;
      *) sbad "score() returned '$_f1', want 0.800" ;;
    esac
    rm -rf "$_scd"
  fi

  # THE VERDICT LOGIC, LIFTED AND RUN ON ALL THREE OUTCOMES.
  # A falsifier that cannot reach every verdict is not a falsifier. This drives
  # the real if-chain with synthetic scores and checks each branch is reachable:
  # a genuine falsification, a genuine hold, and the ceiling refusal that fired
  # on 2026-09-03 when every arm scored TP=3/3 FP=0 and `b > a` was impossible.
  _vc="$(printf '%s' "$_s17" | sed -n '/^  if \[ -z "\$F1A" \]; then/,/^  fi$/p')"
  if [ -z "$_vc" ]; then
    sbad "could not lift case 17's verdict chain"
  else
    _verdict() {   # _verdict <F1A> <F1B> <TPA> <FPA> <truthn> <na> <nb>
      F1A="$1"; F1B="$2"; TPA="$3"; FPA="$4"; _truthn="$5"; _na="$6"; _nb="$7"
      ok()  { printf 'OK:%s\n'  "$1"; }
      bad() { printf 'BAD:%s\n' "$1"; }
      eval "$_vc"
    }
    _ceil=$(_verdict 1.000 1.000 3 0 3 3 3 2>&1)
    _fals=$(_verdict 0.500 0.900 1 0 3 1 2 2>&1)
    _hold=$(_verdict 0.900 0.500 2 0 3 2 3 2>&1)
    # A TIE below the ceiling: arm (a) is imperfect, so (b) HAD room to win and
    # did not. That is the outcome the 2026-09-06 run produced, and it must not
    # read the same as (a) winning outright -- the evidence is weaker.
    _tie=$(_verdict 0.889 0.889 4 0 5 4 4 2>&1)
    case "$_ceil" in
      *UNINFORMATIVE*) sok "case 17 refuses a ceiling: arm (a) perfect means (b) cannot beat it" ;;
      *) sbad "case 17 reads a ceiling as a corroboration (got: $(printf '%s' "$_ceil" | head -1))" ;;
    esac
    case "$_fals" in
      *BAD:FALSIFIED*) sok "case 17 CAN falsify: (b) beating (a) reports FALSIFIED" ;;
      *) sbad "case 17 cannot report a falsification (got: $(printf '%s' "$_fals" | head -1))" ;;
    esac
    case "$_hold" in
      *TIE*)          sbad "case 17 reports a strict win for (a) as a tie" ;;
      *OK:one-round*) sok "case 17 can report the premise holding when (a) genuinely wins" ;;
      *) sbad "case 17 cannot report a hold (got: $(printf '%s' "$_hold" | head -1))" ;;
    esac
    case "$_tie" in
      *OK:*TIE*) sok "case 17 distinguishes a TIE from (a) winning, below the ceiling" ;;
      *UNINFORMATIVE*) sbad "case 17 mistakes an imperfect tie for a ceiling -- (b) had room to win there" ;;
      *) sbad "case 17 reports a tie as an outright win (got: $(printf '%s' "$_tie" | head -1))" ;;
    esac
  fi

  # ---- THE CORPUS ITSELF -------------------------------------------------
  # On 2026-09-03 case 17 ran cleanly and measured nothing: every arm scored
  # TP=3/3, FP=0, F1=1.000 on a six-line fixture, so `b > a` was arithmetically
  # unreachable. The verdict chain above was correct; the CORPUS was the
  # problem. These checks ask whether the corpus can carry the experiment.

  # 0. The F1 column alone cannot be read. Three arms tying at one F1 can mean
  #    they agreed on the same criteria, or that they reached DIFFERENT sets of
  #    equal size -- opposite conclusions about what a second round buys. The
  #    per-arm sets, and the criteria no arm reached at all, are what separate
  #    a systematic blind spot from a sampling miss.
  if printf '%s' "$_l17" | grep -qF 'cited by (a)'; then
    sok "case 17 prints the criteria each arm actually cited, not just its F1"
  else
    sbad "case 17 reports F1 alone -- a tie cannot be told from arms finding different sets"
  fi
  if printf '%s' "$_l17" | grep -qF 'missed.txt'; then
    sok "case 17 names the truth criteria no arm reached, bounding what (b) could have won"
  else
    sbad "case 17 does not report which criteria the reviewer never reaches"
  fi
  # Once false positives exist, precision drives the F1 gaps between arms, and
  # "FP=1" does not say whether the citation was actually wrong. On django host
  # f30acb18 the FP was C1 -- the host commit's OWN SUBJECT -- in 2 of 3 runs.
  if printf '%s' "$_l17" | grep -qF 'FALSE POSITIVES'; then
    sok "case 17 names the false positives, not just how many, so a low-precision arm can be checked"
  else
    sbad "case 17 reports FP counts alone -- an inventing arm cannot be told from an unfair truth set"
  fi
  # Naming an id is not enough either. Whether a citation was WRONG needs what it
  # actually cited: on django host f30acb18 the FP in 2 of 3 runs was C1, the host
  # commit's OWN SUBJECT, and precision drives every F1 gap once FPs exist.
  if printf '%s' "$_l17" | grep -qF 'cite "$_fpid"'; then
    sok "case 17 prints what each false positive actually cited, not only its id"
  else
    sbad "case 17's false positives cannot be judged -- it prints ids with no citation text"
  fi

  # ---- arm (d), the revision round ---------------------------------------
  # Deferred until its gate opened: its only mechanism (c) lacks is removing a
  # false positive, and every arm scored FP=0 until the django corpus produced
  # some. It must REPLACE rather than union -- union arm (a) back in and a
  # withdrawal becomes unobservable, making (d) a slower copy of (c).
  if printf '%s' "$_l17" | grep -qF 'arm-d.txt'; then
    if printf '%s' "$_l17" | grep -qF 'crits "$WORK/d1.json" | sort -u > "$WORK/arm-d.txt"'; then
      sok "arm (d) scores the revision round alone, so a withdrawal is observable"
    else
      sbad "arm (d) unions its rounds -- a withdrawal cannot be seen, making it a copy of (c)"
    fi
    # The prompt must lean neither way. A floor manufactures false positives
    # (INVARIANT 1, and case 15 measured it); pressure to delete manufactures
    # false CLEANS, which INVARIANT 10 cares about at least as much.
    if printf '%s' "$_l17" | grep -qF 'restate it unchanged' \
       && printf '%s' "$_l17" | grep -qF 'emit an empty array'; then
      sok "arm (d)'s prompt says an unchanged set and an empty set are both complete answers"
    else
      sbad "arm (d)'s prompt leans toward adding or toward withdrawing -- it manufactures one or the other"
    fi
    # A run where it withdrew nothing says nothing about withdrawal, and must
    # say so rather than let its F1 be read as evidence either way.
    if printf '%s' "$_l17" | grep -qF 'withdrew NOTHING'; then
      sok "arm (d) says when it withdrew nothing, so its F1 is not read as evidence about withdrawal"
    else
      sbad "arm (d) can report an F1 from a run where it withdrew nothing, as if it had been exercised"
    fi
  else
    sbad "arm (d) is absent although its gate condition (false positives to withdraw) is met"
  fi

  # A HARNESS MUST NOT CONTRADICT ITSELF IN ITS OWN OUTPUT.
  #
  # Case 17 printed arm (d)'s score row and, four lines later, "Arm (d) ... is
  # deliberately not built". Both were written honestly, months apart in
  # editing terms: the note was true when arm (c) became sequential and went
  # stale the moment (d) was built. A reader has no way to tell which half of a
  # self-contradicting report to believe, and the offline suite could not see it
  # because every check tested code, not the prose beside it.
  # Matched against the COMMENT-STRIPPED text, and not per-line: the stale
  # sentence spanned two echo lines ("Arm (d) — a round that may" / "WITHDRAW an
  # earlier finding — is deliberately not built"), so a single-line pattern saw
  # nothing and the first version of this check passed on the very text it was
  # written to catch. It was only caught by running it against the stale file.
  if printf '%s' "$_l17" | grep -qF 'arm-d.txt'; then
    if printf '%s' "$_l17" | grep -qE 'not built|deliberately not'; then
      sbad "case 17 prints arm (d)'s score AND says arm (d) is not built -- the output contradicts itself"
    else
      sok "case 17's prose about arm (d) matches the arm it actually runs"
    fi
  fi

  # ---- host verification: the guard the corpus always assumed ------------
  #
  # Case 17's django corpus scores every citation outside {S1 S2 S4 S6} as a
  # false positive. That is only sound if the reviewer returns CLEAN on the
  # host commit's own change. The first guard audited a SUPERSET -- all *.py
  # including tests, no seeds -- and a clean result there was recorded as if it
  # certified the subset case 17 actually audits. It does not, and on host
  # f30acb18 the difference was the whole result: C1 at admin_modify.py:158
  # reproduces on the unseeded host diff, so it was never a false positive.
  if printf '%s' "$_l17" | grep -qF 'VERIFY_HOST'; then
    sok "case 17 can verify a host on the exact diff it audits (--verify-host)"

    # The control must be PROVED a subset, not assumed. Assuming it is the
    # defect this mode exists to close.
    if printf '%s' "$_l17" | grep -qF 'seeded-diff.txt' \
       && printf '%s' "$_l17" | grep -qF 'comm -23'; then
      sok "host verification proves its control diff is a subset of the audited diff"
    else
      sbad "host verification does not check that its control diff is contained in the audited diff"
    fi

    # Splitting the seeds into their own commit must not have moved the diff
    # case 17 audits. base..HEAD is still the seeded tree; only the control
    # stops one commit short.
    if printf '%s' "$_s17" | grep -qF 'HARD_BASE="$(git rev-parse HEAD~2)"' \
       && printf '%s' "$_s17" | grep -qF 'HARD_HEAD="$HARD_SEEDED"'; then
      sok "the seeds are their own commit and the audited range still ends at the seeded tree"
    else
      sbad "case 17's django range no longer ends at the seeded tree -- the arms would audit the wrong diff"
    fi

    # A question ABOUT the corpus cannot be answered alongside numbers FROM it.
    _vh="$(printf '%s' "$_s17" | sed -n '/if \[ "\$VERIFY_HOST" = 1 \]; then/,/^  K=2$/p')"
    if printf '%s' "$_vh" | grep -qF 'exit $?'; then
      sok "host verification exits instead of falling through into the arms"
    else
      sbad "host verification can fall through and print arm scores from an unverified corpus"
    fi
  else
    sbad "case 17 has no way to verify its host on the exact diff it audits"
  fi

  # ---- arm (e), the criteria walk, and the floor it could have been ------
  #
  # Arm (e) tests whether arm (c)'s win is really about chaining or just about
  # pointing at the uncited criteria. Its prompt is the hazard: "work through
  # every criterion" is one careless sentence from "find something for every
  # criterion", and case 15 measured a floor manufacturing findings on a diff
  # with nothing wrong in it. So the arm is not trusted on its wording -- it is
  # controlled, and the control is read before the score.
  if printf '%s' "$_l17" | grep -qF 'arm-e.txt'; then
    sok "arm (e) exists -- one round told to walk the criteria list"

    # ONE audit. The hypothesis is about the budget, so the arm must spend it.
    _ecalls=$(printf '%s' "$_l17" | grep -cF 'audit "$WORK/e1.json"')
    if [ "$_ecalls" = "1" ]; then
      sok "arm (e) spends exactly one audit, half of (a)'s -- the budget is the claim"
    else
      sbad "arm (e) does not spend exactly one audit ($_ecalls), so 'at half the budget' is not what it measures"
    fi

    # The floor control must exist, must run on the UNSEEDED host diff, and must
    # be read BEFORE the score is credited.
    if printf '%s' "$_l17" | grep -qF 'audit "$WORK/efloor.json"' \
       && printf '%s' "$_l17" | grep -qF 'DIFF_FILE="$WORK/host-only-diff.txt"'; then
      sok "arm (e)'s prompt is controlled against the unseeded host diff, not trusted on its wording"
    else
      sbad "arm (e) has no floor control -- a prompt that invents findings would score as recall"
    fi
    if printf '%s' "$_l17" | grep -qF 'ARM (e) IS A FINDING FLOOR'; then
      sok "a floor verdict VOIDS arm (e)'s score rather than annotating it"
    else
      sbad "arm (e) can report an F1 from a prompt that manufactured findings on a clean diff"
    fi
    # And the control must be restored, or every later arm audits the wrong diff.
    if printf '%s' "$_l17" | grep -qF 'DIFF_FILE="$_esaved"'; then
      sok "the floor control restores DIFF_FILE, so it cannot silently redirect the other arms"
    else
      sbad "the floor control leaves DIFF_FILE pointing at the clean diff -- every later arm audits the wrong thing"
    fi

    # An uncontrolled score must SAY it is uncontrolled. The hard corpus has no
    # clean host diff, so the control cannot run there.
    if printf '%s' "$_l17" | grep -qF 'is UNCONTROLLED'; then
      sok "arm (e) says so when its floor control could not run, instead of reporting a bare F1"
    else
      sbad "arm (e) reports the same F1 whether or not its floor control ran"
    fi
  else
    sbad "arm (e) is absent although it is the cheapest open question case 17 has"
  fi

  # ---- the host must supply NOISE, not just a place to put the seeds -----
  #
  # DJ_FILES is capped at six files and the cap does not pick the six that
  # carry the change. Host 5f90dc24 is a 172-line commit that produced a
  # TWELVE-line diff against ~24 lines of seeded defects: the seeds are the
  # diff, the reviewer finds all of them, arm (a) saturates and the falsifier
  # has no power. That is the hand-built fixture's failure, reappearing inside
  # the corpus built to escape it.
  if printf '%s' "$_l17" | grep -qF 'seeded ones. The seeds ARE the diff'; then
    sok "case 17 refuses a django host that contributes less diff than its own seeds"
  else
    sbad "case 17 will score a host whose seeds outweigh its noise -- arm (a) saturates by construction"
  fi
  if printf '%s' "$_l17" | grep -qF 'host lines vs'; then
    sok "case 17 reports host noise and seeded lines separately, not one combined count"
  else
    sbad "case 17 prints one line count, so a reader cannot tell noise from seeds"
  fi
  # And it must not fire during verification, which audits the host change ALONE
  # and would therefore always look seed-heavy.
  if printf '%s' "$_s17" | grep -qF '[ "$VERIFY_HOST" != 1 ] && [ "${_hloc:-0}" -lt "${_seedloc}" ]'; then
    sok "the noise guard is skipped during verification, which audits the host change alone"
  else
    sbad "the noise guard would fire during verification and refuse every host"
  fi

  # ---- the host requirement must be ENFORCED, not written down -----------
  #
  # "THE HOST COMMIT MUST BE ONE THE REVIEWER RETURNS CLEAN ON, unseeded" sat
  # in case 17 as a comment while two of the three django runs used a host
  # nobody had checked -- including the only run that fired the falsifier. A
  # comment cannot stop a run. Every requirement that decides whether a number
  # is readable belongs in the code that produces the number.
  if printf '%s' "$_l17" | grep -qF 'never been verified'; then
    sok "case 17's django arms refuse a host that has never been verified"
  else
    sbad "case 17 will score a django host nobody has verified -- the requirement is prose again"
  fi
  if printf '%s' "$_l17" | grep -qF '!= "CLEAN"'; then
    sok "case 17's django arms refuse a host recorded DIRTY"
  else
    sbad "case 17 will score a host recorded DIRTY, counting a host property as a false positive"
  fi

  # Verification is NECESSARY AND NOT SUFFICIENT: it only asks whether a
  # citation survives without the seeds, and S3 at options.py:2087 on f30acb18
  # appeared only in seeded runs while being true of django's own code. A human
  # disqualification has to outrank the machine verdict, and no run may clear it.
  if printf '%s' "$_l17" | grep -qF '#!DQ'; then
    sok "a human disqualification outranks the machine verdict and cannot be cleared by a run"
  else
    sbad "nothing can disqualify a host that verifies clean but is known bad -- the verdict is final"
  fi
  if printf '%s' "$_l17" | grep -qF 'NECESSARY, NOT SUFFICIENT'; then
    sok "a clean verification says so in its own output: it permits a host, it does not vouch for it"
  else
    sbad "a clean verification reads as a guarantee it cannot give"
  fi

  # The allowlist must be unwritable outside verification, or a run could
  # authorise the very corpus it is about to score.
  _vhw="$(printf '%s' "$_s17" | sed -n '/if \[ "\$VERIFY_HOST" = 1 \]; then/,/^  K=2$/p')"
  if printf '%s' "$_s17" | grep -qF 'cp "$WORK/vh.tmp" "$VHOSTS"'; then
    if printf '%s' "$_vhw" | grep -qF 'cp "$WORK/vh.tmp" "$VHOSTS"'; then
      sok "only a --verify-host run can write the allowlist (evidence and permission are one artifact)"
    else
      sbad "the allowlist is written outside --verify-host -- a run could authorise its own corpus"
    fi
  else
    sbad "host verification does not record its result, so the next run learns nothing from it"
  fi

  # And the enforcement must sit OUTSIDE that block, or the arms never reach it.
  if printf '%s' "$_vhw" | grep -qF 'never been verified'; then
    sbad "the host check lives inside --verify-host, so the scoring arms never reach it"
  else
    sok "the host check gates the scoring arms, not the verification that feeds it"
  fi

  # A DIRTY verdict must be recorded as readily as a clean one, and it must not
  # decay. f30acb18 cited C1 once, returned clean three times running, then cited
  # it again -- 2 of 7 unseeded runs. A writer that kept only the last result
  # would have published CLEAN 3/3 at the moment it was asked.
  if printf '%s' "$_s17" | grep -qF '_verd=CLEAN; [ -n "$_allcit" ] && _verd=DIRTY'; then
    sok "verification records DIRTY as readily as CLEAN"
  else
    sbad "verification may only record clean hosts, so a dirty one leaves no trace"
  fi
  if printf '%s' "$_s17" | grep -qF '_truns=$((_pruns + RUNS))' \
     && printf '%s' "$_s17" | grep -qF '_allcit=$(printf'; then
    sok "verification rows accumulate -- a later quiet run cannot retire an earlier citation"
  else
    sbad "verification overwrites its row, so a quiet run erases the run that found something"
  fi

  # BEHAVIOURAL, not textual. These are the guards that would let a verification
  # certify a host it never looked at, so they are executed rather than grepped.
  #
  # EVERY PROBE MUST DIE AT A GUARD. This suite is offline, and live-cases.sh
  # runs its auth probe -- a real model call -- immediately after the guards.
  # The first version of this block passed `--corpus django --runs 3`, which is
  # a VALID combination: it sailed through both guards, spent the auth probe and
  # started case 12 for real. An offline suite that quietly bills a model is a
  # worse defect than the one it was checking for. `--corpus hard` with a valid
  # --runs proves the run-count guard let 3 through AND stops one guard later,
  # so the discriminating probe never reaches the model.
  _r0="$(bash acceptance/live-cases.sh --verify-host --corpus hard --runs 0 2>&1)"
  _rn="$(bash acceptance/live-cases.sh --verify-host --corpus hard --runs 0abc 2>&1)"
  _rh="$(bash acceptance/live-cases.sh --verify-host --corpus hard --runs 3 2>&1)"
  if printf '%s' "$_r0" | grep -qF 'must be at least 1' \
     && printf '%s' "$_rn" | grep -qF 'positive integer'; then
    sok "--runs 0 and a non-numeric --runs are both refused before anything is audited"
  else
    sbad "--verify-host accepts a run count that audits nothing and would report the host clean"
  fi

  # The same probe, read the other way: a valid count reaches the NEXT guard, so
  # the run-count check can be green as well as red.
  if printf '%s' "$_rh" | grep -qF 'only means something with --corpus django'; then
    sok "a valid --runs passes its guard and --verify-host is then refused on the hostless corpus"
  else
    sbad "--verify-host on the hard corpus is not refused, or a valid --runs never gets past its guard"
  fi

  # live-cases.sh prints its banner only AFTER the guards and just before the
  # auth probe, so the banner in a probe's output is proof that probe reached
  # the model. None of them may.
  if printf '%s%s%s' "$_r0" "$_rn" "$_rh" | grep -qF 'triforce live cases'; then
    sbad "an offline probe got past the guards into live-cases.sh proper -- it spends a model call"
  else
    sok "every live-cases probe dies at a guard, before the auth probe (the suite stays offline)"
  fi

  # ---- the verdict must be able to see the sequential arm ----------------
  # The falsifier clause names arm (b), and the verdict chain implements it
  # unchanged. But arm (c) only became a real arm on 2026-09-06 -- until then it
  # was byte-identical to (a) -- so the chain never compared it, and on the
  # django host 804660d6 it printed "the premise holds, as a TIE" while (c)
  # scored F1=1.000 against (a) and (b) at 0.857. A falsifier blind to the arm
  # that beat the control is not a falsifier.
  if printf '%s' "$_l17" | grep -qF 'FALSIFIED BY THE SEQUENTIAL ARM'; then
    sok "case 17's verdict compares the sequential arm against (a), not only (b)"
  else
    sbad "case 17's verdict cannot report a sequential arm beating (a) -- it is blind to arm (c)"
  fi
  if printf '%s' "$_s17" | grep -qF 'not the issue'"'"'s literal clause'; then
    sok "the sequential finding is reported as distinct from the issue's own (b)-vs-(a) clause"
  else
    sbad "case 17 folds a sequential-arm result into the issue's clause, answering a question it did not ask"
  fi
  # and the block itself, LIFTED AND RUN. A comparison that cannot fire is the
  # same as no comparison, and this one is new enough to be unexercised.
  _vseq="$(printf '%s' "$_s17" | sed -n '/^  if \[ -n "\$F1A" \] && \[ -n "\${F1C:-}" \]/,/^  fi$/p')"
  if [ -z "$_vseq" ]; then
    sbad "could not lift case 17's sequential-arm comparison"
  else
    _vsd="$(mktemp -d)"
    printf 'S1\nS2\nS6\n'    > "$_vsd/arm-a.txt"
    printf 'S1\nS2\nS4\nS6\n' > "$_vsd/arm-c.txt"
    _seqfire() {   # <F1A> <F1C> <TPA> <FPA> <truthn>
      WORK="$_vsd"; F1A="$1"; F1C="$2"; TPA="$3"; FPA="$4"; _truthn="$5"
      ok()  { printf 'OK:%s\n'  "$1"; }
      bad() { printf 'BAD:%s\n' "$1"; }
      eval "$_vseq"
    }
    _sfals=$(_seqfire 0.857 1.000 3 0 4 2>&1)
    _shold=$(_seqfire 0.900 0.500 3 0 4 2>&1)
    _sceil=$(_seqfire 1.000 1.000 4 0 4 2>&1)
    case "$_sfals" in
      *BAD:FALSIFIED*) sok "the sequential comparison FIRES when (c) beats (a) — the case 17 django shape" ;;
      *) sbad "the sequential comparison cannot report (c) beating (a) (got: $(printf '%s' "$_sfals" | head -1))" ;;
    esac
    case "$_shold" in
      *BAD:*) sbad "the sequential comparison falsifies when (c) LOSES to (a)" ;;
      *) sok "the sequential comparison stays quiet when (c) does not beat (a)" ;;
    esac
    case "$_sceil" in
      *BAD:*) sbad "the sequential comparison fires at a ceiling, where (c) cannot beat a perfect (a)" ;;
      *) sok "the sequential comparison is suppressed at a ceiling, like the (b) comparison" ;;
    esac
    rm -rf "$_vsd"
  fi

  # ---- arm (c) must actually be sequential -------------------------------
  # It was byte-identical to arm (a) -- K independent audits unioned, no
  # chaining -- and reported as such rather than passed off as sequential.
  if printf '%s' "$_l17" | grep -qF 'A previous reviewer audited this exact diff'; then
    sok "arm (c) chains: a later round is told what the previous one cited"
  else
    sbad "arm (c) is still K independent audits unioned -- it is not a sequential arm"
  fi
  # INVARIANT 1: no finding floor, in any prompt. "Report what the previous
  # reviewer missed" is one careless sentence from a quota, and case 15
  # measured a floor manufacturing false positives on a genuinely clean diff.
  if printf '%s' "$_l17" | grep -qF 'emit an empty array'; then
    sok "arm (c)'s chaining prompt says missing nothing is a complete answer -- not a floor"
  else
    sbad "arm (c) asks a later round for what was missed with no empty-array escape -- that is a finding floor"
  fi
  # Arm (d) -- a round that may WITHDRAW an earlier finding -- changes authority
  # as well as chaining and would confound the two. It is deliberately absent
  # while every measured arm scores FP=0 and it would have nothing to withdraw.
  if printf '%s' "$_s17" | grep -qF 'arm (d)'; then
    sok "the withdraw-capable arm is named and deliberately deferred, not silently folded into (c)"
  else
    sbad "no record of why a withdraw-capable arm is absent -- it will read as an oversight"
  fi

  # ---- the django-seeded corpus ------------------------------------------
  # The hand-built fixture is fully found: 5/5 with FP=0 on three runs, so
  # `b > a` is unreachable and the falsifier has no power. Seeding the same
  # defect classes into a REAL commit keeps ground truth knowable while making
  # the diff realistic. These checks guard the ways that can go quietly wrong.
  if printf '%s' "$_l17" | grep -qF 'CORPUS = "django"' \
     || printf '%s' "$_l17" | grep -qF '"$CORPUS" = "django"'; then
    if grep -qE '^CORPUS="hard"' acceptance/live-cases.sh; then
      sok "case 17 defaults to the self-contained corpus, so a bare --case 17 needs no external repo"
    else
      sbad "case 17's default corpus is not the self-contained one -- the case stops being runnable offline"
    fi
    # An absent clone or host must be UNMEASURED, never a silent fall back to
    # the easy corpus: that would report a hand-fixture ceiling under a name
    # that says the measurement ran on real code.
    if printf '%s' "$_s17" | grep -qF 'UNMEASURED  case 17: --corpus django needs'; then
      sok "case 17 reports UNMEASURED when the django corpus is requested without a repo or host"
    else
      sbad "case 17 can silently fall back to the easy corpus when --corpus django is unusable"
    fi
    # The host must be a commit the reviewer returns CLEAN on. Otherwise its own
    # legitimate findings score as false positives against a truth set that only
    # knows about the seeded defects -- penalising whichever arm searched
    # hardest, which is the bias adding S4 removed from the hand fixture.
    if printf '%s' "$_s17" | grep -qF 'MUST BE ONE THE REVIEWER RETURNS CLEAN ON'; then
      sok "case 17 records that the django host must be verified clean before it is seeded"
    else
      sbad "case 17 does not require its django host to be a commit the reviewer returns clean on"
    fi
    # C1 is the host commit's own subject, which the host satisfies. Including
    # it in truth would claim a violation nothing seeded.
    if printf '%s' "$_l17" | grep -qF "printf 'S1"; then
      sok "case 17's django truth is the seeded defects only, leaving C1, S3 and S5 clean"
    else
      sbad "case 17's django truth does not exclude C1 -- it would claim a violation nothing seeded"
    fi
    # The seeding must iterate over the DEFECTS. Cycling over files instead
    # seeded only as many defects as there were files: on a 2-file host that is
    # 2 defects against a truth set claiming 4, so two criteria were unreachable
    # and recall was capped at 2/4 by the fixture. It would have looked exactly
    # like the reviewer missing things.
    if printf '%s' "$_l17" | grep -qF 'for _def in S1 S2 S4 S6'; then
      sok "case 17 seeds every claimed defect regardless of how many files the host touches"
    else
      sbad "case 17's django seeding cycles over files, so a small host seeds fewer defects than its truth claims"
    fi
  else
    sbad "case 17 has no django corpus arm; the hand fixture is saturated and cannot falsify"
  fi

  # 1. It must not be the SHARED fixture. Cases 12, 13 and 15 are measured on
  #    that one, so hardening it in place would silently move three other
  #    results at the same time.
  if printf '%s' "$_l17" | grep -qF '> "$WORK/diff.txt"'; then
    sbad "case 17 writes the shared diff -- hardening its corpus would move cases 12, 13 and 15 too"
  else
    sok "case 17 audits its own corpus and leaves the shared fixture untouched"
  fi
  if grep -qF 'bash "$GATE" --criteria "$CRIT_FILE" --diff "$DIFF_FILE"' acceptance/live-cases.sh; then
    sok "audit() reads CRIT_FILE/DIFF_FILE, so a case can supply its own corpus"
  else
    sbad "audit() is hard-wired to one corpus -- case 17 cannot differ from cases 12, 13 and 15"
  fi

  # 2. Truth must be a PROPER subset of the criteria. If every criterion were
  #    violated, no citation could be a false positive, precision would be
  #    pinned at 1.000, and F1 would collapse to pure recall -- under which arm
  #    (b), a superset of (a) by construction, can only match or BEAT it. That
  #    rigs the run FOR falsification, the mirror image of the ceiling that
  #    rigged it against. Precision has to be able to fall.
  _t17="$(printf '%s' "$_l17" | grep -F 'truth.txt' | grep -F 'printf' | head -1)"
  _tn=$(printf '%s' "$_t17" | grep -oE '(C1|S[1-6])' | grep -c . || true)
  _cn=$(printf '%s' "$_l17" | grep -oE "printf '(C1|S[1-6])" \
        | grep -oE '(C1|S[1-6])' | sort -u | grep -c . || true)
  if [ "${_tn:-0}" -eq 0 ] || [ "${_cn:-0}" -eq 0 ]; then
    sbad "could not lift case 17's ground truth and criteria ids"
  else
    if [ "$_tn" -lt "$_cn" ]; then
      sok "case 17's truth is a PROPER subset of its criteria ($_tn of $_cn) -- precision can fall"
    else
      sbad "case 17's truth covers every criterion ($_tn of $_cn): no citation can be a false positive, F1 collapses to recall, and (b) can only beat (a)"
    fi
    for _cl in S3 S5; do
      if printf '%s' "$_t17" | grep -qF "$_cl"; then
        sbad "case 17's truth claims $_cl, which the seeded code does not violate"
      else
        sok "case 17 leaves $_cl clean, so citing it scores as a real false positive"
      fi
    done
  fi

  # 3. The fixture must BUILD, and its diff must carry every seeded defect.
  #    A fixture that fails to build writes an empty diff, every arm scores
  #    zero, and the comparison is a tie between three nothings. Case 17 aborts
  #    on that at runtime; this catches it with no live model and no tokens.
  _hf="$(printf '%s' "$_s17" | sed -n '/^  HFIX="\$WORK\/hard"/,/^  ) >\/dev\/null 2>&1$/p')"
  if [ -z "$_hf" ]; then
    sbad "could not lift case 17's hard-fixture builder"
  else
    _hd="$(mktemp -d)"
    ( WORK="$_hd"; eval "$_hf" ) >/dev/null 2>&1
    _hdf="$_hd/seeded.diff"
    ( cd "$_hd/hard" && git diff -W HEAD~1..HEAD ) > "$_hdf" 2>/dev/null
    if ! grep -q '[^[:space:]]' "$_hdf" 2>/dev/null; then
      sbad "case 17's hard fixture builds an EMPTY diff -- every arm would score zero"
    else
      sok "case 17's hard fixture builds and produces a non-empty seeded diff"
      # Each seeded defect, identified by the line that carries it and named for
      # the criterion it makes true. A fixture edit that drops one is caught
      # here, by the id the ground truth still claims.
      _seed_C1="-    throw new Error('refund exceeds invoice');"
      _seed_S1="+  for (let i = 1; i < items.length; i++) {"
      _seed_S2="+function purgeAll(userId) {"
      # S4 must be matched by ITS OWN line, not by S2's. Sharing a marker is
      # how two criteria came to rest on one defect in the first place.
      _seed_S4="+  settings.insert(user.id, user.settings);"
      _seed_S6="+  const n = s.uses;"
      for _id in C1 S1 S2 S4 S6; do
        eval "_pat=\"\$_seed_$_id\""
        if grep -qF -- "$_pat" "$_hdf" 2>/dev/null; then
          sok "case 17's diff carries the $_id defect its ground truth claims"
        else
          sbad "case 17's ground truth claims $_id but the seeded diff does not contain it"
        fi
      done
      # Each truth criterion must be matched by a DISTINCT marker line.
      #
      # Why it matters: measured 2026-09-06 on a fixture seeding a rollback
      # failure and nothing else, the reviewer cites ONE criterion per defect.
      # It reached S4 in 1 of 3 runs and the competing domain criterion in 3 of
      # 3. So when one defect satisfies two criteria, citing either makes the
      # other unreachable, and recall is capped BY THE TRUTH SET rather than by
      # the reviewer. That happened here: S2 and S4 both scored the same
      # delete-before-archive lines, the reviewer labelled them S2 every time,
      # and case 17 tied at F1=0.889 against a de facto ceiling of 4/5.
      #
      # WHAT THIS CHECK ACTUALLY VERIFIES, WHICH IS LESS: that no two ids share
      # a marker STRING. Two different lines can still belong to one defect, and
      # nothing mechanical can tell that from the markers alone -- so this
      # catches the crude form and the reasoning above is what catches the rest.
      # Do not read a green here as proof the criteria are independent.
      _dupmark=0
      for _i in C1 S1 S2 S4 S6; do
        for _j in C1 S1 S2 S4 S6; do
          [ "$_i" = "$_j" ] && continue
          eval "_pi=\"\$_seed_$_i\""; eval "_pj=\"\$_seed_$_j\""
          [ "$_pi" = "$_pj" ] && _dupmark=1
        done
      done
      if [ "$_dupmark" -eq 0 ]; then
        sok "case 17's truth criteria are matched by distinct marker lines (the crude form of the one-label-per-defect cap)"
      else
        sbad "two of case 17's truth criteria share a marker line -- the reviewer cites one label per defect, so recall would be capped by the truth set, not the reviewer"
      fi

      _nfl=$(grep -c '^diff --git' "$_hdf" 2>/dev/null || true)
      if [ "${_nfl:-0}" -ge 3 ]; then
        sok "case 17's defects are spread over $_nfl files, not concentrated in one function"
      else
        sbad "case 17's defects sit in ${_nfl:-0} file(s) -- a single enclosing-function ring sees them all"
      fi
    fi
    rm -rf "$_hd"
  fi
fi

# --- case 12 must say WHAT KIND of leak it found ----------------------------
# Case 12's FAIL read "the schema is leaking", asserted from criterion ids
# alone. The ids cannot support that. A criterion new to round 2 is either a new
# citation or the SAME defect relabelled, and the reviewer was measured emitting
# one criterion per defect with the label varying between runs -- so a relabel
# is the likelier reading and it is a different, smaller finding: a bounded
# population with unstable labels, not an unbounded one.
_c12="$(sed -n '/^# CASE 12/,/^# CASE 13/p' acceptance/live-cases.sh)"
_c12l="$(printf '%s' "$_c12" | grep -vE '^[[:space:]]*#')"
if [ -z "$_c12" ]; then
  sbad "could not lift case 12 from live-cases.sh"
else
  if printf '%s' "$_c12l" | grep -qF 'SAME DEFECT, DIFFERENT LABEL'; then
    sok "case 12 separates a relabelled defect from a genuinely new citation, by span"
  else
    sbad "case 12 calls any new criterion a schema leak, which the ids alone cannot establish"
  fi
  # A relabel is still a FAIL: a re-audit that renames a finding makes the same
  # defect look new to the user. The characterisation must not become an excuse.
  if printf '%s' "$_c12l" | grep -qF 'bad "idempotence:'; then
    sok "case 12 still FAILS on a leak of either kind, rather than explaining one away"
  else
    sbad "case 12 no longer fails on a leaked criterion"
  fi
  # And when spans cannot be read, it must say the character is unmeasured
  # rather than defaulting to the flattering reading. INVARIANT 10 again.
  if printf '%s' "$_c12l" | grep -qF 'its CHARACTER is unmeasured'; then
    sok "case 12 reports the leak's character as unmeasured when spans are unavailable"
  else
    sbad "case 12 would guess at a leak's character when it cannot read the spans"
  fi
fi
# spans() must return NOTHING rather than a wrong answer on unparseable input --
# a fabricated span would send the reader to the wrong conclusion with
# confidence. Lifted and run against garbage.
_sp="$(sed -n '/^spans() {/,/^}$/p' acceptance/live-cases.sh)"
if [ -z "$_sp" ]; then
  sbad "could not lift spans() from live-cases.sh"
else
  _spd="$(mktemp -d)"
  printf 'not json at all\n' > "$_spd/bad.json"
  printf '[{"criterion_id":"S2","file":"a.js","line":7}]\n' > "$_spd/good.json"
  _spout=$( PY="python"; eval "$_sp"; printf 'BAD[%s] GOOD[%s]' \
            "$(spans "$_spd/bad.json" | tr '\n' ' ')" "$(spans "$_spd/good.json" | tr -d '\t' | tr '\n' ' ')" )
  case "$_spout" in
    "BAD[] GOOD[S2a.js:7 ]") sok "spans() reads real entries and returns nothing on unparseable input" ;;
    *) sbad "spans() misbehaves on the round trip (got: $_spout)" ;;
  esac
  rm -rf "$_spd"
fi

# --- every audit must keep its OWN pre-gate array ----------------------------
# audit() wrote every call's pre-gate violations to the same $WORK/raw.json, so
# each call overwrote the last and no two arms could be compared BEFORE gating.
# That is not a cosmetic loss: it is what stopped case 15 telling "the floor
# produced nothing" apart from "the floor produced findings and the gate deleted
# them" -- opposite conclusions about whether the floor is harmful.
_lc="$(grep -vE '^[[:space:]]*#' acceptance/live-cases.sh)"
if printf '%s' "$_lc" | grep -qF '"$WORK/raw.json"'; then
  sbad "audit() still writes every pre-gate array to one shared file"
else
  sok "audit() keeps a per-call pre-gate array, so arms can be compared before gating"
fi
if printf '%s' "$_lc" | grep -qF 'nofloor.raw.json' && printf '%s' "$_lc" | grep -qF 'floor.raw.json'; then
  sok "case 15 reads pre-gate as well as post-gate counts"
else
  sbad "case 15 still judges the ablation on post-gate counts alone"
fi
if printf '%s' "$_lc" | grep -qF 'the GATE removed them'; then
  sok "case 15 names the floor-harmful-but-gated case instead of calling it inconclusive"
else
  sbad "case 15 cannot distinguish a gated-away floor effect from no floor effect"
fi

echo
echo "  $SPASS passed, $SFAIL failed"
CHECKS=$((CHECKS + SPASS))
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
defer "case 17's verification rows have NO FINGERPRINT of the diff they certify. A row says 'this host is clean', but what was audited depends on DJ_FILES, which is the host's non-test .py files capped at six -- and the cap does not pick the six that carry the change. Change that selection (picking the largest-diff files is the obvious improvement) and every stale CLEAN row silently certifies a diff that no longer exists. That is the same failure class as verifying a superset: a guard attached to the wrong artifact. Fix: record a hash of the sorted file list in the row, recompute it at the gate, and refuse on mismatch -- which means a row without one is not verified, so the existing rows must be re-run. Deferred because it costs a re-verification of every host and the selection has not changed yet."
defer "case 17 arm (e), a SINGLE round told to walk the criteria list — BUILT 2026-09-07, RUN 2026-09-09 and 2026-09-10, n=2 INFORMATIVE and still deferred. FOUR runs: on 804660d6, run H informative and runs I and J refused CEILINGS (arm (a) scored 4/4, so no arm could beat it -- an arm that loses to a ceiling has not lost, and neither is counted for (e) any more than run C was counted against (c)); on 0f581cd2, run K informative. READ THE FLOOR CONTROL FIRST, and it is CLEAN on BOTH hosts: the criteria walk cited NOTHING on either unseeded host diff, so it is not a Cause A floor and INVARIANT 1 holds for it. Its scores are therefore readable, and they are the same score twice: F1=0.857, FP=0, cited S1 S2 S6, MISSED S4, and TIED arm (a) while spending HALF the audits -- on both runs arm (c) scored 1.000 and did reach S4. That REFUTES, 2 of 2, the 2026-09-07 prediction that pointing at the uncited criteria is arm (c)'s mechanism: the criteria list was in front of arm (e) the whole time and it never once reached S4. What (c) buys is seeing the previous round's ACTUAL CITATIONS, which is a different thing and is the part that needs a chain. Why this stays deferred: the NEGATIVE is settled at n=2 and licenses nothing to build, but 'ties (a) at half the budget' is an efficiency claim, and halving the product's audit budget on the strength of two ties would be a design change made on two runs. What is NOT deferred: nothing here licenses building a criteria-walk prompt into the product. Run: acceptance/live-cases.sh --case 17 --corpus django --repo <clone> --host 0f581cd29d42d1b5ed1dafb67794c2f3ce6705c9 -- prefer THAT host over 804660d6: it is 3 informative runs in 3 and has never ceilinged, where 804660d6 is 4 in 7 and drew its last two consecutively."
defer "case 17 arm (d), the revision round — STRUCTURALLY STUCK, not merely unrun. It withdrew nothing in 3 of 4 runs on 804660d6 and 3 of 3 on 0f581cd2, and correctly said so each time. Its only mechanism is removing a false positive; a host clean enough for a readable truth set produces none (FP=0 in every arm of every run on both verified hosts), and the one corpus that did produce them — f30acb18 — has a truth set that is not readable. It needs a host that is clean AND error-provoking. Nothing so far is both, and it is not obvious such a host exists."

echo
echo "=============================================================="
echo " summary"
echo "=============================================================="
echo "  suites: $SUITES_OK/$SUITES green"
echo "  checks: $CHECKS"

# The README carries this number, and only this number. Verify it rather than
# trusting it: it was wrong by 89 before anyone noticed.
# HANDOFF is checked too, and it matters MORE: it is the declared source of
# truth for a cold session. It sat at 174 while the suite ran 179, because the
# first version of this check guarded only the README.
_rmc=$(grep -oE '\*\*[0-9]+ checks green\*\*' README.md 2>/dev/null | grep -oE '[0-9]+' | head -1)
_hoc=$(grep -oE '\*\*[0-9]+\*\* checks' HANDOFF.md 2>/dev/null | grep -oE '[0-9]+' | head -1)
for _pair in "README.md:$_rmc" "HANDOFF.md:$_hoc"; do
  _f="${_pair%%:*}"; _n="${_pair##*:}"
  if [ -z "$_n" ]; then
    echo "  FAIL  $_f states no check count — the one figure it carries must be checkable"
    SUITES=$((SUITES + 1))
  elif [ "$_n" -ne "$CHECKS" ]; then
    echo "  FAIL  $_f says $_n checks; the suite runs $CHECKS. Update $_f."
    SUITES=$((SUITES + 1))
  else
    echo "  ok    $_f's check count matches the suite ($CHECKS)"
  fi
done
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
