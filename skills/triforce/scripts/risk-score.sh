#!/usr/bin/env bash
# risk-score.sh — compute the triforce risk score and audit tier for a diff.
#
#   risk-score.sh <base-ref> [<head-ref>]     default head: HEAD
#
# Emits KEY=VALUE lines on stdout (shell-parseable), and a human-readable
# component breakdown on stderr when TRIFORCE_VERBOSE=1.
#
# DESIGN CONSTRAINTS, all load-bearing:
#
#   ADDITIVE, NEVER MULTIPLICATIVE.  A product zeroes out exactly the case that
#   matters most — a four-line change to an auth guard scores near zero on
#   spread, churn and fragmentation, and any multiplicative combination drives
#   the whole score to nothing. Components are summed, each capped on its own.
#
#   CATEGORICAL FLOORS RAISE ONLY.  A floor can promote a tier. Nothing can
#   demote one. There is no path in this script that lowers a tier.
#
#   UNKNOWN NEVER READS AS LOW.  Shallow history yields the neutral mid value,
#   not zero. A repo we cannot characterise is not thereby safe.
#
# Signals (9): spread, relative churn, fragmentation, interface change, danger
# domains, guard deletion, boundary/arithmetic edits, test gap, history.
#
# Relative churn is normalised by the size of the files touched. Absolute churn
# is a poor tier predictor; only churn relative to component size discriminates.

set -uo pipefail

BASE="${1:-}"
HEAD_REF="${2:-HEAD}"

if [ -z "$BASE" ]; then
  echo "usage: risk-score.sh <base-ref> [<head-ref>]" >&2
  exit 2
fi

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "risk-score: not a git repository" >&2
  exit 2
fi

for ref in "$BASE" "$HEAD_REF"; do
  if ! git rev-parse --verify --quiet "$ref^{commit}" >/dev/null; then
    echo "risk-score: cannot resolve ref: $ref" >&2
    exit 2
  fi
done

RANGE="$BASE..$HEAD_REF"

# count_matches <extended-regex> — reads stdin, always prints exactly one
# integer. `grep -c` already prints 0 on no match but exits 1, so the usual
# `|| echo 0` appends a SECOND zero and every later arithmetic test breaks.
count_matches() {
  local n
  n=$(grep -cE "$1" 2>/dev/null) || n=0
  printf '%s' "${n:-0}"
}

# --- git call 1: per-file added/deleted -------------------------------------
NUMSTAT="$(git diff --numstat "$RANGE" 2>/dev/null)"

# --- git call 2: the diff body, zero context, for content signals ------------
DIFFBODY="$(git diff -U0 "$RANGE" 2>/dev/null)"

# --- git call 3: history over the touched paths -----------------------------
# (The design note says "two git calls" for the eight diff-derived signals;
#  history is inherently a third. Kept separate and cheap.)

FILES_CHANGED=0
LINES_ADDED=0
LINES_DELETED=0
TEST_FILES=0
PROD_FILES=0
CHANGED_PATHS=""

while IFS=$'\t' read -r add del path; do
  [ -n "${path:-}" ] || continue
  # binary files report "-" for both counts
  [ "$add" = "-" ] && add=0
  [ "$del" = "-" ] && del=0
  FILES_CHANGED=$((FILES_CHANGED + 1))
  LINES_ADDED=$((LINES_ADDED + add))
  LINES_DELETED=$((LINES_DELETED + del))
  CHANGED_PATHS="$CHANGED_PATHS$path"$'\n'
  case "$path" in
    *test*|*spec*|*Test*|*Spec*|*__tests__*|*.test.*|*.spec.*)
      TEST_FILES=$((TEST_FILES + 1)) ;;
    *)
      PROD_FILES=$((PROD_FILES + 1)) ;;
  esac
done <<< "$NUMSTAT"

CHANGED_LINES=$((LINES_ADDED + LINES_DELETED))

