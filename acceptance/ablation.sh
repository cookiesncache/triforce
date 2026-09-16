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
#   Both arms: --strict-mcp-config (no MCP servers) and WebFetch/WebSearch
#   disallowed. The task names a django ticket, the ticket links the real PR,
#   and the first B cell fetched it. Hidden tests are not hidden from a model
#   that can read the answer.
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
# WINDOWS PATHS FOR THE CLI. MSYS_NO_PATHCONV=1 is needed so a leading
# "/triforce" is not rewritten into a Windows path -- but it also stops Git
# Bash converting "/c/Users/..." for --plugin-dir, and the CLI then silently
# loads no plugin ("Unknown command: /triforce", 2 seconds, no model). So every
# path handed to the CLI is converted here, explicitly.
wpath() { cygpath -m "$1" 2>/dev/null || printf '%s' "$1"; }
ROOT_W="$(wpath "$ROOT")"

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

# WHICH TRIFORCE SERVES A CELL IS ASSERTED, NOT ASSUMED.
#
# An installed copy of this plugin (triforce@cookiesncache-marketplace, the
# author's own marketplace) shadows --plugin-dir: with both present the
# marketplace copy won 3 of 3 probes from inside this repo and raced it from
# elsewhere. Disabling it suppresses the inline one too (the flag is by name).
# The first A cell ran WITH the installed plugin loaded -- skill, agents, Stop
# hook -- and the first B cells ran the installed copy's stale skill. Both are
# void. So: the installed copy is uninstalled for the run and reinstalled on
# exit, and every cell's init line is checked -- arm A must carry no triforce
# at all, arm B must carry triforce@inline at THIS repo -- or the cell is UNRUN.
MARKET_ID="triforce@cookiesncache-marketplace"
RESTORE_PLUGIN=0
if [ "$DRY" = 0 ] && grep -q "\"$MARKET_ID\"" "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null; then
  echo "  plugin  $MARKET_ID is installed and would shadow --plugin-dir; uninstalling for this run (restored on exit)"
  claude plugin uninstall --keep-data "$MARKET_ID" >/dev/null 2>&1 && RESTORE_PLUGIN=1
fi
restore_plugin() {
  if [ "$RESTORE_PLUGIN" = 1 ]; then
    if claude plugin install "$MARKET_ID" >/dev/null 2>&1; then echo "  plugin  $MARKET_ID reinstalled"
    else echo "  plugin  FAILED to reinstall $MARKET_ID -- run: claude plugin install $MARKET_ID" >&2; fi
  fi
}
trap restore_plugin EXIT

