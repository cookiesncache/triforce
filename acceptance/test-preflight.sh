#!/usr/bin/env bash
# test-preflight.sh — acceptance case 1 and its neighbours.
#
# Case 1: "Preflight catches the silent misconfiguration. With worktree.baseRef
# unset or fresh, zelda refuses or warns loudly. Fails if the run proceeds
# quietly." So the assertion is on the EXIT CODE and the message, not on the
# absence of an error.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
P="$ROOT/skills/triforce/scripts/preflight.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }

mkrepo() {  # mkrepo <name> <baseRef-json-or-empty>
  local d="$WORK/$1"
  mkdir -p "$d/.claude/src"
  (
    cd "$d" || exit 1
    git init -q -b main
    git config user.email t@e.com; git config user.name t
    echo "function f() { return 1; }" > src.js
    [ -n "$2" ] && printf '%s\n' "$2" > .claude/settings.json
    git add -A; git commit -qm base
    echo "function f() { return 2; }" > src.js
    git commit -qam change
  ) >/dev/null 2>&1
  echo "$d"
}

echo "preflight"
echo

# --- baseRef unset: MUST block ----------------------------------------------
d=$(mkrepo unset "")
out=$(cd "$d" && env -u CLAUDE_CODE_SUBAGENT_MODEL bash "$P" 2>&1); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "worktree.baseRef is UNSET"; then
  ok "baseRef unset blocks (exit 1) and names the setting"
else
  bad "baseRef unset blocks — exit=$rc"; printf '%s\n' "$out" | tail -5
fi

# --- baseRef: fresh — MUST block --------------------------------------------
d=$(mkrepo fresh '{ "worktree": { "baseRef": "fresh" } }')
out=$(cd "$d" && env -u CLAUDE_CODE_SUBAGENT_MODEL bash "$P" 2>&1); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'baseRef is "fresh"'; then
  ok "baseRef=fresh blocks (exit 1) and quotes the wrong value"
else
  bad "baseRef=fresh blocks — exit=$rc"; printf '%s\n' "$out" | tail -5
fi

# --- baseRef: head — MUST pass ----------------------------------------------
d=$(mkrepo head '{ "worktree": { "baseRef": "head" } }')
out=$(cd "$d" && env -u CLAUDE_CODE_SUBAGENT_MODEL bash "$P" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "worktree.baseRef = head"; then
  ok "baseRef=head passes (exit 0) and says so positively"
else
  bad "baseRef=head passes — exit=$rc"; printf '%s\n' "$out" | tail -8
fi

# --- the escape hatch is loud, not silent -----------------------------------
d=$(mkrepo unsafe "")
out=$(cd "$d" && env -u CLAUDE_CODE_SUBAGENT_MODEL bash "$P" --allow-unsafe-base 2>&1); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "allow-unsafe-base"; then
  ok "--allow-unsafe-base proceeds but announces itself"
else
  bad "--allow-unsafe-base proceeds loudly — exit=$rc"
fi

# --- CLAUDE_CODE_SUBAGENT_MODEL overrides every pin: MUST block -------------
d=$(mkrepo model '{ "worktree": { "baseRef": "head" } }')
out=$(cd "$d" && CLAUDE_CODE_SUBAGENT_MODEL=haiku bash "$P" 2>&1); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "CLAUDE_CODE_SUBAGENT_MODEL"; then
  ok "CLAUDE_CODE_SUBAGENT_MODEL blocks (it outranks frontmatter)"
else
  bad "CLAUDE_CODE_SUBAGENT_MODEL blocks — exit=$rc"
fi

# --- version comes from the binary, never from the env var ------------------
d=$(mkrepo version '{ "worktree": { "baseRef": "head" } }')
out=$(cd "$d" && CLAUDE_CODE_VERSION=2.1.42 env -u CLAUDE_CODE_SUBAGENT_MODEL bash "$P" 2>&1)
if printf '%s' "$out" | grep -q "read from the binary"; then
  ok "version read from 'claude --version', not CLAUDE_CODE_VERSION"
else
  bad "version read from the binary"
fi
if printf '%s' "$out" | grep -q "CLAUDE_CODE_VERSION=2.1.42 disagrees"; then
  ok "a disagreeing CLAUDE_CODE_VERSION is noted and ignored"
else
  bad "a disagreeing CLAUDE_CODE_VERSION is noted"
fi

# --- the card carries a tier and its model pin ------------------------------
d=$(mkrepo card '{ "worktree": { "baseRef": "head" } }')
out=$(cd "$d" && env -u CLAUDE_CODE_SUBAGENT_MODEL bash "$P" 2>&1)
if printf '%s' "$out" | grep -qE '^\│ tier      T[0-3]'; then
  ok "preflight card states the tier"
else
  bad "preflight card states the tier"; printf '%s\n' "$out" | head -6
fi
if printf '%s' "$out" | grep -qE 'audit     (SKIPPED|ganondorf-t[123])'; then
  ok "preflight card names the auditor (or says SKIPPED)"
else
  bad "preflight card names the auditor"
fi

# --- not a git repo is exit 2, distinct from a blocking condition -----------
mkdir -p "$WORK/nogit"
out=$(cd "$WORK/nogit" && bash "$P" 2>&1); rc=$?
if [ "$rc" -eq 2 ]; then
  ok "non-repo exits 2 (could not run), distinct from exit 1 (blocked)"
else
  bad "non-repo exits 2 — got $rc"
fi

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
