#!/usr/bin/env bash
# ablation.sh — Arm A of evals/README.md: triforce WITH vs WITHOUT, paired, on
# real django commits with the commit's own tests as hidden ground truth.
#
#   bash acceptance/ablation.sh [--repo <django clone>] [--corpus <dir>] [--out <dir>]
#                               [--tasks 01,02,...] [--arms A,B] [--reps 2] [--dry-run]
#
# THE QUESTION. An outside review (evals/2026-09-15-defensibility-review.md)
# found zero of triforce's sixteen claimed benefits measured against the thing
# a user gets without it: one Opus session at high effort that plans and
# executes in one context. This is the measurement it specified, section 6,
# and the decision rule below is copied from there BEFORE any run.
#
# ARMS, both starting from a fresh worktree at <sha>^ with
# .claude/settings.json = {"worktree":{"baseRef":"head"}}:
#   A  baseline   claude -p --model opus --effort high "<task>", edit/bash tools,
#                 editing in place. No plugin.
#   B  triforce   claude -p --plugin-dir <this repo> "/triforce <task>", criteria
#                 pre-frozen (C1 = commit subject, plus S1-S6) so no
#                 AskUserQuestion is needed -- headless has none.
#
# METRICS per run, all retained under --out/<task>/<arm><rep>/:
#   pass        the commit's own tests/ hunks applied on top of the arm's output,
#               then the touched labels run: exit 0 is a PASS. Binary. PRIMARY.
#   tokens      per model, from the stream's result.modelUsage (input, output,
#               cache create, cache read) and total_cost_usd as the CLI reports it
#   wall        seconds, measured around the claude call
#   completed   the stream ended with a result of subtype success, and the arm
#               left a non-empty diff. A run that asked a question nobody could
#               answer, hit max turns, or timed out is NOT completed.
#   tier        B only: the preflight tier, read from the transcript
#   findings    B only: the gated findings, copied out of .triforce/ for
#               adjudication BY HAND against the hidden tests. Not automated.
#
# PRE-REGISTERED DECISION RULE (review section 6, verbatim in substance):
#   - B fails to complete headlessly in > 2 of 20 runs
#         -> production path unverified; verdict stays NOT DEFENSIBLE until fixed.
#   - Paired on tasks: if discordant pairs favour A
#         -> NOT DEFENSIBLE, stop.
#   - B >= A on pass rate AND median B/A token ratio <= 2.0
#         -> DEFENSIBLE WITH STATED CAVEATS as a default.
#   - B >= A on pass rate AND ratio > 2.0
#         -> defensible only as opt-in for T2/T3 diffs; publish the tier histogram.
#   - The audit's TP/FP tally is reported regardless.
#
# INVARIANT 10 applies to every cell: a run that did not execute is UNRUN, and
# an UNRUN cell is never a pass for either arm. The auth probe gates the whole
# script, as every live harness here does.
#
# COST. Each B run is zelda + a fresh plan reviewer + link + K auditors + the
# Stop hook. Forty runs is hours and real money; --tasks/--arms/--reps exist so
# it can be bought in instalments, and results.tsv is appended, never rewritten.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=acceptance/headless.sh
. "$ROOT/acceptance/headless.sh"

REPO="$ROOT/../django"; CORPUS="$ROOT/acceptance/ablation/corpus"; OUT="$ROOT/acceptance/ablation/runs"
TASKS=""; ARMS="A,B"; REPS=2; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --corpus) CORPUS="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --tasks) TASKS="$2"; shift 2 ;;
    --arms) ARMS="$2"; shift 2 ;;
    --reps) REPS="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) echo "ablation: unknown argument $1" >&2; exit 2 ;;
  esac
done
[ -d "$REPO/.git" ] || { echo "ablation: '$REPO' is not a git repository" >&2; exit 2; }
REPO="$(cd "$REPO" && pwd)"
[ -f "$CORPUS/corpus.tsv" ] || { echo "ablation: no corpus at $CORPUS; run ablation-corpus.sh first" >&2; exit 2; }
ABL_PY="${ABL_PY:-$ROOT/acceptance/.out/ablation-venv/Scripts/python.exe}"
[ -x "$ABL_PY" ] || ABL_PY="${ABL_PY%.exe}"
"$ABL_PY" -c "import asgiref, sqlparse" 2>/dev/null || {
  echo "ablation: ABL_PY='$ABL_PY' cannot import asgiref/sqlparse." >&2
  echo "  python -m venv acceptance/.out/ablation-venv && acceptance/.out/ablation-venv/Scripts/python -m pip install asgiref sqlparse" >&2
  exit 2; }
case "$REPS" in ''|*[!0-9]*|0) echo "ablation: --reps must be >= 1" >&2; exit 2 ;; esac

