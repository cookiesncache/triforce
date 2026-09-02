#!/usr/bin/env bash
# Generate the three ganondorf tier variants from the single shared contract.
#
# The three agents differ ONLY in frontmatter and in the trailing Tier constants
# block. Everything between is byte-identical by construction, because it is the
# same file concatenated three times.
#
#   ./gen-ganondorf.sh          write agents/ganondorf-t{1,2,3}.md
#   ./gen-ganondorf.sh --check  regenerate into a temp dir and diff; exit 1 on drift
#
# --check is what acceptance/run.sh calls. It is the mechanism that makes hand
# edits to a generated agent file fail loudly instead of silently desynchronising
# the tiers.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTRACT="$ROOT/skills/triforce/references/audit-contract.md"

[ -f "$CONTRACT" ] || { echo "missing contract: $CONTRACT" >&2; exit 2; }

MODE="${1:-write}"
if [ "$MODE" = "--check" ]; then
  OUTDIR="$(mktemp -d)"
  trap 'rm -rf "$OUTDIR"' EXIT
else
  OUTDIR="$ROOT/agents"
  mkdir -p "$OUTDIR"
fi

# tier | model | finding cap | LOC envelope | ring label | ring definition
TIERS="
t1|sonnet|4|400|an enclosing-function|the enclosing function of a changed hunk, as delimited by the \`git diff -W\` context you were given
t2|opus|6|600|an enclosing-function|the enclosing function of a changed hunk, as delimited by the \`git diff -W\` context you were given
t3|fable|8|800|a touched-file|any line inside a file touched by this diff
"

emit_one() {
  local tier="$1" model="$2" cap="$3" loc="$4" ring_label="$5" ring_def="$6"
  local out="$OUTDIR/ganondorf-$tier.md"

  {
    printf -- '---\n'
    printf 'name: ganondorf-%s\n' "$tier"
    printf 'description: >-\n'
    printf '  Tier-%s adversarial auditor. Dispatched by zelda at the final-state gate to render\n' "${tier#t}"
    printf '  a verdict on a merged diff against a frozen criteria list — never to hunt for problems,\n'
    printf '  and never invoked directly by a user or proactively by the main thread. Selected by the\n'
    printf '  preflight risk score: tier %s covers a %s-LOC envelope with %s citation ring.\n' \
           "${tier#t}" "$loc" "$ring_label"
    printf 'model: %s\n' "$model"
    printf 'effort: medium\n'
    printf 'maxTurns: 8\n'
    printf 'tools: []\n'
    printf 'color: red\n'
    printf -- '---\n\n'

    cat "$CONTRACT"

    printf '\n<!-- TIER-BLOCK-START -->\n'
    printf '\n## Tier constants\n\n'
    printf 'You are the **tier-%s** auditor.\n\n' "${tier#t}"
    printf '```\n'
    printf 'CITATION RING   %s\n' "$ring_def"
    printf 'FINDING CAP     %s surviving violations, excluding SAFETY rows,\n' "$cap"
    printf '                which are exempt and are never dropped to fit\n'
    printf 'LOC ENVELOPE    %s changed lines. Over that, emit SEND_BACK and stop.\n' "$loc"
    printf '```\n\n'
    printf 'The finding cap is a ceiling, not a target. Reaching it means the diff was\n'
    printf 'unusually bad, not that you did the job properly. Nothing about this number\n'
    printf 'implies a floor, and there is no floor.\n'
    printf '<!-- TIER-BLOCK-END -->\n'
  } > "$out"
}

printf '%s\n' "$TIERS" | while IFS='|' read -r tier model cap loc ring_label ring_def; do
  [ -n "$tier" ] || continue
  emit_one "$tier" "$model" "$cap" "$loc" "$ring_label" "$ring_def"
done

if [ "$MODE" = "--check" ]; then
  rc=0
  for tier in t1 t2 t3; do
    if ! diff -q "$ROOT/agents/ganondorf-$tier.md" "$OUTDIR/ganondorf-$tier.md" >/dev/null 2>&1; then
      echo "DRIFT: agents/ganondorf-$tier.md differs from the generated form" >&2
      diff -u "$ROOT/agents/ganondorf-$tier.md" "$OUTDIR/ganondorf-$tier.md" | head -40 >&2 || true
      rc=1
    fi
  done
  [ $rc -eq 0 ] && echo "ganondorf tier variants in sync with the shared contract"
  exit $rc
fi

echo "wrote ganondorf-t1/t2/t3 to $OUTDIR"