# plugin_state <stream.jsonl> -> "<source>|<path>|<skill 0/1>|<mcp count>" from the init line
plugin_state() {
  "$HL_PY" - "$1" <<'PY'
import json, sys
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    try: d = json.loads(line)
    except Exception: continue
    if d.get("type") == "system" and d.get("subtype") == "init":
        tf = [p for p in d.get("plugins", []) if p.get("name") == "triforce"]
        src = ",".join(p.get("source", "") for p in tf); path = ",".join(p.get("path", "") for p in tf)
        print("%s|%s|%d|%d" % (src, path.replace("\\", "/"), int("triforce:triforce" in d.get("skills", [])), len(d.get("mcp_servers", []))))
        sys.exit(0)
print("NO_INIT|||")
PY
}

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
  local _wt_before; _wt_before=$(git -C "$REPO" worktree list --porcelain | sed -n 's/^worktree //p' | sort)
  local _br_before; _br_before=$(git -C "$REPO" branch --format='%(refname:short)' | sort)
  if [ "$DRY" = 1 ]; then echo "        (dry run: would invoke arm $arm in $WT)"; git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1; return 0; fi
  t0=$(date +%s)
  case "$arm" in
    A)
      # The prompt goes in on STDIN for both arms: --disallowedTools is variadic
      # and swallowed a trailing prompt argument as a tool name. A slash command
      # on stdin still expands as a skill (probed).
      ( cd "$WT" && printf '%s' "$prompt" | MSYS_NO_PATHCONV=1 timeout "${ABL_TIMEOUT:-2400}" claude -p --model opus --effort high \
          --output-format stream-json --verbose --dangerously-skip-permissions \
          --strict-mcp-config --disallowedTools "WebFetch,WebSearch" \
          > "$R/stream.jsonl" 2> "$R/stderr.txt" ); rc=$? ;;
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
      # COMMITTED, not left untracked. zelda takes its OWN worktree (EnterWorktree,
      # step 2 of the skill) branched from this HEAD, and an untracked file does
      # not follow: the first counted B cell found no frozen file there,
      # extracted its own criteria, had no AskUserQuestion, asked in prose and
      # ended its turn. agent.diff already excludes both paths.
      ( cd "$WT" && git add .triforce/criteria.tsv .claude/settings.json && git -c user.email=ablation@local -c user.name=ablation commit -qm "ablation: frozen criteria and worktree setting" ) >/dev/null 2>&1
      # MSYS_NO_PATHCONV: Git Bash rewrites an argument that starts with "/" into
      # a Windows path, so "/triforce ..." reached the CLI as "C:/Program
      # Files/Git/triforce ..." and the first B cell ran with no skill at all.
      ( cd "$WT" && printf '/triforce %s' "$prompt" | MSYS_NO_PATHCONV=1 TRIFORCE_CRITERIA_FILE="$(wpath "$WT/.triforce/criteria.tsv")" timeout "${ABL_TIMEOUT:-3600}" claude -p --plugin-dir "$ROOT_W" \
          --output-format stream-json --verbose --dangerously-skip-permissions \
          --strict-mcp-config --disallowedTools "WebFetch,WebSearch" \
          > "$R/stream.jsonl" 2> "$R/stderr.txt" ); rc=$? ;;
    *) echo "ablation: unknown arm $arm" >&2; return 2 ;;
  esac
  t1=$(date +%s); wall=$((t1 - t0))
  hl_transcript < "$R/stream.jsonl" > "$R/transcript.txt" 2>/dev/null
  IFS=$'\t' read -r cost tin tout cc cr models subtype turns < <(usage_of "$R/stream.jsonl" | tr -d '\r')
  # WHAT THE ARM PRODUCED, and where. Arm A edits the checkout it was given.
  # Arm B does not: zelda takes its own worktree and, per its contract, leaves
  # the merged work on a named branch -- the first completed B cell was scored
  # "EMPTY DIFF" against a checkout zelda never touched, after a full run. So
  # for B the output is the newest branch the cell created, scored in a fresh
  # worktree of that branch; for A it is the checkout, as before.
  SCORE_WT="$WT"; OUT_REF=""
  if [ "$arm" = B ]; then
    OUT_REF=$(comm -13 <(printf '%s\n' "$_br_before") <(git -C "$REPO" branch --format='%(refname:short)' | sort) | grep -v '^$' | head -1)
    if [ -n "$OUT_REF" ]; then
      SCORE_WT="$(mktemp -d)/score"
      git -C "$REPO" worktree add -q --detach "$SCORE_WT" "$OUT_REF" 2>/dev/null || SCORE_WT="$WT"
    fi
  fi
  printf '%s\n' "${OUT_REF:-<checkout>}" > "$R/output-ref.txt"
  ( cd "$SCORE_WT" && git add -A >/dev/null 2>&1 && git diff --cached "$base" -- . ':!.claude' ':!.triforce' > "$R/agent.diff" 2>/dev/null )
  # tr -d '\r': Windows python prints CRLF, and "0\r" is not "0".
  IFS='|' read -r _psrc _ppath _pskill _pmcp < <(plugin_state "$R/stream.jsonl" | tr -d '\r')
  _rootn="$ROOT_W"
  _pstate_ok=1
  case "$arm" in
    A) [ -z "$_psrc" ] && [ "$_pskill" = 0 ] && [ "${_pmcp:-0}" = 0 ] || _pstate_ok=0 ;;
    B) [ "$_psrc" = "triforce@inline" ] && [ "$(printf '%s' "$_ppath" | tr 'A-Z' 'a-z')" = "$(printf '%s' "$_rootn" | tr 'A-Z' 'a-z')" ] && [ "${_pmcp:-0}" = 0 ] || _pstate_ok=0 ;;
  esac
  printf 'plugin_source\t%s\nplugin_path\t%s\ntriforce_skill\t%s\nmcp_servers\t%s\n' "$_psrc" "$_ppath" "$_pskill" "$_pmcp" > "$R/plugin-state.tsv"
  if [ "$_pstate_ok" = 0 ]; then note="WRONG PLUGIN STATE: source='$_psrc' path='$_ppath' skill=$_pskill mcp=$_pmcp -- UNRUN"
  elif [ "$rc" -eq 124 ]; then note="TIMEOUT after ${ABL_TIMEOUT:-}s"
  elif [ "$subtype" != "success" ]; then note="result subtype=${subtype:-none} rc=$rc"
  elif ! grep -q '[^[:space:]]' "$R/agent.diff" 2>/dev/null; then note="EMPTY DIFF: the arm changed nothing"
  else completed=1; fi
  if [ "$arm" = B ]; then
    tier=$(grep -oE 'ganondorf-t[123]|tier[[:space:]]*[0-3]|\bT[0-3]\b' "$R/transcript.txt" 2>/dev/null | head -1)
    [ -d "$WT/.triforce" ] && cp -R "$WT/.triforce" "$R/triforce-state" 2>/dev/null
    grep -c 'AskUserQuestion' "$R/transcript.txt" >/dev/null 2>&1 && note="$note; mentions AskUserQuestion"
    # zelda's own worktrees, if any survived, are noise for git; prune after the copy.
  fi
  # HIDDEN ACCEPTANCE: the commit's own test FILES replace the arm's versions,
  # then the touched labels run. This used to `git apply --3way` the tests
  # patch and call a conflict a fail; the first completed B cell conflicted
  # because it had written its own tests at the same place in the same file,
  # which measures where an arm puts its tests, not whether its implementation
  # works. Replacing the files scores every arm against the same tests with no
  # merge in the way. On task 01 the change altered no outcome: both arms fail
  # the same 2 + 6 either way (recorded in HANDOFF before any further cell).
  if [ "$completed" = 1 ]; then
    _tfiles=$(git -C "$REPO" diff --name-only "$base" "$sha" -- tests/)
    ( cd "$SCORE_WT" && for _f in $_tfiles; do
        mkdir -p "$(dirname "$_f")"; git -C "$REPO" show "$sha:$_f" > "$_f" 2>/dev/null || rm -f "$_f"
      done ) && echo "test files replaced from $sha: $_tfiles" > "$R/apply.log"
    # shellcheck disable=SC2086
    ( cd "$SCORE_WT" && PYTHONPATH="$SCORE_WT" timeout 900 "$ABL_PY" tests/runtests.py --parallel 1 --noinput $labels > "$R/tests.log" 2>&1 ); trc=$?
    [ "$trc" -eq 0 ] && pass=1 || note="$note; hidden tests rc=$trc"
  else
    echo "UNRUN or incomplete; hidden tests not applied" > "$R/tests.log"
  fi
  note="${note#; }"
  printf 'task\tarm\trep\tsha\tcompleted\tpass\twall_s\tcost_usd\ttokens_in\ttokens_out\tcache_create\tcache_read\tmodels\ttier\tnote\n' > "$R/meta.tsv"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$t" "$arm" "$rep" "$sha" "$completed" "$pass" "$wall" "$cost" "$tin" "$tout" "$cc" "$cr" "$models" "$tier" "$note" | tee -a "$RESULTS" | tail -1 >> "$R/meta.tsv"
  echo "        completed=$completed pass=$pass wall=${wall}s cost=\$${cost:-?} models=[$models] ${note:+note=$note}"
  git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1; rm -rf "$(dirname "$WT")"
  [ "$SCORE_WT" != "$WT" ] && { git -C "$REPO" worktree remove --force "$SCORE_WT" >/dev/null 2>&1; rm -rf "$(dirname "$SCORE_WT")"; }
  # zelda's own worktrees (and their branches) do not outlive the cell. Their
  # content is already in agent.diff if it was merged, and in the stream if not.
  local _w
  while IFS= read -r _w; do
    [ -n "$_w" ] || continue
    git -C "$REPO" worktree unlock "$_w" >/dev/null 2>&1
    git -C "$REPO" worktree remove --force "$_w" >/dev/null 2>&1 || rm -rf "$_w"
  done < <(comm -13 <(printf '%s\n' "$_wt_before") <(git -C "$REPO" worktree list --porcelain | sed -n 's/^worktree //p' | sort) | grep -v '^$')
  git -C "$REPO" worktree prune >/dev/null 2>&1
  comm -13 <(printf '%s\n' "$_br_before") <(git -C "$REPO" branch --format='%(refname:short)' | sort) | grep -v '^$' \
    | xargs -r -n1 git -C "$REPO" branch -D >/dev/null 2>&1
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
