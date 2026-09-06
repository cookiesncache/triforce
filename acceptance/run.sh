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