# ---------------------------------------------------------------------------
# Content class — how many changed lines are actually executable?
#
# T0 must key on WHAT was touched, not on how much caution accumulated. A
# comment reword in a shallow repo is trivially safe; if T0 were purely
# score-based, the shallow-history neutral mid (5) plus the test gap (6) would
# hold it in T1 forever and the zero-call tier would be unreachable. Every cost
# claim for a required gate rests on the tier distribution being T0/T1-heavy,
# so an unreachable T0 is a cost bug, not a rounding error.
# ---------------------------------------------------------------------------
CODE_LINES=$(printf '%s\n' "$DIFFBODY" \
  | grep -E '^[+-]' | grep -Ev '^(\+\+\+|---)' \
  | sed -E 's/^[+-][[:space:]]*//' \
  | grep -Ev '^[[:space:]]*$' \
  | grep -Ev '^(//|#|\*|/\*|\*/|--|<!--|;;)' \
  | count_matches '.')

DOC_ONLY=true
while IFS= read -r path; do
  [ -n "$path" ] || continue
  case "$path" in
    *.md|*.markdown|*.txt|*.rst|*.adoc|docs/*|*/docs/*|LICENSE|*.license) ;;
    *) DOC_ONLY=false ;;
  esac
done <<< "$CHANGED_PATHS"

# ---------------------------------------------------------------------------
# Signal 1 — spread (how many files)                                   cap 12
# ---------------------------------------------------------------------------
if   [ "$FILES_CHANGED" -eq 0 ]; then S_SPREAD=0
elif [ "$FILES_CHANGED" -eq 1 ]; then S_SPREAD=2
elif [ "$FILES_CHANGED" -le 3 ]; then S_SPREAD=5
elif [ "$FILES_CHANGED" -le 7 ]; then S_SPREAD=9
else                                  S_SPREAD=12
fi

# ---------------------------------------------------------------------------
# Signal 2 — RELATIVE churn: changed lines / total lines of touched files
#            Absolute churn is a poor predictor; normalise by component size.
#                                                                      cap 15
# ---------------------------------------------------------------------------
TOTAL_LINES=0
while IFS= read -r path; do
  [ -n "$path" ] || continue
  if [ -f "$path" ]; then
    n=$(wc -l < "$path" 2>/dev/null | tr -d ' ')
    TOTAL_LINES=$((TOTAL_LINES + ${n:-0}))
  fi
done <<< "$CHANGED_PATHS"

if [ "$TOTAL_LINES" -le 0 ]; then
  # New files only, or files deleted outright: we cannot normalise. Neutral mid,
  # never zero — an unmeasurable ratio is not a safe ratio.
  S_CHURN=7
  CHURN_PCT="unknown"
else
  CHURN_PCT=$(( CHANGED_LINES * 100 / TOTAL_LINES ))
  if   [ "$CHURN_PCT" -lt 5  ]; then S_CHURN=3
  elif [ "$CHURN_PCT" -lt 15 ]; then S_CHURN=7
  elif [ "$CHURN_PCT" -lt 40 ]; then S_CHURN=11
  else                               S_CHURN=15
  fi
fi

# ---------------------------------------------------------------------------
# Signal 3 — fragmentation: hunks per file                             cap 10
# ---------------------------------------------------------------------------
HUNKS=$(printf '%s\n' "$DIFFBODY" | count_matches '^@@')
HUNKS=${HUNKS:-0}
if [ "$FILES_CHANGED" -gt 0 ]; then
  FRAG=$(( HUNKS * 10 / FILES_CHANGED ))   # tenths, to avoid float
else
  FRAG=0
fi
if   [ "$FRAG" -le 20 ]; then S_FRAG=2
elif [ "$FRAG" -le 40 ]; then S_FRAG=5
elif [ "$FRAG" -le 80 ]; then S_FRAG=8
else                          S_FRAG=10
fi

# ---------------------------------------------------------------------------
# Signal 4 — interface change (exported/public signature touched)       cap 12
#            CATEGORICAL FLOOR: T2
# ---------------------------------------------------------------------------
IFACE=$(printf '%s\n' "$DIFFBODY" \
  | grep -E '^[+-]' | grep -Ev '^(\+\+\+|---)' \
  | count_matches '(^[+-][[:space:]]*(export|public|pub |func |def |class |interface |type |struct |trait |protocol )|^[+-].*\b(module\.exports|__all__)\b)')
IFACE=${IFACE:-0}
if   [ "$IFACE" -eq 0 ]; then S_IFACE=0
elif [ "$IFACE" -le 2 ]; then S_IFACE=6
elif [ "$IFACE" -le 6 ]; then S_IFACE=9
else                          S_IFACE=12
fi

# ---------------------------------------------------------------------------
# Signal 5 — danger domains, by path AND by content                    cap 15
#            CATEGORICAL FLOOR: T2 for one domain, T3 for two or more
# ---------------------------------------------------------------------------
DANGER_RE='auth|authz|authn|login|session|token|password|passwd|secret|credential|crypto|cipher|encrypt|decrypt|hash|signature|payment|billing|charge|refund|invoice|migration|migrate|schema|permission|acl|role|privileg|sudo|sql|query|exec|eval|deserial|pickle|subprocess'
DANGER_HITS=$(printf '%s\n%s\n' "$CHANGED_PATHS" \
  "$(printf '%s\n' "$DIFFBODY" | grep -E '^[+-]' | grep -Ev '^(\+\+\+|---)')" \
  | tr 'A-Z' 'a-z' | count_matches "$DANGER_RE")
DANGER_DOMAINS=$(printf '%s\n%s\n' "$CHANGED_PATHS" \
  "$(printf '%s\n' "$DIFFBODY" | grep -E '^[+-]' | grep -Ev '^(\+\+\+|---)')" \
  | grep -ioE "$DANGER_RE" 2>/dev/null | tr 'A-Z' 'a-z' | sort -u | wc -l | tr -d ' ')
DANGER_DOMAINS=${DANGER_DOMAINS:-0}
if   [ "$DANGER_HITS" -eq 0 ]; then S_DANGER=0
elif [ "$DANGER_HITS" -le 3 ]; then S_DANGER=8
elif [ "$DANGER_HITS" -le 10 ]; then S_DANGER=12
else                                S_DANGER=15
fi

# ---------------------------------------------------------------------------
# Signal 6 — guard deletion (a removed check is not the same as an added one)
#                                                                      cap 14
#            CATEGORICAL FLOOR: T2
# ---------------------------------------------------------------------------
GUARD_RE='\b(if|assert|check|validate|verify|guard|throw|raise|panic|require|precondition|invariant|bounds|null|nil|None|undefined|catch|rescue|except)\b'
GUARDS_DELETED=$(printf '%s\n' "$DIFFBODY" \
  | grep -E '^-' | grep -Ev '^---' \
  | count_matches "$GUARD_RE")
GUARDS_ADDED=$(printf '%s\n' "$DIFFBODY" \
  | grep -E '^\+' | grep -Ev '^\+\+\+' \
  | count_matches "$GUARD_RE")
GUARDS_DELETED=${GUARDS_DELETED:-0}
GUARDS_ADDED=${GUARDS_ADDED:-0}
GUARD_NET=$(( GUARDS_DELETED - GUARDS_ADDED ))
if   [ "$GUARD_NET" -le 0 ]; then S_GUARD=0
elif [ "$GUARD_NET" -le 2 ]; then S_GUARD=7
elif [ "$GUARD_NET" -le 5 ]; then S_GUARD=11
else                              S_GUARD=14
fi

# ---------------------------------------------------------------------------
# Signal 7 — boundary and arithmetic edits                             cap 10
# ---------------------------------------------------------------------------
BOUND_RE='(<=|>=|!=|==|\+\+|--|\[[[:alnum:]_ +*/-]*\]|\b(len|length|size|count|index|idx|offset|limit|max|min|first|last|end|start|range|slice|substr)\b)'
BOUND_HITS=$(printf '%s\n' "$DIFFBODY" \
  | grep -E '^[+-]' | grep -Ev '^(\+\+\+|---)' \
  | count_matches "$BOUND_RE")
