---
description: Check whether the fixes you made since the last triforce audit actually landed — the cheap, non-generative mode. Pass --re-audit to buy a fresh roll-call over the same frozen criteria instead.
argument-hint: "[--re-audit]"
context: fork
---

**Seeing the orchestrator's changes.** Two named modes, both costed at the point of choice, and this
command defaults to the cheap one.

You are running in a forked context. That is deliberate: everything here is self-contained, needs no
mid-process user input, and a long verification transcript does not belong in the user's main
conversation.

Argument (may be empty): `$ARGUMENTS`

---

## Before anything: three preconditions, all mechanical

Run these in order and **stop at the first failure**. Report the terminal honestly; none of these
is a reason to improvise.

1. **A ledger must exist for this branch.**
   ```
   ledger.sh get <key> criteria_hash
   ```
   No ledger means no audit has run, so there is nothing to verify against. Report `UNREVIEWABLE`.

2. **The frozen criteria must still match their hash.** If `.triforce/criteria.tsv` hashes
   differently than the ledger records, the criteria drifted. Report `UNREVIEWABLE`.
   **Do not re-derive them, and never author replacements** — an auditee that writes its own exam
   sets its own blocking budget in both directions.

3. **Budget must remain.**
   ```
   ledger.sh can <key> verify_used      # default mode
   ledger.sh can <key> reaudits_used    # --re-audit
   ```
   Exhausted means `BUDGET_EXHAUSTED_OPEN`. It does not mean "one more". There is no flag here that
   raises a cap and you must not add one.

---

## Default mode — `verify()`

Answers **"did my fixes land."** It is structurally incapable of generating a new finding, because
its schema has no findings array.

For each open violation in the ledger:

1. Load the persisted audited bytes (`.triforce/audited/<key>.audited`) and the violation's recorded
   evidence quote. This is why `audit()` persists them — without it the only available delta is the
   orchestrator's self-report, which is precisely the input the context firewall exists to exclude.
2. Locate the span **as it now stands** and extract it as plain text.
3. Dispatch the `verifier` agent with: the violation id, the criterion id and its verbatim text, the
   original evidence quote, and that current span.

   **Withhold the diff.** The verifier answers *"does this text still exhibit V?"*, not *"is the
   author's clarification adequate."* A delta of an artifact edited in response to critique **is**
   the rebuttal.

   Send nothing you wrote in response to the audit — no explanation of what you changed, no
   reasoning, no other violations, no conversation. The invariant is **provenance, not shape**.
4. Bump `verify_used` **before** dispatching, not after.

Then act on each status, and only these three exist:

| Status | Action |
|---|---|
| `RESOLVED` | Close the violation. This is the expected, common, successful result. |
| `UNRESOLVED` | `ledger.sh unresolved-bump <key> <violation_id>`. At the third, that command exits non-zero and **a human decides** — do not dispatch a fourth check. |
| `RELOCATION_FAILED` | **Explicitly not `RESOLVED`.** A violation that moved must never be reported fixed. Escalate. |

Discard every token outside those shapes before reading the result.

---

## `--re-audit` — RE-AUDIT DELTA

> A fresh roll-call over the **same frozen criteria**, citation scope restricted to changed spans
> plus all six SAFETY rows. This is what "look at my changes" actually buys.

This is generative and it costs **one capped invocation**. Say so before running it.

- Same frozen criteria. Never recomputed, never extended, never trimmed.
- Dispatch the tier variant the ledger records — not a higher one because this round feels
  important. There is no path that raises a tier.
- Gate every returned candidate through `gate.sh`. Failures are **discarded, never demoted to a nit**.
- Dedup against `seen_keys`. **Against everything SEEN, never everything CONFIRMED** — a finding
  rejected in round 1 that reappears now is not new and must not re-enter any counter.
- If `gate.sh` cannot run, report `UNREVIEWABLE`. An ungated audit is not a PASS.

---

## Only a human pulls the second mode

`--re-audit` exists so the user can buy another round. **You may not pull it yourself**, and you may
not suggest it because a `RESOLVED` felt unconvincing or because you would like to be thorough.

Refuse these by name rather than rationalising them into a legal trigger: reviewer residual
uncertainty · "I may have missed something" · the severity of what was originally found · your own
unease · "the diff is complex" · "let's be thorough" · a clean result that feels suspicious · any
estimate of defects remaining.

Compute no statistic, display none, and let none route control flow.

---

## Reporting

State which mode ran, what it cost, and the remaining budget. List each violation with its status.

If everything came back `RESOLVED`, say so plainly and stop. **Do not add a caveat inviting another
round** — the honest claim is that another round is no longer worth its cost, not that the code is
now clean.

If any changes were made after the original audit that this run did not cover, name the terminal
`PASS_FIX_DELTA_UNAUDITED` and carry its sentence verbatim:

> Changes made after round 1 were checked only against the round-1 violations and the SAFETY set.
> They were not audited.
