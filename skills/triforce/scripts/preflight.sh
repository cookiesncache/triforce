#!/usr/bin/env bash
# preflight.sh — run before anything is dispatched. Refuses loudly rather than
# misbehaving quietly.
#
#   preflight.sh [--base <ref>] [--json] [--allow-unsafe-base]
#
# Exit 0 = safe to proceed. Exit 1 = a BLOCKING condition; the caller must stop
# and tell the user, not work around it. Exit 2 = preflight itself could not run.
#
# Everything here is a SILENT failure mode. A wrong `worktree.baseRef` still
# produces a plausible-looking run in which every executor quietly builds on the
# default branch instead of the orchestrator's work. So the assertions are
# positive: we check that the setting IS "head", never that no error appeared.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE=""
AS_JSON=0
ALLOW_UNSAFE_BASE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE="$2"; shift 2 ;;
    --json) AS_JSON=1; shift ;;
    --allow-unsafe-base) ALLOW_UNSAFE_BASE=1; shift ;;
    *) echo "preflight: unknown argument $1" >&2; exit 2 ;;
  esac
done

CRITERIA_FILE="${TRIFORCE_CRITERIA_FILE:-.triforce/criteria.tsv}"

BLOCKING=()
WARNINGS=()
NOTES=()

block() { BLOCKING+=("$1"); }
warn()  { WARNINGS+=("$1"); }
note()  { NOTES+=("$1"); }

# --- 0. a git repo at all ---------------------------------------------------
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "preflight: not a git repository — triforce needs one" >&2
  exit 2
fi
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
CUR_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"

# --- 1. CLI version — from the binary, NEVER from CLAUDE_CODE_VERSION -------
# CLAUDE_CODE_VERSION has been observed carrying a malformed value (2.1.42)
# that predates features the environment demonstrably has. Shell out instead.
CLI_VERSION="$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
if [ -z "$CLI_VERSION" ]; then
  warn "could not read 'claude --version'; version-gated behaviour is unverified"
  CLI_VERSION="unknown"
else
  note "claude $CLI_VERSION (read from the binary, not CLAUDE_CODE_VERSION)"
fi
if [ -n "${CLAUDE_CODE_VERSION:-}" ] && [ "${CLAUDE_CODE_VERSION}" != "$CLI_VERSION" ]; then
  note "CLAUDE_CODE_VERSION=${CLAUDE_CODE_VERSION} disagrees with the binary; ignoring it, by design"
fi

ver_ge() {  # ver_ge <have> <want>
  [ "$1" = "unknown" ] && return 1
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]
}

# --- 2. worktree.baseRef — the silent misconfiguration ----------------------
# Subagent worktrees branch from the repository's DEFAULT BRANCH unless this is
# "head". Without it every executor silently builds on main, and the run still
# looks fine. A plugin cannot write a user's settings.json, so this is a
# documented prerequisite we must verify rather than assume.
read_setting() {  # read_setting <file> <dotted.path>
  [ -f "$1" ] || return 1
  tr -d ' \n' < "$1" \
    | grep -oE "\"worktree\":\{[^}]*\}" 2>/dev/null \
    | grep -oE "\"baseRef\":\"[^\"]*\"" 2>/dev/null \
    | sed 's/.*"baseRef":"\([^"]*\)".*/\1/' | head -1
}

BASEREF=""
BASEREF_SRC=""
for f in "$REPO_ROOT/.claude/settings.local.json" \
         "$REPO_ROOT/.claude/settings.json" \
         "$HOME/.claude/settings.json"; do
  v="$(read_setting "$f" 2>/dev/null)"
  if [ -n "$v" ]; then BASEREF="$v"; BASEREF_SRC="$f"; break; fi
done

if [ "$BASEREF" = "head" ]; then
  note "worktree.baseRef = head  (from ${BASEREF_SRC#"$REPO_ROOT/"})"
