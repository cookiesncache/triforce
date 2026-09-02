#!/usr/bin/env bash
# probe-harness.sh — the cases that need a live model.
#
#   bash acceptance/probe-harness.sh
#
# Requires an authenticated `claude -p`. If `claude -p` reports "Not logged in",
# stop: nothing here can run, and a skipped case must never be reported green.
#
# Covers Step-0 probes P2-P4 and Tier-2 acceptance cases 2-6. Every assertion is
# POSITIVE — a wrong `worktree.baseRef` still produces a plausible-looking run,
# so "no error was raised" proves nothing here.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "triforce probe harness (live model required)"
echo

# --- auth gate --------------------------------------------------------------
probe=$(timeout 90 claude -p "Reply with exactly: READY" --model haiku 2>&1)
if ! printf '%s' "$probe" | grep -q "READY"; then
  echo "  CANNOT RUN: headless claude is not usable here."
  echo "  got: $(printf '%s' "$probe" | head -2)"
  echo
  echo "  Authenticate an interactive session first (/login), then re-run."
  echo "  Reporting these cases as SKIPPED, not passed."
  exit 2
fi
ok "headless claude responds"

# --- a scratch repo with the prerequisite set correctly ---------------------
R="$WORK/repo"; mkdir -p "$R/.claude/src"
(
  cd "$R" || exit 1
  git init -q -b main
  git config user.email t@example.com; git config user.name t
  printf '{ "worktree": { "baseRef": "head" } }\n' > .claude/settings.json
  echo "function f() { return 1; }" > src/app.js
  git add -A; git commit -qm base
) >/dev/null 2>&1

cd "$R" || exit 1
MAIN_TOPLEVEL="$(git rev-parse --show-toplevel)"

# zelda's state: a commit that exists ONLY on the integration branch. Case 3
# turns on an executor being able to see it.
git checkout -q -b triforce/run
echo "// marker from the orchestrator" >> src/app.js
git commit -qam "orchestrator commit, absent from main" >/dev/null 2>&1
ORCH_COMMIT="$(git rev-parse HEAD)"

MAIN_BEFORE="$(git rev-parse main)"
MAIN_TREE_BEFORE="$(git show --format=%T --no-patch main)"

# --- P2/P3 + case 2: every dispatch is isolated -----------------------------
OUT=$(timeout 600 claude -p "Use the link agent to do exactly this and nothing else: run 'git rev-parse --show-toplevel', run 'git rev-parse --abbrev-ref HEAD', and report both verbatim as TOPLEVEL=<x> BRANCH=<y>. Do not modify any file." \
      --plugin-dir "$ROOT" --allowedTools Bash Agent --permission-mode acceptEdits 2>&1)

EXEC_TOPLEVEL=$(printf '%s' "$OUT" | grep -oE 'TOPLEVEL=[^ ]+' | head -1 | cut -d= -f2)
if [ -n "$EXEC_TOPLEVEL" ] && [ "$EXEC_TOPLEVEL" != "$MAIN_TOPLEVEL" ]; then
  ok "case 2: executor cwd is NOT the main checkout ($EXEC_TOPLEVEL)"
else
  bad "case 2: executor is isolated — got '$EXEC_TOPLEVEL', main is '$MAIN_TOPLEVEL'"
fi
if printf '%s' "$EXEC_TOPLEVEL" | grep -q ".claude/worktrees/"; then
  ok "case 2: executor worktree is under .claude/worktrees/"
else
  bad "case 2: executor worktree is under .claude/worktrees/"
fi

# --- P4 + case 3: base targets the ORCHESTRATOR, not the default branch -----
# THE HIGHEST-VALUE TEST. With baseRef wrong this passes silently for the wrong
# reason, so assert the orchestrator's commit is an ancestor of the executor's
# HEAD — positively, from inside the executor.
OUT=$(timeout 600 claude -p "Use the link agent to run exactly: git merge-base --is-ancestor $ORCH_COMMIT HEAD; then echo ANCESTOR=\$?. Report that line verbatim. Do not modify any file." \
      --plugin-dir "$ROOT" --allowedTools Bash Agent --permission-mode acceptEdits 2>&1)
if printf '%s' "$OUT" | grep -q "ANCESTOR=0"; then
  ok "case 3: executor branches from the orchestrator's HEAD (baseRef: head works)"
else
  bad "case 3: executor branches from the orchestrator's HEAD — executors are building on the DEFAULT BRANCH"
  printf '%s\n' "$OUT" | tail -5
fi

# --- case 4: sole merge point — the main checkout never moves ---------------
MAIN_AFTER="$(git rev-parse main)"
MAIN_TREE_AFTER="$(git show --format=%T --no-patch main)"
if [ "$MAIN_BEFORE" = "$MAIN_AFTER" ] && [ "$MAIN_TREE_BEFORE" = "$MAIN_TREE_AFTER" ]; then
  ok "case 4: the default branch is byte-identical throughout execution"
else
  bad "case 4: the default branch moved during execution"
fi

# --- case 5: terminal-state cleanup after success ---------------------------
# The harness auto-removes only agents that finish with NO changes, and the
# periodic sweep skips any worktree holding work. Teardown is ours to do.
LEFTOVER_WT=$(git worktree list | grep -c "worktrees/agent-" || true)
LEFTOVER_BR=$(git branch --list 'worktree-agent-*' | wc -l | tr -d ' ')
if [ "${LEFTOVER_WT:-0}" -eq 0 ] && [ "${LEFTOVER_BR:-0}" -eq 0 ]; then
  ok "case 5: no residual worktrees or worktree-agent-* branches after a clean run"
else
  bad "case 5: residual worktrees=$LEFTOVER_WT branches=$LEFTOVER_BR"
  git worktree list
fi

# --- case 6: FAILED executors are RETAINED ----------------------------------
# Complement of case 5. Cleanup must be terminal-state-aware, not indiscriminate.
OUT=$(timeout 600 claude -p "Use the link agent to create a file named FAILED_MARKER containing the text 'left behind', then report TESTS -> FAIL and stop without cleaning up." \
      --plugin-dir "$ROOT" --allowedTools Bash Agent Write --permission-mode acceptEdits 2>&1)
KEPT_WT=$(git worktree list | grep -c "worktrees/agent-" || true)
if [ "${KEPT_WT:-0}" -gt 0 ]; then
  ok "case 6: a failed executor's worktree survives for inspection"
  git worktree list | grep "worktrees/agent-" | head -2
else
  bad "case 6: a failed executor's worktree was removed — cleanup is indiscriminate"
fi

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