if   [ "$BOUND_HITS" -eq 0 ]; then S_BOUND=0
elif [ "$BOUND_HITS" -le 4 ]; then S_BOUND=4
elif [ "$BOUND_HITS" -le 15 ]; then S_BOUND=7
else                               S_BOUND=10
fi

# ---------------------------------------------------------------------------
# Signal 8 — test gap: production code moved, tests did not            cap 12
# ---------------------------------------------------------------------------
if [ "$PROD_FILES" -eq 0 ] || [ "$CODE_LINES" -eq 0 ]; then
  # No executable line moved — a missing test is not a gap.
  S_TESTGAP=0
elif [ "$TEST_FILES" -gt 0 ]; then
  S_TESTGAP=0
elif [ "$PROD_FILES" -le 2 ]; then
  S_TESTGAP=6
else
  S_TESTGAP=12
fi

# ---------------------------------------------------------------------------
# Signal 9 — history: prior reverts/hotfixes over these paths          cap 10
#            FLOORED AT NEUTRAL MID WHEN SHALLOW — unknown is not low.
# ---------------------------------------------------------------------------
DEPTH=$(git rev-list --count "$HEAD_REF" 2>/dev/null || echo 0)
DEPTH=${DEPTH:-0}
if [ "$DEPTH" -lt 20 ]; then
  S_HISTORY=5           # neutral mid — shallow history tells us nothing
  HISTORY_BASIS="shallow(depth=$DEPTH), floored to neutral mid"