[ -n "$TASKS" ] || TASKS=$(ls -d "$CORPUS"/task* 2>/dev/null | sed 's|.*/task||' | tr '\n' ',' | sed 's/,$//')

# --- usability gate (same two diagnoses as live-cases.sh) -------------------
if [ "$DRY" = 0 ]; then
  if ! command -v claude >/dev/null 2>&1; then
    echo "  CANNOT RUN: 'claude' is not on PATH in this shell (Git Bash, not WSL). Every cell is UNRUN."; exit 2
  fi
  probe=$(timeout 90 claude -p "Reply with exactly: READY" --model haiku 2>&1)
  if ! printf '%s' "$probe" | grep -q "READY"; then
    echo "  CANNOT RUN: headless claude is not usable here."
    echo "  got: $(printf '%s' "$probe" | head -2)"
    echo "  Every cell is UNRUN, not a pass for either arm."; exit 2
  fi
fi

mkdir -p "$OUT"
RESULTS="$OUT/results.tsv"
[ -f "$RESULTS" ] || printf 'task\tarm\trep\tsha\tcompleted\tpass\twall_s\tcost_usd\ttokens_in\ttokens_out\tcache_create\tcache_read\tmodels\ttier\tnote\n' > "$RESULTS"

# usage_of <stream.jsonl> -> "cost<TAB>in<TAB>out<TAB>cc<TAB>cr<TAB>models<TAB>subtype<TAB>turns"
usage_of() {
  "$HL_PY" - "$1" <<'PY'
import json, sys
res = None; models = []
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line: continue
    try: d = json.loads(line)
    except Exception: continue
    if d.get("type") == "assistant":
        m = (d.get("message") or {}).get("model")
        if m and m not in models: models.append(m)
    if d.get("type") == "result": res = d
if res is None:
    print("\t".join(["", "", "", "", "", ",".join(models), "NO_RESULT", ""])); sys.exit(0)
mu = res.get("modelUsage") or {}
ti = to = cc = cr = 0
for mid, u in mu.items():
    if mid not in models: models.append(mid)
    ti += u.get("inputTokens", 0) or 0; to += u.get("outputTokens", 0) or 0
    cc += u.get("cacheCreationInputTokens", 0) or 0; cr += u.get("cacheReadInputTokens", 0) or 0
if not mu:
    u = res.get("usage") or {}
    ti = u.get("input_tokens", 0); to = u.get("output_tokens", 0)
    cc = u.get("cache_creation_input_tokens", 0); cr = u.get("cache_read_input_tokens", 0)
print("\t".join([str(res.get("total_cost_usd", "")), str(ti), str(to), str(cc), str(cr),
                 ",".join(models), str(res.get("subtype", "")), str(res.get("num_turns", ""))]))
PY
}

