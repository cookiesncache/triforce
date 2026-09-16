#!/usr/bin/env bash
# ablation-corpus.sh — draw the task corpus for the with/without ablation (Arm A
# of evals/README.md), MECHANICALLY, from the django clone's own history.
#
#   bash acceptance/ablation-corpus.sh [--repo <django clone>] [--n 10] [--scan 400] [--out <dir>]
#
# The spec is section 6 of evals/2026-09-15-defensibility-review.md, quoted:
#
#   "10 django commits, 50-300 LOC, each touching >=1 non-test .py file and >=1
#    tests/ file, where the touched test module fails at <sha>^ and passes at
#    <sha> ... Draw them mechanically from git log, reject on the test criterion
#    only, record the rejected list. Task prompt = commit subject + body + the
#    NAMES of the added/changed test functions (not bodies). Hidden acceptance =
#    the commit's own test hunks applied on top of the agent's output."
#
# Mechanical means: newest first, no merges, every commit that clears the static
# filters is TRIED, and the first --n that clear the dynamic test criterion are
# the corpus. Nothing is hand-picked and nothing is skipped without a recorded
# reason. A future reader can re-run this and get the same ten from the same
# clone at the same HEAD; corpus.tsv records that HEAD.
#
# Static filters (cheap, from the diff alone):
#   LOC        50 <= added + deleted <= 300, all files, binaries excluded
#   SOURCE     touches >= 1 file matching django/**/*.py
#   TESTS      touches >= 1 file under tests/ that yields a runtests label
# Dynamic criterion (two test runs in a throwaway worktree):
#   FAILS-THEN-PASSES   the commit's tests/ hunks applied on <sha>^ -- exactly the
#                       hidden-acceptance step an arm faces, run against a no-op
#                       arm -- exit non-zero; the full commit at <sha> exits zero.
#                       (The review wrote "the touched test module fails at
#                       <sha>^"; run literally that passes for almost every fix,
#                       because the tests that exercise a fix are ADDED by it.
#                       First draw: 11 of 13 rejected that way. This is the
#                       criterion it meant.)
#
# Needs a python that can import django's deps (asgiref, sqlparse). ABL_PY names
# it; the default is the venv ablation.sh documents.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$ROOT/../django"; N=10; SCAN=400; OUT="$ROOT/acceptance/ablation/corpus"
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --n) N="$2"; shift 2 ;;
    --scan) SCAN="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    *) echo "ablation-corpus: unknown argument $1" >&2; exit 2 ;;
  esac
done
[ -d "$REPO/.git" ] || { echo "ablation-corpus: '$REPO' is not a git repository" >&2; exit 2; }
REPO="$(cd "$REPO" && pwd)"
ABL_PY="${ABL_PY:-$ROOT/acceptance/.out/ablation-venv/Scripts/python.exe}"
[ -x "$ABL_PY" ] || ABL_PY="${ABL_PY%.exe}"
"$ABL_PY" -c "import asgiref, sqlparse" 2>/dev/null || {
  echo "ablation-corpus: ABL_PY='$ABL_PY' cannot import asgiref/sqlparse. See ablation.sh." >&2; exit 2; }

mkdir -p "$OUT"
HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)
{
  echo "# drawn $(date -u +%Y-%m-%dT%H:%MZ) from $REPO at $HEAD_SHA, scan=$SCAN newest-first, no merges"
  printf 'sha\tloc\tlabels\tsubject\n'
} > "$OUT/corpus.tsv"
printf 'sha\treason\n' > "$OUT/rejected.tsv"

# labels_for <sha> -- runtests labels for the tests/ files this commit touched.
labels_for() {
  git -C "$REPO" diff --name-only "$1^" "$1" -- tests/ | "$ABL_PY" -c '
import sys, os
labels = []
for p in sys.stdin.read().split():
    parts = p.split("/")
    if len(parts) < 3 or parts[0] != "tests":
        continue                      # tests/runtests.py, tests/README.rst ...
    app = parts[1]
    if len(parts) == 3 and parts[2].endswith(".py") and parts[2].startswith("test"):
        lab = app if parts[2] == "tests.py" else app + "." + parts[2][:-3]
    else:
        lab = app                     # models.py, fixtures, deeper packages: run the app
    if lab not in labels:
        labels.append(lab)
print(" ".join(labels))
'
}