elif [ -z "$BASEREF" ]; then
  if [ "$ALLOW_UNSAFE_BASE" -eq 1 ]; then
    warn "worktree.baseRef is UNSET; proceeding only because --allow-unsafe-base was passed"
  else
    block "worktree.baseRef is UNSET. Executor worktrees will branch from the repository's DEFAULT BRANCH, not from the orchestrator's work, and the run will look normal while every executor builds on the wrong base. Add this to .claude/settings.json and start a new session:
        { \"worktree\": { \"baseRef\": \"head\" } }"
  fi
else
  if [ "$ALLOW_UNSAFE_BASE" -eq 1 ]; then
    warn "worktree.baseRef is \"$BASEREF\"; proceeding only because --allow-unsafe-base was passed"
  else
    block "worktree.baseRef is \"$BASEREF\", not \"head\". Executors would branch from the default branch instead of the orchestrator's state, breaking isolation invariant 2. Set it to \"head\" in ${BASEREF_SRC:-.claude/settings.json}. (The setting accepts only \"fresh\" or \"head\" — never a branch name.)"
  fi
fi

# --- 3. CLAUDE_CODE_SUBAGENT_MODEL outranks frontmatter ---------------------
# It sits ABOVE the agent definition in model resolution, so a user with it set
# silently overrides every pin and the entire cost design with it.
if [ -n "${CLAUDE_CODE_SUBAGENT_MODEL:-}" ]; then
  block "CLAUDE_CODE_SUBAGENT_MODEL=${CLAUDE_CODE_SUBAGENT_MODEL} is set. It outranks agent frontmatter, so every triforce model pin is overridden and the tier cost model does not hold. Unset it, or accept that zelda/link/ganondorf all run on ${CLAUDE_CODE_SUBAGENT_MODEL}."
else
  note "CLAUDE_CODE_SUBAGENT_MODEL is unset; frontmatter pins apply"
fi

# --- 4. spawn depth ---------------------------------------------------------
# `context: fork` does not consume a depth level (the fork builds a base agent
# rather than spawning a subagent), so zelda sits at the main thread's depth and
# link at depth 1. Only navi, at depth 2, needs nesting enabled.
DEPTH="${CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH:-}"
if [ -z "$DEPTH" ]; then
  if ver_ge "$CLI_VERSION" "2.1.219"; then
    note "spawn depth: default (3 below main) — nesting available"
  else
    note "spawn depth: not configurable on claude $CLI_VERSION (env var landed in 2.1.219)"
  fi
elif [ "$DEPTH" = "1" ]; then
  note "spawn depth = 1: link runs, navi is unavailable (this is the web default, by platform policy)"
else
  note "spawn depth = $DEPTH"
fi

# --- 5. concurrency ceiling is USER config; we only report it ---------------
note "max concurrent subagents: ${CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS:-20 (default)}"

# --- 6. .worktreeinclude ----------------------------------------------------
# A worktree is a fresh checkout, so gitignored files are absent. Executors that
# run tests fail without them, usually in a confusing way.
if [ -f "$REPO_ROOT/.worktreeinclude" ]; then
  note ".worktreeinclude present"
else
  ENVISH=$(ls -a "$REPO_ROOT" 2>/dev/null | grep -cE '^\.env' || true)
  if [ "${ENVISH:-0}" -gt 0 ]; then
    warn "no .worktreeinclude, but this repo has .env files. Executor worktrees are fresh checkouts and will not have them; tests that need them will fail inside isolation."
  fi
fi

# --- 7. a clean-enough tree -------------------------------------------------
DIRTY=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
if [ "${DIRTY:-0}" -gt 0 ]; then
  warn "$DIRTY uncommitted change(s) in the main checkout. Executors branch from committed state; uncommitted work will not be visible to them."
fi

# --- 8. risk score / tier ---------------------------------------------------
TIER=""; SCORE=""; ENVELOPE=""; FLOORS=""; OVER=""
if [ -z "$BASE" ]; then
  BASE="$(git merge-base HEAD "@{upstream}" 2>/dev/null || true)"
  [ -z "$BASE" ] && BASE="$(git rev-parse HEAD 2>/dev/null)"
fi
if [ -x "$HERE/risk-score.sh" ] || [ -f "$HERE/risk-score.sh" ]; then
  RS="$(bash "$HERE/risk-score.sh" "$BASE" 2>/dev/null || true)"
  if [ -n "$RS" ]; then
    TIER=$(printf '%s\n' "$RS" | sed -n 's/^TRIFORCE_TIER=//p')
    SCORE=$(printf '%s\n' "$RS" | sed -n 's/^TRIFORCE_SCORE=//p')
    ENVELOPE=$(printf '%s\n' "$RS" | sed -n 's/^TRIFORCE_ENVELOPE=//p')
    FLOORS=$(printf '%s\n' "$RS" | sed -n 's/^TRIFORCE_FLOORS=//p')
    OVER=$(printf '%s\n' "$RS" | sed -n 's/^TRIFORCE_OVER_ENVELOPE=//p')
  fi
fi

# --- the preflight card -----------------------------------------------------
if [ "$AS_JSON" -eq 1 ]; then
  printf '{\n'
  printf '  "cli_version": "%s",\n' "$CLI_VERSION"
  printf '  "base_ref_setting": "%s",\n' "${BASEREF:-unset}"
  printf '  "tier": "%s",\n' "${TIER:-unknown}"
  printf '  "score": "%s",\n' "${SCORE:-unknown}"
  printf '  "blocking": %s,\n' "${#BLOCKING[@]}"
  printf '  "criteria_frozen": %s,\n' "$([ -f "$CRITERIA_FILE" ] && echo true || echo false)"
  printf '  "warnings": %s\n' "${#WARNINGS[@]}"
  printf '}\n'
else
  echo "┌─ triforce preflight ─────────────────────────────────────────"
  printf '│ repo      %s (%s)\n' "$(basename "$REPO_ROOT")" "$CUR_BRANCH"
  if [ -n "$TIER" ]; then
    printf '│ tier      T%s   score %s/100   envelope %s LOC\n' "$TIER" "$SCORE" "$ENVELOPE"
    case "$TIER" in
      0) printf '│ audit     SKIPPED — zero model calls at T0\n' ;;
      1) printf '│ audit     ganondorf-t1 (sonnet), K=1, cap 4 invocations\n' ;;
      2) printf '│ audit     ganondorf-t2 (opus),   K=2, cap 6 invocations\n' ;;
      3) printf '│ audit     ganondorf-t3 (fable),  K=3, cap 9 invocations\n' ;;
    esac
    [ "$FLOORS" != "none" ] && [ -n "$FLOORS" ] && printf '│ floors    %s\n' "$FLOORS"
    [ "$OVER" = "true" ] && printf '│ SEND_BACK diff exceeds the T%s envelope; split it\n' "$TIER"
  else
    printf '│ tier      unknown (no diff against %s)\n' "${BASE:0:12}"
  fi
  for n in "${NOTES[@]:-}";    do [ -n "$n" ] && printf '│ ok        %s\n' "$n"; done
  for w in "${WARNINGS[@]:-}"; do [ -n "$w" ] && printf '│ warn      %s\n' "$w"; done

  # The frozen criteria list belongs ON the card. This is what the audit will
  # be judged against, and the user should see it before any reviewer runs —
  # not discover it afterwards in a verdict. It is also the one part of the
  # card the reviewer may not renegotiate.
  if [ "${TIER:-0}" != "0" ]; then
    echo "├─ frozen criteria ────────────────────────────────────────────"
    if [ -f "$CRITERIA_FILE" ]; then
      while IFS=$'\t' read -r cid ctext; do
        [ -n "${cid:-}" ] || continue
        printf '│ %-4s %s\n' "$cid" "$ctext"
      done < "$CRITERIA_FILE"
      printf '│ hash      %s\n' "$(sha1sum < "$CRITERIA_FILE" | cut -d' ' -f1)"
    else
      printf '│ none yet — extracted from your request and confirmed before freezing\n'
      printf '│ (%s)\n' "$CRITERIA_FILE"
    fi
  fi
  echo "└──────────────────────────────────────────────────────────────"
  for b in "${BLOCKING[@]:-}"; do
    [ -n "$b" ] || continue
    echo
    echo "BLOCKING: $b"
  done
fi

# The tier is not renegotiable and neither is a blocking condition. There is no
# flag here that lowers a tier; --allow-unsafe-base only downgrades the baseRef
# check to a warning, and it is deliberately verbose about having done so.
[ "${#BLOCKING[@]}" -gt 0 ] && exit 1
exit 0