run_cell() {   # run_cell <task> <arm> <rep>
  local t="$1" arm="$2" rep="$3" T="$CORPUS/task$1" sha labels R WT base rc t0 t1 wall note="" tier="" completed=0 pass=0
  sha=$(cat "$T/sha.txt"); labels=$(cat "$T/labels.txt"); base="$sha^"
  R="$OUT/task$t/$arm$rep"; mkdir -p "$R"
  if [ -s "$R/meta.tsv" ]; then echo "  skip  task$t $arm$rep already recorded"; return 0; fi
  # OUTSIDE this repo: a django worktree inside it would be swept up by any
  # git add -A here, and its .git file would confuse both repos.
  WT="$(mktemp -d)/task$t-$arm$rep"
  git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1; rm -rf "$WT"
  git -C "$REPO" worktree add -q --detach "$WT" "$base" || { echo "  UNRUN task$t $arm$rep: worktree add failed"; return 1; }
  mkdir -p "$WT/.claude"; printf '{"worktree":{"baseRef":"head"}}\n' > "$WT/.claude/settings.json"
  # The arm never sees the reference patch or the tests patch. Assert it.
  [ ! -e "$WT/reference.patch" ] && [ ! -e "$WT/tests.patch" ] || { echo "  ABORT: answer key inside the worktree"; return 1; }
  local prompt; prompt=$(cat "$T/task.md")
  echo "  run   task$t $arm$rep  sha=$(git -C "$REPO" rev-parse --short "$sha")  labels=[$labels]"
  if [ "$DRY" = 1 ]; then echo "        (dry run: would invoke arm $arm in $WT)"; git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1; return 0; fi
  t0=$(date +%s)
  case "$arm" in
    A)
      ( cd "$WT" && timeout "${ABL_TIMEOUT:-2400}" claude -p --model opus --effort high \
          --output-format stream-json --verbose --dangerously-skip-permissions \
          "$prompt" > "$R/stream.jsonl" 2> "$R/stderr.txt" ); rc=$? ;;
    B)
      mkdir -p "$WT/.triforce"
      {
        printf 'C1\t%s\n' "$(head -1 "$T/task.md")"
        printf 'S1\tincorrect output or silently wrong result\n'
        printf 'S2\tdata loss or irreversible destruction\n'
        printf 'S3\tsecurity exposure\n'
        printf 'S4\tfailed or impossible rollback\n'
        printf 'S5\tunbounded resource consumption\n'
        printf 'S6\tconcurrency or ordering hazard\n'
      } > "$WT/.triforce/criteria.tsv"
      cp "$WT/.triforce/criteria.tsv" "$R/criteria.tsv"
      ( cd "$WT" && TRIFORCE_CRITERIA_FILE="$WT/.triforce/criteria.tsv" timeout "${ABL_TIMEOUT:-3600}" claude -p --plugin-dir "$ROOT" \
          --output-format stream-json --verbose --dangerously-skip-permissions \
          "/triforce $prompt" > "$R/stream.jsonl" 2> "$R/stderr.txt" ); rc=$? ;;
    *) echo "ablation: unknown arm $arm" >&2; return 2 ;;
  esac
  t1=$(date +%s); wall=$((t1 - t0))
  hl_transcript < "$R/stream.jsonl" > "$R/transcript.txt" 2>/dev/null
  IFS=$'\t' read -r cost tin tout cc cr models subtype turns < <(usage_of "$R/stream.jsonl")
  # What the arm produced, relative to base. Committed or not, staged or not.
  ( cd "$WT" && git add -A >/dev/null 2>&1 && git diff --cached "$base" -- . ':!.claude' ':!.triforce' > "$R/agent.diff" 2>/dev/null )
  if [ "$rc" -eq 124 ]; then note="TIMEOUT after ${ABL_TIMEOUT:-}s"
  elif [ "$subtype" != "success" ]; then note="result subtype=${subtype:-none} rc=$rc"
  elif ! grep -q '[^[:space:]]' "$R/agent.diff" 2>/dev/null; then note="EMPTY DIFF: the arm changed nothing"
  else completed=1; fi
  if [ "$arm" = B ]; then
    tier=$(grep -oE 'ganondorf-t[123]|tier[[:space:]]*[0-3]|\bT[0-3]\b' "$R/transcript.txt" 2>/dev/null | head -1)
    [ -d "$WT/.triforce" ] && cp -R "$WT/.triforce" "$R/triforce-state" 2>/dev/null
    grep -c 'AskUserQuestion' "$R/transcript.txt" >/dev/null 2>&1 && note="$note; mentions AskUserQuestion"
    # zelda's own worktrees, if any survived, are noise for git; prune after the copy.
  fi
  # HIDDEN ACCEPTANCE: the commit's tests on top of the arm's output. Applied to
  # the arm's tree exactly as left; a conflict with the arm's own test edits is
  # a fail, because the tests are the spec.
  if [ "$completed" = 1 ]; then
    if ( cd "$WT" && git apply --3way "$T/tests.patch" >"$R/apply.log" 2>&1 ); then
      # shellcheck disable=SC2086
      ( cd "$WT" && PYTHONPATH="$WT" timeout 900 "$ABL_PY" tests/runtests.py --parallel 1 --noinput $labels > "$R/tests.log" 2>&1 ); trc=$?
      [ "$trc" -eq 0 ] && pass=1 || note="$note; hidden tests rc=$trc"
    else
      note="$note; TESTS_APPLY_FAILED"; cp "$R/apply.log" "$R/tests.log"
    fi
  else
    echo "UNRUN or incomplete; hidden tests not applied" > "$R/tests.log"
  fi
  note="${note#; }"
  printf 'task\tarm\trep\tsha\tcompleted\tpass\twall_s\tcost_usd\ttokens_in\ttokens_out\tcache_create\tcache_read\tmodels\ttier\tnote\n' > "$R/meta.tsv"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$t" "$arm" "$rep" "$sha" "$completed" "$pass" "$wall" "$cost" "$tin" "$tout" "$cc" "$cr" "$models" "$tier" "$note" | tee -a "$RESULTS" | tail -1 >> "$R/meta.tsv"
  echo "        completed=$completed pass=$pass wall=${wall}s cost=\$${cost:-?} models=[$models] ${note:+note=$note}"
  git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1; rm -rf "$(dirname "$WT")"
  git -C "$REPO" worktree prune >/dev/null 2>&1
}

echo "triforce ablation (Arm A): with vs without, paired on hidden tests"
echo "  corpus $CORPUS   out $OUT   tasks [$TASKS]   arms [$ARMS]   reps $REPS"
echo
for rep in $(seq 1 "$REPS"); do
  for t in $(printf '%s' "$TASKS" | tr ',' ' '); do
    for arm in $(printf '%s' "$ARMS" | tr ',' ' '); do
      run_cell "$t" "$arm" "$rep"
    done
  done
done
echo
echo "results: $RESULTS"