else
  PATHSPEC=$(printf '%s' "$CHANGED_PATHS" | tr '\n' ' ')
  # shellcheck disable=SC2086
  FIXES=$(git log --oneline -n 200 --grep='revert\|hotfix\|regression\|rollback\|urgent fix' -i \
            "$HEAD_REF" -- $PATHSPEC 2>/dev/null | wc -l | tr -d ' ')
  FIXES=${FIXES:-0}
  if   [ "$FIXES" -eq 0 ]; then S_HISTORY=2
  elif [ "$FIXES" -le 2 ]; then S_HISTORY=6
  else                          S_HISTORY=10
  fi
  HISTORY_BASIS="depth=$DEPTH, prior fix/revert commits over these paths=$FIXES"
fi

# ---------------------------------------------------------------------------
# Sum — additive, then clamp to 100
# ---------------------------------------------------------------------------
SCORE=$(( S_SPREAD + S_CHURN + S_FRAG + S_IFACE + S_DANGER + S_GUARD + S_BOUND + S_TESTGAP + S_HISTORY ))
[ "$SCORE" -gt 100 ] && SCORE=100

# ---------------------------------------------------------------------------
# Tier — thresholds, then categorical floors. Floors RAISE ONLY.
# ---------------------------------------------------------------------------
NO_CATEGORICAL=false
if [ "$S_DANGER" -eq 0 ] && [ "$S_GUARD" -eq 0 ] && [ "$S_IFACE" -eq 0 ]; then
  NO_CATEGORICAL=true
fi

if [ "$FILES_CHANGED" -eq 0 ]; then
  TIER=0
  SCORE=0
elif [ "$NO_CATEGORICAL" = true ] && { [ "$CODE_LINES" -eq 0 ] || [ "$DOC_ONLY" = true ]; }; then
  # Comment-only, whitespace-only, or documentation-only: nothing executable moved.
  TIER=0
elif [ "$SCORE" -lt 12 ] && [ "$CHANGED_LINES" -lt 25 ] && [ "$NO_CATEGORICAL" = true ]; then
  TIER=0
