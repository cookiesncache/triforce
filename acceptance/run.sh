#!/usr/bin/env bash
# run.sh — the triforce acceptance suite.
#
#   bash acceptance/run.sh
#
# Runs every case that can run without a live model, reports the rest as
# DEFERRED with a reason. A deferred case is never counted as a pass. If you
# see a green run, read the deferred list before believing it.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

SUITES=0; SUITES_OK=0
DEFERRED=()

run_suite() {
  local name="$1" script="$2"
  SUITES=$((SUITES + 1))
  echo
  echo "=============================================================="
  echo " $name"
  echo "=============================================================="
  if bash "$script"; then
    SUITES_OK=$((SUITES_OK + 1))
  fi
}

defer() { DEFERRED+=("$1"); }

echo "triforce acceptance"

# --- static checks ----------------------------------------------------------
echo
echo "=============================================================="
echo " static"
echo "=============================================================="
SPASS=0; SFAIL=0
sok()  { printf '  ok    %s\n' "$1"; SPASS=$((SPASS+1)); }
sbad() { printf '  FAIL  %s\n' "$1"; SFAIL=$((SFAIL+1)); }

# manifests
if claude plugin validate .claude-plugin/plugin.json >/dev/null 2>&1; then
  sok "plugin.json validates"; else sbad "plugin.json validates"; fi
if claude plugin validate .claude-plugin/marketplace.json >/dev/null 2>&1; then
  sok "marketplace.json validates"; else sbad "marketplace.json validates"; fi
if python -c "import json,sys;json.load(open('hooks/hooks.json'))" 2>/dev/null; then
  sok "hooks.json is valid JSON"; else sbad "hooks.json is valid JSON"; fi

