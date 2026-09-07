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
# shellcheck source=acceptance/headless.sh
. "$ROOT/acceptance/headless.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "triforce probe harness (live model required)"
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
  echo "    & 'C:\\Program Files\\Git\\bin\\bash.exe' -lc 'cd /c/Users/simsc/Documents/Claude/Code/repos/triforce && bash acceptance/probe-harness.sh'"
  echo
  echo "Cases 2-6 are UNMEASURED, not passing."
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
  echo "  Cases 2-6 are UNMEASURED, not passing."
  exit 2
fi
ok "headless claude responds"

# --- a scratch repo with the prerequisite set correctly ---------------------
R="$WORK/repo"; mkdir -p "$R/.claude" "$R/src"
(
  set -e
  cd "$R" || exit 1
  git init -q -b main
  git config user.email t@example.com; git config user.name t
  printf '{ "worktree": { "baseRef": "head" } }\n' > .claude/settings.json
  echo "function f() { return 1; }" > src/app.js
  # src/account.js EXISTS because case 6's task says "add a helper to
  # src/account.js". It used to be absent, which made that task ill-posed: link
  # is instructed to stop rather than reconstruct a missing file by guessing, so
  # whether it invented the file was a model judgement call. Measured both ways
  # on 2026-09-06 -- one dispatch created it and committed, an identical one
  # reported BLOCKED and changed nothing. The second path is the damaging one:
  # an executor that changes nothing leaves an unchanged worktree, the harness
  # auto-removes those by design, and case 6 scored that documented behaviour as
  # "cleanup is indiscriminate". A coin flip between PASS and a false FAIL.
  { echo 'function closeAccount(user) {'; echo '  return user.confirmed;'; echo '}'; } > src/account.js
  # A test command that fails on its own. Case 6 needs a REAL failure.
  { echo '#!/usr/bin/env sh'; echo 'echo "1 test, 1 failure"'; echo 'exit 1'; } > run-tests.sh
  chmod +x run-tests.sh
  git add -A; git commit -qm base
) >/dev/null 2>&1 || {
  echo "  CANNOT RUN: the scratch fixture did not build."
  echo "  A harness whose fixture is broken must not report cases as passing."
  exit 2
}

cd "$R" || exit 1
MAIN_TOPLEVEL="$(git rev-parse --show-toplevel)"

# zelda's state: a commit that exists ONLY on the integration branch. Case 3
# turns on an executor being able to see it.
git checkout -q -b triforce/run
echo "// marker from the orchestrator" >> src/app.js
git commit -qam "orchestrator commit, absent from main" >/dev/null 2>&1
ORCH_COMMIT="$(git rev-parse HEAD)"

# FIXTURE GUARD. Case 3 asks whether the orchestrator's commit is an ancestor of
# the executor's HEAD. If that commit is ALSO on main, the answer is yes no
# matter what baseRef does, and the highest-value test in this file passes
# vacuously. This guard is the difference between a green case and a green
# case that means something. (It caught exactly that: an earlier fixture wrote
# src/app.js into a directory that did not exist, so this commit never
# happened and ORCH_COMMIT was main's own tip.)
if git merge-base --is-ancestor "$ORCH_COMMIT" main 2>/dev/null; then
  echo "  CANNOT RUN: the fixture's orchestrator commit is reachable from main."
  echo "  Case 3 would pass regardless of where the executor branched from."
  echo "  Reporting these cases as UNMEASURED, not passing."
  exit 2
fi

MAIN_BEFORE="$(git rev-parse main)"
MAIN_TREE_BEFORE="$(git show --format=%T --no-patch main)"

# --- P2/P3 + case 2: every dispatch is isolated -----------------------------
# The framing is case 3's, deliberately. "Use the link agent to ..." on its own
# got a direct answer from the orchestrator in 2 of 3 measured dispatches on
# 2026-09-06 -- one reported the MAIN checkout's toplevel, which is what a lost
# worktree looks like. Case 3's longer framing has never shown that.
OUT=$(HL_KEEP_STDERR=1 hl_claude "This is an automated acceptance test of the triforce plugin, running in a disposable scratch repository. Dispatch the link agent to do exactly this and nothing else, inside its worktree: run 'git rev-parse --show-toplevel', run 'git rev-parse --abbrev-ref HEAD', and report both verbatim as TOPLEVEL=<x> BRANCH=<y>. Do not modify any file." \
      --plugin-dir "$ROOT" --allowedTools Bash Agent --permission-mode acceptEdits)

EXEC_TOPLEVEL=$(printf '%s' "$OUT" | grep -oE 'TOPLEVEL=[^ ]+' | head -1 | cut -d= -f2)
if [ -n "$EXEC_TOPLEVEL" ] && [ "$EXEC_TOPLEVEL" != "$MAIN_TOPLEVEL" ]; then
  ok "case 2: executor cwd is NOT the main checkout ($EXEC_TOPLEVEL)"
