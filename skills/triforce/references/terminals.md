# Terminals, re-entry, and seeing your own fixes

## The stopping rule

**The orchestrator contains no loop over the generator.** `audit()` returns. Re-entry is a fresh
top-level call gated on persisted ledger state.

*Termination proof:* `audit()` and `verify()` each increment a monotone integer and compare it to a
per-tier constant **before doing any work**. No path decrements any counter. No path calls itself.
`REPAIR_INVOCATIONS = 0` closes the one uncounted loop — malformed output is repaired by
**dropping**, never by re-asking. Therefore invocations per ledger key are bounded above by
`INVOCATION_CAP[tier] + GROUND_TRUTH_GRANT`.

The stopping rule cannot be derived from the reviewer's own behaviour. It is imposed from outside.

## Legal re-entry triggers — exactly three

- **E1** — the artifact changed (new commit SHA), *and* the edit touched a span other than the one
  the violation cited.
- **E2** — a test that **passed** at the recorded baseline now fails. The only syntactic
  ground-truth trigger, and the one case where re-reviewing the whole diff is correct. Costs the
  `GROUND_TRUTH_GRANT`, once per branch.
- **E3** — the user explicitly asked.

## Illegal triggers — refuse these by name

Say the refusal out loud rather than rationalising it into one of the legal three:

- reviewer residual uncertainty
- "I may have missed something"
- **the severity of what was found** — a blocker buys a *fix*, not a round. E1 then fires on the fix.
- orchestrator unease
- "the diff is complex"
- "let's be thorough"
- a PASS that feels suspicious
- any estimate of defects remaining

## Seeing the orchestrator's changes — two named modes

Both are costed at the point of choice. **Only a human may pull the second**, so the orchestrator
can never reopen its own loop.

### (i) `verify()` — default, cheap, structurally incapable of generating

Answers *"did my fixes land."* Its schema **has no findings array**:

```
{ violation_id,
  status: RESOLVED | UNRESOLVED | RELOCATION_FAILED,
  current_quote   (required, and only, when UNRESOLVED) }
```

Every token outside those shapes is discarded by the orchestrator.

- `UNRESOLVED` requires quoting text from the **current** artifact and stating how it still violates
  the criterion's verbatim wording. A verifier that cannot quote current text returns `RESOLVED`.
- `RELOCATION_FAILED` is **explicitly not `RESOLVED`.** A violation that *moved* must never be
  reported fixed.
- A violation may return `UNRESOLVED` at most twice; the third escalates to a human.

**The diff is deliberately withheld.** The verifier sees the span as it now stands, with no change
markers, so it answers "does this text still exhibit V?" rather than "is the author's clarification
adequate." A delta of an artifact edited in response to critique *is* the rebuttal.

Preconditions, both mechanical:
- `audit()` persisted the exact audited bytes and their SHA. Without this the only available delta
  is the orchestrator's self-report — the forbidden input arriving through the front door.
- Violation ids are **content-addressed**, `hash(criterion_id + normalized span)`, never a line or
  step number.

### (ii) `RE-AUDIT DELTA` — human-pulled, one capped invocation

A fresh roll-call over the **same frozen criteria**, citation scope restricted to changed spans plus
all six SAFETY rows. This is what "look at my changes" actually buys.

## The fix-introduced-defect hole — stated, not hidden

A defect the orchestrator's own fix introduces, that violates no criterion and destroys no prior
evidence quote, is **structurally invisible** to `verify()`.

It is narrowed and disclosed rather than papered over. The terminal is `PASS_FIX_DELTA_UNAUDITED`
and it carries this sentence, verbatim:

> Changes made after round 1 were checked only against the round-1 violations and the SAFETY set.
> They were not audited.

Plus one generative channel that cannot grow: `safety_delta[]`, scoped to changed bytes, restricted
to the closed SAFETY set, hard-capped at 6.

## Every terminal

| Terminal | Means |
|---|---|
| `PASS` | Roll-call complete, no surviving violations. Derived by the orchestrator; the auditor cannot emit it. |
| `PASS_FIX_DELTA_UNAUDITED` | As above, but post-round-1 changes were checked only against round-1 violations and SAFETY. Carries its disclosure sentence. |
| `SEND_BACK` | Diff exceeds the tier's LOC envelope. "Too large to audit at this tier; split it." |
| `UNREVIEWABLE` | No criteria, criteria drifted from their hash, baseline lost to a history rewrite, or the gate could not run. |
| `INSUFFICIENT_CONTEXT` | Truncation, or a majority of criteria not exercised. |
| `SPEC_CONFLICT` | A criterion's status has alternated across audits — two criteria are in tension and no amount of reviewing resolves it. |
| `SKIPPED` | T0, or `--no-audit`. **Rendered neutrally, never with PASS's affordance.** |
| `BUDGET_EXHAUSTED_OPEN` | The cap was reached with violations still open. Honest, and not a failure of the method. |

**A truncated, crashed, or timed-out reviewer can never produce `PASS`.** An honest terminal always
beats a false one.

## What is not claimed

This is not "we will tell you when the code is clean." It is **"another round is no longer worth its
cost."**

At a per-round detection probability of 0.35, reaching under 10% residual risk takes seven
consecutive clean rounds — and effective detection *declines* with each round, because surviving
defects are selected for difficulty. Roughly **29% residual risk after three clean rounds is the
floor of the method**, not a bug in it.

Accepted recall costs, named rather than assumed away: T0 forfeits real defects (~31% of sub-50-line
PRs contain findings); the confidence bar discards borderline true findings; the ring discards real
bugs outside it; dropping ambiguity as a blocking class loses a real class.

**The user remains the only thing that can buy another round.**