# filename == frontmatter name
mism=0
for f in agents/*.md; do
  n=$(sed -n 's/^name: //p' "$f" | head -1); b=$(basename "$f" .md)
  [ "$n" = "$b" ] || { mism=1; echo "      $b != $n"; }
done
[ "$mism" -eq 0 ] && sok "every agent filename matches its frontmatter name" \
                  || sbad "every agent filename matches its frontmatter name"

# forbidden frontmatter keys — these fail SILENTLY at runtime (unknown keys are
# telemetried, not rejected), so a static check is the only place they surface.
if grep -q "allowed-tools" agents/*.md 2>/dev/null; then
  sbad "no 'allowed-tools' in agents (it is a skill/command field)"
else
  sok "no 'allowed-tools' in agents (it is a skill/command field)"
fi
if grep -qE "^effort:[[:space:]]*xhigh" agents/*.md 2>/dev/null; then
  sbad "no 'xhigh' effort in agents (enum is low|medium|high|max)"
else
  sok "no 'xhigh' effort in agents (enum is low|medium|high|max)"
fi

# model pins are ALIASES, never dated ids — dated ids do not survive a release
if grep -hE "^model:" agents/*.md | grep -qE "[0-9]{8}|-[0-9]{4}-"; then
  sbad "model pins are aliases, not dated ids"
else
  sok "model pins are aliases, not dated ids"
fi
for pin in "zelda:opus" "link:sonnet" "verifier:sonnet"            "ganondorf-t1:sonnet" "ganondorf-t2:opus" "ganondorf-t3:fable"; do
  a="${pin%%:*}"; m="${pin##*:}"
  if grep -qE "^model: $m\$" "agents/$a.md" 2>/dev/null; then
    sok "$a pinned to $m"
  else
    sbad "$a pinned to $m (got '$(sed -n 's/^model: //p' "agents/$a.md" | head -1)')"
  fi
done
if grep -hE "^model:" agents/*.md | grep -q "inherit"; then
  sbad "no agent resolves to 'inherit'"; else sok "no agent resolves to 'inherit'"; fi

# the skill entry point
if grep -q "^agent: zelda" skills/triforce/SKILL.md; then
  sok "/triforce pins zelda via agent:"; else sbad "/triforce pins zelda via agent:"; fi

# ganondorf tier variants stay in sync with the shared contract
if bash acceptance/gen-ganondorf.sh --check >/dev/null 2>&1; then
  sok "ganondorf tier variants in sync with the shared contract"
else
  sbad "ganondorf tier variants in sync with the shared contract"
fi

# ACCEPTANCE CASE 9, second half: the orchestrator contains no loop over the
# generator. A `while` around a reviewer dispatch is the failure this design
# exists to prevent, so it is checked mechanically rather than trusted.
if grep -nE '^\s*while .*(audit|ganondorf|review|Agent)' agents/zelda.md skills/triforce/SKILL.md 2>/dev/null; then
  sbad "no while-loop over the generator in the orchestrator"
else
  sok "no while-loop over the generator in the orchestrator"
fi

# no finding floor anywhere, in any tier — Cause A in one grep
if grep -rniE "at least [0-9]+ (finding|issue)|minimum of [0-9]+ finding|target of [0-9]+ finding" \
     agents/ skills/ 2>/dev/null; then
  sbad "no finding floor in any agent or reference"
else
  sok "no finding floor in any agent or reference"
fi

# verify() must be structurally incapable of generating. Its schema has no
# findings array, and the closed status enum is the whole contract.
if grep -qE '"(findings|violations)"' agents/verifier.md 2>/dev/null; then
  sbad "verifier has no findings/violations array in its schema"
else
  sok "verifier has no findings/violations array in its schema"
fi
missing=""
for st in RESOLVED UNRESOLVED RELOCATION_FAILED; do
  grep -q "$st" agents/verifier.md 2>/dev/null || missing="$missing $st"
done
[ -z "$missing" ] && sok "verifier carries all three statuses"                   || sbad "verifier is missing:$missing"
if grep -q "explicitly not \`RESOLVED\`" agents/verifier.md 2>/dev/null; then
  sok "RELOCATION_FAILED is explicitly not RESOLVED"
else
  sbad "RELOCATION_FAILED is explicitly not RESOLVED"
fi
# the verifier must not be handed the diff
if grep -q "You do not receive the diff" agents/verifier.md 2>/dev/null; then
  sok "the diff is withheld from the verifier"
else
  sbad "the diff is withheld from the verifier"
fi
# tools: [] on both non-writing agents makes the firewall a type, not a request
for a in verifier ganondorf-t1 ganondorf-t2 ganondorf-t3; do
  if grep -qE '^tools: \[\]$' "agents/$a.md" 2>/dev/null; then
    sok "$a has no file tools"
  else
    sbad "$a has no file tools"
  fi
done
# the /triforce:verify entry point forks and defaults to the cheap mode
if grep -q "^context: fork" commands/verify.md 2>/dev/null; then
  sok "verify command uses context: fork (self-contained, no user input)"
else
  sbad "verify command uses context: fork"
fi
if grep -q -- "--re-audit" commands/verify.md 2>/dev/null; then
  sok "the generative mode requires an explicit --re-audit"
else
  sbad "the generative mode requires an explicit --re-audit"
fi

# the disclosure sentence must survive verbatim
if grep -q "They were not audited." skills/triforce/references/terminals.md; then
  sok "PASS_FIX_DELTA_UNAUDITED carries its disclosure sentence verbatim"
else
  sbad "PASS_FIX_DELTA_UNAUDITED carries its disclosure sentence verbatim"
fi

echo
echo "  $SPASS passed, $SFAIL failed"
SUITES=$((SUITES + 1)); [ "$SFAIL" -eq 0 ] && SUITES_OK=$((SUITES_OK + 1))

# --- unit suites ------------------------------------------------------------
run_suite "risk score / tiering"        acceptance/test-risk-score.sh
run_suite "preflight (case 1)"          acceptance/test-preflight.sh
run_suite "invocation ledger (cases 8, 9)" acceptance/test-ledger.sh
run_suite "the four-check gate (cases 10, 14)" acceptance/test-gate.sh

# --- cases that need a live model or a newer CLI ----------------------------
defer "case 2,3,4,5,6 (isolation, base-targets-orchestrator, sole merge point, cleanup, retention) — need a live model to dispatch link. Run acceptance/probe-harness.sh when authenticated."
defer "case 7 (navi degradation, two arms) — navi is CUT pending its A/B; and CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH is not implemented on this CLI (landed in 2.1.219)."
defer "case 11 (clean-return rate, THE HEADLINE METRIC) — needs a live model. Run acceptance/clean-corpus.sh when authenticated."
defer "case 12,13 (idempotence; fix-and-re-audit rounds 1-3) — need a live model."
defer "case 15 (floor ablation) — needs a live model; the floor-free static check above is its cheap proxy, not a substitute."
defer "case 16 (effective false positives over rolling windows) — needs production audits to accumulate."
defer "case 17 (the one-round falsifier: parallel vs forced-second-round vs sequential) — needs a live model."
defer "Tier-1 'claude plugin details triforce' — needs the plugin installed, not just validated."

echo
echo "=============================================================="
echo " summary"
echo "=============================================================="
echo "  suites: $SUITES_OK/$SUITES green"
echo
echo "  DEFERRED — not run, and NOT counted as passing:"
for d in "${DEFERRED[@]}"; do
  echo "    - $d"
done
echo
if [ "$SUITES_OK" -eq "$SUITES" ]; then
  echo "  All runnable suites green. The deferred list above is the honest remainder."
  exit 0
else
  echo "  FAILURES ABOVE."
  exit 1
fi