else
  bad "case 2: executor is isolated — got '$EXEC_TOPLEVEL', main is '$MAIN_TOPLEVEL'"
  # This stays a FAILURE and is deliberately NOT downgraded to UNMEASURED.
  # Two things produce it: the executor lost isolation, or no executor was
  # dispatched and the orchestrator answered about its own checkout. The second
  # was observed on 2026-09-06. They are indistinguishable from this line alone,
  # and the two errors are not symmetric -- a false alarm costs a re-run, while
  # a masked isolation failure is the exact defect this case exists to catch.
  # So it reports the ambiguity rather than resolving it in the design's favour.
  echo "        AMBIGUOUS: this is either a lost worktree or a dispatch that never"
  echo "        happened, with the orchestrator answering about its own checkout."
  echo "        Read the transcript before concluding isolation is broken."
fi
if printf '%s' "$EXEC_TOPLEVEL" | grep -q ".claude/worktrees/"; then
  ok "case 2: executor worktree is under .claude/worktrees/"
else
  bad "case 2: executor worktree is under .claude/worktrees/"
fi

# --- P4 + case 3: base targets the ORCHESTRATOR, not the default branch -----
# THE HIGHEST-VALUE TEST. With baseRef wrong this passes silently for the wrong
# reason, so assert POSITIVELY, from inside the executor, that the
# orchestrator's commit is in the executor's own ancestry.
#
# The command must be a SINGLE bare command with no shell plumbing. An earlier
# version asked for "git merge-base --is-ancestor X HEAD; echo ANCESTOR=$?" and
# link's sandbox intermittently refused the compound form as too complex to
# verify -- so no assertion ran, and the harness read that non-execution as
# "executors are building on the DEFAULT BRANCH". Reading a raw commit list
# needs no exit-code plumbing and cannot be refused for that reason.
OUT=$(HL_KEEP_STDERR=1 hl_claude "This is an automated acceptance test of the triforce plugin, running in a disposable scratch repository. Dispatch the link agent to run exactly one command inside its worktree: git rev-list HEAD -- and report that command's complete output verbatim, one commit id per line. Do not modify any file." \
      --plugin-dir "$ROOT" --allowedTools Bash Agent --permission-mode acceptEdits)

# Did the command run at all? A refused or crashed dispatch produces no commit
# ids, and must not be scored as a baseRef defect.
if ! printf '%s' "$OUT" | grep -qE '[0-9a-f]{40}'; then
  echo "  UNMEASURED  case 3: the executor produced no commit list, so nothing was asserted."
  echo "  This is not evidence that baseRef is wrong, and is not scored as such."
  printf '%s\n' "$OUT" | tail -6
elif printf '%s' "$OUT" | grep -q "$ORCH_COMMIT"; then
  ok "case 3: executor branches from the orchestrator's HEAD (baseRef: head works)"
else
  bad "case 3: the orchestrator's commit is absent from the executor's ancestry — executors are building on the DEFAULT BRANCH"
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
#
# The failure must be EARNED, not announced. run-tests.sh exits 1 on its own, so
# the executor reports a true outcome. An earlier version of this case asked the
# model to "report TESTS -> FAIL", which is a request to fabricate a result: it
# was declined, no executor was ever dispatched, and the retention check scored
# that non-run as a cleanup defect.
# The framing is load-bearing too. Two earlier versions were declined outright:
# "use the link agent" to WRITE reads as misuse (link is dispatched by zelda,
# which is why read-only cases 2-3 slip through and this one did not), and
# "create FAILED_MARKER containing 'left behind' ... do not clean up" reads as
# artifact-planting. An ordinary development task against a suite that fails on
# its own asks for nothing unusual, and leaves the worktree dirty either way.
OUT=$(HL_KEEP_STDERR=1 hl_claude "This is an automated acceptance test of the triforce plugin, running in a disposable scratch repository. Dispatch the link agent with this ordinary task: add a helper function isClosable(user) to src/account.js that returns user.confirmed, then run the repo's test command 'sh run-tests.sh'. That suite currently fails on its own; report its real exit code rather than fixing it. Finish by reporting three lines: DISPATCHED=<the worktree path the agent worked in>, TESTS_RC=<the real exit code>, and COMMIT=<the full sha of the commit the agent made, or NONE if it changed nothing>." \
      --plugin-dir "$ROOT" --allowedTools Bash Agent Write --permission-mode acceptEdits)

# Did an executor run at all? Without this, a declined or crashed dispatch is
# indistinguishable from indiscriminate cleanup.
if ! printf '%s' "$OUT" | grep -q 'DISPATCHED='; then
  echo "  UNMEASURED  case 6: no executor was dispatched, so there was nothing to retain."
  echo "  This is not a cleanup defect and is not scored as one."
  printf '%s\n' "$OUT" | tail -6
