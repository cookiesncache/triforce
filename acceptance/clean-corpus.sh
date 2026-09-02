#!/usr/bin/env bash
# clean-corpus.sh — ACCEPTANCE CASE 11, the headline metric.
#
#   bash acceptance/clean-corpus.sh [--repo <path>] [--n 20]
#
# 20 known-clean merged diffs, size-stratified, one audit each.
#
#   PASS BAR: verdict == PASS and |blocking| == 0 for at least 70% in the
#             under-50-LOC band.
#
#   BELOW 50% THE WHOLE CRITERIA CONTRACT IS DECORATIVE AND THE DESIGN HAS
#   FAILED. That is the issue's own words, and this script exists to produce
#   the number rather than assume it.
#
# "Known clean" here means "merged into the default branch and not subsequently
# reverted". That is a proxy, and a generous one — merged code contains real
# defects. It is the right proxy anyway: the question is not whether the code is
# perfect, it is whether an auditor handed ordinary accepted work can bring
# itself to say nothing.
#
# Requires an authenticated `claude -p`.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORPUS_REPO="$ROOT"
N=20

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) CORPUS_REPO="$2"; shift 2 ;;
    --n)    N="$2"; shift 2 ;;
    *) echo "clean-corpus: unknown argument $1" >&2; exit 2 ;;
  esac
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "clean-corpus — acceptance case 11"
echo "  corpus: $CORPUS_REPO   n=$N"
echo

probe=$(timeout 90 claude -p "Reply with exactly: READY" --model haiku 2>&1)
if ! printf '%s' "$probe" | grep -q "READY"; then
  echo "  CANNOT RUN: headless claude is not usable here."
  echo "  got: $(printf '%s' "$probe" | head -2)"
  echo "  Reporting UNMEASURED, not passing."
  exit 2
fi

cd "$CORPUS_REPO" || exit 1

# --- gather commits, excluding anything that was later reverted -------------
mapfile -t ALL < <(git log --no-merges --format=%H -n 400 2>/dev/null)
REVERTED=$(git log --format=%s -n 400 2>/dev/null | grep -oiE 'revert "?[^"]*' || true)

SMALL=(); MED=(); LARGE=()
for sha in "${ALL[@]}"; do
  subj=$(git log -1 --format=%s "$sha")
  case "$subj" in Revert*|revert*) continue ;; esac
  printf '%s' "$REVERTED" | grep -qF "$subj" && continue
  loc=$(git show --numstat --format= "$sha" 2>/dev/null \
        | awk '{a+=$1; d+=$2} END {print a+d+0}')
  [ -z "$loc" ] && continue
  if   [ "$loc" -lt 50  ]; then SMALL+=("$sha:$loc")
  elif [ "$loc" -lt 200 ]; then MED+=("$sha:$loc")
  else                          LARGE+=("$sha:$loc")
  fi
done

# Size-stratified: the under-50-LOC band is the one the bar is stated for, so
# it gets the largest share.
take() { local -n arr=$1; local k=$2; printf '%s\n' "${arr[@]:0:$k}"; }
SEL=()
mapfile -t s1 < <(take SMALL $(( N / 2 )))
mapfile -t s2 < <(take MED   $(( N / 4 )))
mapfile -t s3 < <(take LARGE $(( N - N/2 - N/4 )))
SEL=("${s1[@]}" "${s2[@]}" "${s3[@]}")

echo "  selected: ${#s1[@]} small (<50 LOC), ${#s2[@]} medium, ${#s3[@]} large"
echo

SMALL_TOTAL=0; SMALL_CLEAN=0
ALL_TOTAL=0;   ALL_CLEAN=0

printf '  %-10s %-6s %-6s %-8s %s\n' SHA LOC TIER VERDICT BLOCKING
printf '  %s\n' "---------------------------------------------------------"

