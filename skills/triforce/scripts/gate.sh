#!/usr/bin/env bash
# gate.sh — the four gate checks, enforced mechanically, orchestrator-side.
#
#   gate.sh --criteria <file> --diff <file> --violations <file> [--tier N]
#
# CRITERION       names one frozen criterion id and quotes it verbatim
# RING            cited line inside the enclosing function (T1/T2) or the
#                 touched file (T3), per the `git diff -W` it was given
# NOVELTY         cited line was introduced by this diff
# BEHAVIOR-DELTA  fix_verb comes from the closed enum
#
# Failures are DISCARDED, never demoted. A discarded candidate leaves no trace
# in the surviving output — that is the whole point. It is reported on stderr
# for the ablation, not in the artifact.
#
# Why this is a script and not a prompt paragraph: an ablation that disables an
# instruction proves nothing, because the model may comply anyway. An ablation
# that disables a filter proves the filter was load-bearing. Acceptance case 14
# depends on this being mechanical.
#
# Criteria file format: one per line, "<id><TAB><verbatim text>".
# Violations file: the JSON array ganondorf emitted.
#
# Exit codes: 0 gate ran; 2 could not run (caller must report UNREVIEWABLE,
# never PASS — a gate that did not run is not a clean result).

set -uo pipefail

CRITERIA="" ; DIFF="" ; VIOLATIONS="" ; TIER=2 ; DISABLE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --criteria)   CRITERIA="$2"; shift 2 ;;
    --diff)       DIFF="$2"; shift 2 ;;
    --violations) VIOLATIONS="$2"; shift 2 ;;
    --tier)       TIER="$2"; shift 2 ;;
    --disable)    DISABLE=1; shift ;;   # ablation arm only (acceptance case 14)
    *) echo "gate: unknown argument $1" >&2; exit 2 ;;
  esac
done

for f in "$CRITERIA" "$DIFF" "$VIOLATIONS"; do
  [ -n "$f" ] && [ -f "$f" ] || { echo "gate: missing required file argument" >&2; exit 2; }
done

# Find an interpreter that actually RUNS. On Windows `python3` is often a Store
# alias stub that exists on PATH and fails on execution; picking it by presence
# alone makes the gate crash and emit zero survivors, which is indistinguishable
# from a clean audit. Probe, never assume.
PY=""
for cand in python python3 py; do
  if command -v "$cand" >/dev/null 2>&1 && "$cand" -c "print(1)" >/dev/null 2>&1; then
    PY="$cand"; break
  fi
done
if [ -z "$PY" ]; then
  echo "gate: no working python interpreter; the four checks cannot run" >&2
  echo "gate: caller must report UNREVIEWABLE — an ungated audit is not a PASS" >&2
  exit 2
fi

TRIFORCE_GATE_DISABLE="$DISABLE" TRIFORCE_TIER="$TIER" \
"$PY" - "$CRITERIA" "$DIFF" "$VIOLATIONS" <<'PYEOF'
import json, os, re, sys

criteria_path, diff_path, viol_path = sys.argv[1:4]
tier = int(os.environ.get("TRIFORCE_TIER", "2"))
disabled = os.environ.get("TRIFORCE_GATE_DISABLE", "0") == "1"

FIX_VERBS = {
    "add-guard", "correct-operator", "correct-bound", "fix-order",
    "release-resource", "propagate-error", "remove-write", "restore-invariant",
}
SAFETY = {"S1", "S2", "S3", "S4", "S5", "S6"}
FINDING_CAP = {0: 0, 1: 4, 2: 6, 3: 8}
SEVERITY_ORDER = {"blocking": 0, "major": 1, "minor": 2}


def norm(s):
    return re.sub(r"\s+", " ", (s or "")).strip()