elif [ "$SCORE" -lt 35 ]; then
  TIER=1
elif [ "$SCORE" -lt 60 ]; then
  TIER=2
else
  TIER=3
fi

FLOORS=""
raise_to() {
  local want="$1" why="$2"
  if [ "$TIER" -lt "$want" ]; then
    TIER="$want"
    FLOORS="$FLOORS${FLOORS:+; }$why -> T$want"
  fi
}
[ "$S_IFACE"  -gt 0 ] && raise_to 2 "interface change"
[ "$S_GUARD"  -gt 0 ] && raise_to 2 "guard deletion"
[ "$DANGER_HITS" -gt 0 ] && raise_to 2 "danger domain"
[ "$DANGER_DOMAINS" -ge 2 ] && raise_to 3 "multiple danger domains ($DANGER_DOMAINS)"

# LOC envelope per tier — over it, the auditor returns SEND_BACK rather than a
# partial review wearing a complete label.
case "$TIER" in
  0) ENVELOPE=0   ;;
  1) ENVELOPE=400 ;;
  2) ENVELOPE=600 ;;
  3) ENVELOPE=800 ;;
esac
OVER_ENVELOPE=false
if [ "$TIER" -gt 0 ] && [ "$CHANGED_LINES" -gt "$ENVELOPE" ]; then
  OVER_ENVELOPE=true
fi

cat <<EOF
TRIFORCE_TIER=$TIER
TRIFORCE_SCORE=$SCORE
TRIFORCE_FILES_CHANGED=$FILES_CHANGED
TRIFORCE_CHANGED_LINES=$CHANGED_LINES
TRIFORCE_ENVELOPE=$ENVELOPE
TRIFORCE_OVER_ENVELOPE=$OVER_ENVELOPE
TRIFORCE_FLOORS=$(printf '%s' "${FLOORS:-none}")
TRIFORCE_S_SPREAD=$S_SPREAD
TRIFORCE_S_CHURN=$S_CHURN
TRIFORCE_S_FRAG=$S_FRAG
TRIFORCE_S_IFACE=$S_IFACE
TRIFORCE_S_DANGER=$S_DANGER
TRIFORCE_S_GUARD=$S_GUARD
TRIFORCE_S_BOUND=$S_BOUND
TRIFORCE_S_TESTGAP=$S_TESTGAP
TRIFORCE_S_HISTORY=$S_HISTORY
TRIFORCE_CODE_LINES=$CODE_LINES
TRIFORCE_DOC_ONLY=$DOC_ONLY
TRIFORCE_CHURN_PCT=$CHURN_PCT
TRIFORCE_HISTORY_BASIS=$HISTORY_BASIS
EOF

if [ "${TRIFORCE_VERBOSE:-0}" = "1" ]; then
  {
    echo "  spread            $S_SPREAD/12   ($FILES_CHANGED files)"
    echo "  relative churn    $S_CHURN/15   ($CHANGED_LINES lines, ${CHURN_PCT}% of touched files)"
    echo "  fragmentation     $S_FRAG/10   ($HUNKS hunks)"
    echo "  interface change  $S_IFACE/12"
    echo "  danger domains    $S_DANGER/15   ($DANGER_HITS hits, $DANGER_DOMAINS distinct)"
    echo "  guard deletion    $S_GUARD/14   (net $GUARD_NET removed)"
    echo "  boundary/arith    $S_BOUND/10   ($BOUND_HITS hits)"
    echo "  test gap          $S_TESTGAP/12   ($PROD_FILES prod, $TEST_FILES test)"
    echo "  history           $S_HISTORY/10   ($HISTORY_BASIS)"
    echo "  ------------------------------"
    echo "  score             $SCORE/100  -> T$TIER"
    [ -n "$FLOORS" ] && echo "  floors applied    $FLOORS"
  } >&2
fi