run_labels() {   # run_labels <worktree> <labels...> ; exit status of runtests
  local wt="$1"; shift
  ( cd "$wt" && PYTHONPATH="$wt" timeout 900 "$ABL_PY" tests/runtests.py --parallel 1 --noinput "$@" >"$wt/.ablation-tests.log" 2>&1 )
}

accepted=0; tried=0
WT="$(mktemp -d)/wt"
trap 'git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1; git -C "$REPO" worktree prune >/dev/null 2>&1' EXIT

for sha in $(git -C "$REPO" log --no-merges --format=%H -n "$SCAN"); do
  [ "$accepted" -lt "$N" ] || break
  short=$(git -C "$REPO" rev-parse --short "$sha")
  loc=$(git -C "$REPO" diff --numstat "$sha^" "$sha" | awk '$1!="-"{a+=$1; d+=$2} END{print a+d+0}')
  if [ "$loc" -lt 50 ] || [ "$loc" -gt 300 ]; then
    printf '%s\tLOC %s outside 50..300\n' "$short" "$loc" >> "$OUT/rejected.tsv"; continue
  fi
  files=$(git -C "$REPO" diff --name-only "$sha^" "$sha")
  if ! printf '%s\n' "$files" | grep -qE '^django/.*\.py$'; then
    printf '%s\tno django/**/*.py touched\n' "$short" >> "$OUT/rejected.tsv"; continue
  fi
  labels=$(labels_for "$sha")
  if [ -z "$labels" ]; then
    printf '%s\tno tests/ file with a runtests label\n' "$short" >> "$OUT/rejected.tsv"; continue
  fi
  tried=$((tried + 1))
  echo "trying $short  loc=$loc  labels=[$labels]"
  git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1
  git -C "$REPO" worktree add -q --detach "$WT" "$sha^" 2>/dev/null || { printf '%s\tworktree add failed\n' "$short" >> "$OUT/rejected.tsv"; continue; }
  if ! git -C "$REPO" diff "$sha^" "$sha" -- tests/ | git -C "$WT" apply --3way >/dev/null 2>&1; then
    printf '%s\ttests patch does not apply on sha^\n' "$short" >> "$OUT/rejected.tsv"; echo "  reject: tests patch will not apply"; continue
  fi
  # shellcheck disable=SC2086
  if run_labels "$WT" $labels; then
    printf '%s\ttests PASS on sha^ + tests patch (the commit'"'"'s tests do not exercise its change)\n' "$short" >> "$OUT/rejected.tsv"
    echo "  reject: new tests pass without the fix"; continue
  fi
  git -C "$WT" checkout -q -- . 2>/dev/null; git -C "$WT" clean -qfd tests 2>/dev/null
  git -C "$WT" checkout -q --detach "$sha" 2>/dev/null
  # shellcheck disable=SC2086
  if ! run_labels "$WT" $labels; then
    printf '%s\ttests FAIL at sha (not a self-contained fix in this environment)\n' "$short" >> "$OUT/rejected.tsv"
    echo "  reject: fails at sha"; continue
  fi
  accepted=$((accepted + 1))
  subject=$(git -C "$REPO" log -1 --format=%s "$sha")
  printf '%s\t%s\t%s\t%s\n' "$sha" "$loc" "$labels" "$subject" >> "$OUT/corpus.tsv"
  T="$OUT/task$(printf '%02d' "$accepted")"; mkdir -p "$T"
  echo "$sha" > "$T/sha.txt"; echo "$labels" > "$T/labels.txt"
  git -C "$REPO" diff "$sha^" "$sha" -- tests/ > "$T/tests.patch"
  git -C "$REPO" diff "$sha^" "$sha" -- . ':!tests/' > "$T/reference.patch"   # the commit's own fix; NEVER shown to an arm
  # The prompt: subject + body + the NAMES of added/changed test functions.
  {
    echo "$subject"
    echo
    git -C "$REPO" log -1 --format=%b "$sha"
    echo
    echo "Tests that must pass (names only; write them yourself under tests/):"
    grep -E '^\+\s*(async )?def test_' "$T/tests.patch" | sed -E 's/^\+\s*(async )?def (test_[A-Za-z0-9_]*).*/  - \2/' | sort -u
    echo
    echo "Test labels: $labels"
  } > "$T/task.md"
  echo "  ACCEPTED as task$(printf '%02d' "$accepted")"
done

echo
echo "accepted $accepted of $N (tried $tried against the test criterion); rejected list: $OUT/rejected.tsv"
[ "$accepted" -eq "$N" ] || { echo "ablation-corpus: only $accepted accepted; raise --scan" >&2; exit 1; }