for entry in "${SEL[@]}"; do
  [ -n "$entry" ] || continue
  sha="${entry%%:*}"; loc="${entry##*:}"

  tierout=$(bash "$ROOT/skills/triforce/scripts/risk-score.sh" "$sha~1" "$sha" 2>/dev/null)
  tier=$(printf '%s\n' "$tierout" | sed -n 's/^TRIFORCE_TIER=//p')
  [ -z "$tier" ] && tier=1

  git diff -W "$sha~1..$sha" > "$WORK/diff.txt" 2>/dev/null

  # T0 does not run an audit at all; a SKIPPED terminal is not a PASS and must
  # not be counted as one in either direction.
  if [ "$tier" = "0" ]; then
    printf '  %-10s %-6s %-6s %-8s %s\n' "${sha:0:8}" "$loc" "T$tier" "SKIPPED" "-"
    continue
  fi

  # Criteria for a corpus commit: the SAFETY set plus one coverage criterion
  # taken verbatim from the commit's own subject line. The subject is authored
  # by the committer, not by the auditee, which keeps the criteria exogenous.
  subj=$(git log -1 --format=%s "$sha" | tr -d '\t')
  {
    printf 'C1\t%s\n' "$subj"
    printf 'S1\tincorrect output or silently wrong result\n'
    printf 'S2\tdata loss or irreversible destruction\n'
    printf 'S3\tsecurity exposure\n'
    printf 'S4\tfailed or impossible rollback\n'
    printf 'S5\tunbounded resource consumption\n'
    printf 'S6\tconcurrency or ordering hazard\n'
  } > "$WORK/criteria.tsv"

  agent="ganondorf-t$tier"
  prompt="You are $agent. Audit the diff below against the frozen criteria. Emit the criteria roll-call table first, then a JSON array of surviving violations between the markers <<<VIOLATIONS and VIOLATIONS>>>. If nothing survives your gate, emit an empty array.

FROZEN CRITERIA:
$(cat "$WORK/criteria.tsv")

MERGED DIFF (git diff -W):
$(cat "$WORK/diff.txt")"

  raw=$(printf '%s' "$prompt" | timeout 600 claude -p --plugin-dir "$ROOT" \
          --agent "$agent" --allowedTools "" 2>/dev/null)

  printf '%s' "$raw" | sed -n 's/.*<<<VIOLATIONS//p' | sed 's/VIOLATIONS>>>.*//' \
    > "$WORK/viol.json" 2>/dev/null
  grep -q '[^[:space:]]' "$WORK/viol.json" 2>/dev/null || echo '[]' > "$WORK/viol.json"

  gated=$(bash "$ROOT/skills/triforce/scripts/gate.sh" \
            --criteria "$WORK/criteria.tsv" --diff "$WORK/diff.txt" \
            --violations "$WORK/viol.json" --tier "$tier" 2>/dev/null)
  rc=$?

  if [ $rc -ne 0 ]; then
    verdict="UNREVIEWABLE"; nblock="-"
  else
    nblock=$(printf '%s' "$gated" | grep -c '"criterion_id"' || true)
    if [ "${nblock:-0}" -eq 0 ]; then verdict="PASS"; else verdict="FINDINGS"; fi
  fi

  printf '  %-10s %-6s %-6s %-8s %s\n' "${sha:0:8}" "$loc" "T$tier" "$verdict" "$nblock"

  ALL_TOTAL=$((ALL_TOTAL + 1))
  [ "$verdict" = "PASS" ] && ALL_CLEAN=$((ALL_CLEAN + 1))
  if [ "$loc" -lt 50 ]; then
    SMALL_TOTAL=$((SMALL_TOTAL + 1))
    [ "$verdict" = "PASS" ] && SMALL_CLEAN=$((SMALL_CLEAN + 1))
  fi
done

echo
pct() { [ "$2" -eq 0 ] && { echo "n/a"; return; }; echo "$(( $1 * 100 / $2 ))%"; }

echo "  clean-return rate, under-50-LOC band : $SMALL_CLEAN/$SMALL_TOTAL  ($(pct $SMALL_CLEAN $SMALL_TOTAL))"
echo "  clean-return rate, all audited bands : $ALL_CLEAN/$ALL_TOTAL  ($(pct $ALL_CLEAN $ALL_TOTAL))"
echo

if [ "$SMALL_TOTAL" -eq 0 ]; then
  echo "  UNMEASURED — no commits landed in the under-50-LOC band."
  exit 2
fi
RATE=$(( SMALL_CLEAN * 100 / SMALL_TOTAL ))
if   [ "$RATE" -ge 70 ]; then echo "  PASS — at or above the 70% bar."; exit 0
elif [ "$RATE" -ge 50 ]; then echo "  BELOW BAR — above 50%, so the contract works but needs tuning."; exit 1
else echo "  DESIGN FAILURE — below 50%. The criteria contract is decorative."; exit 1
fi