# --- frozen criteria --------------------------------------------------------
criteria = {}
with open(criteria_path, encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line.strip():
            continue
        if "\t" in line:
            cid, text = line.split("\t", 1)
        else:
            parts = line.split(None, 1)
            if len(parts) != 2:
                continue
            cid, text = parts
        criteria[cid.strip()] = text.strip()

# --- the diff: added lines, and per-file -W spans ---------------------------
# `changed` is the NOVELTY admissible set: new-file line numbers this diff
# actually altered. It is added lines UNION deletion loci.
#
# Added lines alone would be wrong. A pure deletion — removing a guard, dropping
# an error branch — introduces no new line, so a strict added-lines rule makes
# every deletion defect structurally uncitable. That is the same class the risk
# scorer treats as a categorical T2 floor, so the two would contradict each
# other. The intent of NOVELTY is "do not flag pre-existing code the diff never
# touched", and a deletion is something the diff did.
changed = {}      # file -> set of new-file line numbers altered by this diff
spans = {}        # file -> list of (start, end) hunk spans in new-file coords
touched = set()

cur = None
newline_no = 0
with open(diff_path, encoding="utf-8", errors="replace") as fh:
    for line in fh:
        if line.startswith("+++ "):
            p = line[4:].strip()
            if p.startswith("b/"):
                p = p[2:]
            cur = None if p == "/dev/null" else p
            if cur:
                touched.add(cur)
                changed.setdefault(cur, set())
                spans.setdefault(cur, [])
            continue
        m = re.match(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@", line)
        if m and cur:
            start = int(m.group(1))
            length = int(m.group(2) or "1")
            # `git diff -W` widens the hunk to the enclosing function, so the
            # hunk span IS the ring. No separate function parsing is needed.
            spans[cur].append((start, start + max(length, 1) - 1))
            newline_no = start
            continue
        if cur is None:
            continue
        if line.startswith("+") and not line.startswith("+++"):
            changed[cur].add(newline_no)
            newline_no += 1
        elif line.startswith("-") and not line.startswith("---"):
            # A removed line consumes no new-file number, but the position it
            # vacated is a locus this diff altered, so it stays citable.
            changed[cur].add(newline_no)
            changed[cur].add(max(newline_no - 1, 1))
        else:
            newline_no += 1

# --- candidates -------------------------------------------------------------
try:
    with open(viol_path, encoding="utf-8") as fh:
        raw = fh.read().strip()
    candidates = json.loads(raw) if raw else []
    if isinstance(candidates, dict):
        candidates = candidates.get("violations", [])
except Exception as exc:                                  # noqa: BLE001
    print(f"gate: violations file is not parseable JSON: {exc}", file=sys.stderr)
    print("gate: caller must report UNREVIEWABLE", file=sys.stderr)
    sys.exit(2)

survivors, discarded = [], []


def drop(cand, check, why):
    discarded.append({"check": check, "why": why,
                      "criterion_id": cand.get("criterion_id"),
                      "summary": cand.get("short_summary") or cand.get("summary")})


for cand in candidates:
    if not isinstance(cand, dict):
        discarded.append({"check": "SHAPE", "why": "not an object"})
        continue

    if disabled:                       # ablation arm: keep everything
        survivors.append(cand)
        continue

    cid = (cand.get("criterion_id") or "").strip()
    quote = cand.get("criterion_quote")
    f = cand.get("file")
    line_no = cand.get("line")
    verb = (cand.get("fix_verb") or "").strip()

    # 1. CRITERION -----------------------------------------------------------
    if cid not in criteria:
        drop(cand, "CRITERION", f"unknown criterion id {cid!r}")
        continue
    if norm(quote) != norm(criteria[cid]):
        drop(cand, "CRITERION", f"quote for {cid} is not verbatim")
        continue

    # 4. BEHAVIOR-DELTA ------------------------------------------------------
    if verb not in FIX_VERBS:
        drop(cand, "BEHAVIOR-DELTA", f"fix_verb {verb!r} not in the closed enum")
        continue

    # 2/3 need a citation ----------------------------------------------------
    try:
        line_no = int(line_no)
    except (TypeError, ValueError):
        drop(cand, "RING", "no usable line number")
        continue
    if not f or f not in touched:
        drop(cand, "RING", f"file {f!r} is not touched by this diff")
        continue

    # 2. RING ----------------------------------------------------------------
    if tier >= 3:
        in_ring = True                                    # touched file
    else:
        in_ring = any(a <= line_no <= b for a, b in spans.get(f, []))
    if not in_ring:
        drop(cand, "RING", f"{f}:{line_no} outside the enclosing-function ring")
        continue

    # 3. NOVELTY -------------------------------------------------------------
    if line_no not in changed.get(f, set()):
        drop(cand, "NOVELTY", f"{f}:{line_no} was not changed by this diff")
        continue

    survivors.append(cand)

# --- severity ordering, then the cap (SAFETY is exempt) ---------------------
survivors.sort(key=lambda c: (SEVERITY_ORDER.get((c.get("severity") or "minor").lower(), 3),
                              c.get("file") or "", c.get("line") or 0))

cap = FINDING_CAP.get(tier, 6)
safety = [c for c in survivors if (c.get("criterion_id") or "") in SAFETY]
other = [c for c in survivors if (c.get("criterion_id") or "") not in SAFETY]
kept = safety + other[:cap]
for c in other[cap:]:
    discarded.append({"check": "CAP", "why": f"beyond finding cap {cap}",
                      "criterion_id": c.get("criterion_id")})

json.dump(kept, sys.stdout, indent=2)
sys.stdout.write("\n")

print(f"gate: {len(candidates)} candidates -> {len(kept)} survivors "
      f"({len(discarded)} discarded){' [GATE DISABLED]' if disabled else ''}",
      file=sys.stderr)
for d in discarded:
    print(f"  discarded [{d['check']}] {d.get('criterion_id')}: {d['why']}"
          if "why" in d else f"  discarded [{d['check']}]", file=sys.stderr)
PYEOF