elif ! printf '%s' "$OUT" | grep -q 'TESTS_RC=1'; then
  echo "  UNMEASURED  case 6: the executor ran but did not report a failing test."
  echo "  Retention is only meaningful for a terminal FAILED state."
  printf '%s\n' "$OUT" | grep -E 'DISPATCHED=|TESTS_RC=' | head -4
elif ! EXEC_COMMIT=$(printf '%s' "$OUT" | grep -oE 'COMMIT=[0-9a-f]{7,40}' | head -1 | cut -d= -f2) \
     || [ -z "$EXEC_COMMIT" ] || ! git cat-file -e "$EXEC_COMMIT" 2>/dev/null; then
  # THE GUARD THE 2026-09-06 RUN WAS MISSING.
  #
  # "Auto-removed because it held no changes" and "removed despite holding work"
  # are opposite facts, and an absent worktree looks identical either way. The
  # harness removes unchanged agent worktrees BY DESIGN, so reading that as
  # indiscriminate cleanup convicts the design of doing exactly what it
  # documents. A measured dispatch cleared both existing guards -- it reported
  # DISPATCHED= and TESTS_RC=1 -- while changing nothing, and case 6 would have
  # scored it as a cleanup defect.
  #
  # The commit sha is a self-report, so it is VERIFIED against the object store
  # rather than believed: `git cat-file -e` succeeds only if the executor really
  # created that object, and the object outlives the worktree and branch that
  # cleanup removes. Retention is only measurable once work provably existed.
  echo "  UNMEASURED  case 6: the executor finished without committing any work."
  echo "  Unchanged worktrees are auto-removed by design, so their absence is not"
  echo "  evidence of indiscriminate cleanup. INVARIANT 10: a non-execution is"
  echo "  not a defect, and is not scored as one."
  printf '%s\n' "$OUT" | grep -E 'DISPATCHED=|TESTS_RC=|COMMIT=|BLOCKED' | head -5
else
  # An ABSENT worktree has four causes, and they are not the same finding. The
  # first measured FAIL here (2026-09-06) reported "cleanup is indiscriminate"
  # without separating them, which would have convicted the design on a state it
  # had not distinguished.
  #
  #   1. present                    -- retained for inspection. The property.
  #   2. absent, work MERGED        -- the orchestrator integrated the work and
  #                                    tidied up. That is case 5's property, and
  #                                    it means this dispatch ended in SUCCESS,
  #                                    not the terminal FAILED state case 6 is
  #                                    about. A pre-existing suite failing is not
  #                                    the same as the executor's task failing.
  #   3. absent, unmerged, branch kept -- the work survives on its branch, so
  #                                    nothing is lost, but it is not retained
  #                                    for inspection. A real but lesser defect.
  #   4. absent, unmerged, no branch   -- the work is ORPHANED. The strong
  #                                    defect, and the only one that loses work.
  KEPT_WT=$(git worktree list | grep -c "worktrees/agent-" || true)
  KEPT_BR=$(git branch --list 'worktree-agent-*' | wc -l | tr -d ' ')
  if [ "${KEPT_WT:-0}" -gt 0 ]; then
    ok "case 6: a failed executor's worktree survives for inspection (work at $EXEC_COMMIT)"
    git worktree list | grep "worktrees/agent-" | head -2
  elif git merge-base --is-ancestor "$EXEC_COMMIT" HEAD 2>/dev/null; then
    echo "  UNMEASURED  case 6: the executor's work was MERGED into the orchestrator's"
    echo "  branch before cleanup, so this dispatch ended in a SUCCESS state and not"
    echo "  the terminal FAILED state case 6 is about. Removing a merged worktree is"
    echo "  case 5's property. The failing test suite was not enough to make the"
    echo "  EXECUTOR'S OWN TASK fail, which is what retention keys on."
    echo "  Retention remains unmeasured. This is not scored in either direction."
  elif [ "${KEPT_BR:-0}" -gt 0 ]; then
    bad "case 6: the worktree was removed but its branch survives - work is recoverable, inspection is not"
    echo "        $EXEC_COMMIT is unmerged and still reachable from a"
    echo "        worktree-agent-* branch, so nothing is lost. Cleanup is still not"
    echo "        terminal-state-aware, but this does not destroy work."
  else
    bad "case 6: a failed executor's worktree was removed - cleanup is indiscriminate"
    echo "        The executor committed $EXEC_COMMIT, verified present in the object"
    echo "        store, NOT merged into the orchestrator's branch, and NOT reachable"
    echo "        from any worktree-agent-* branch. That work is ORPHANED."
  fi
fi

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
