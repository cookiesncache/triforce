# The invocation ledger

The budget is **per-branch invocations**, not dollars and not turns.

`--max-cost-usd` is the wrong lever for the user-facing path: Anthropic's own costs guidance says
the session dollar figure is meaningless to Max and Pro subscribers, whose usage is included in the
subscription. It is kept for the eval suite only, where it is a dev-time guard on a batch run.

`maxTurns` is also the wrong unit. A turn cap bounds how long **one** reviewer talks; it does not
bound how many reviewers get spawned, which is the thing that actually ran away.

## Constants

```
INVOCATION_CAP     = {T0: 0, T1: 4, T2: 6, T3: 9}
HUNT_K             = {T1: 1, T2: 2, T3: 3}
REAUDIT_MAX        = 1        # additional hunt rounds, all tiers
VERIFY_MAX         = {T1: 2, T2: 2, T3: 3}
GROUND_TRUTH_GRANT = 1        # once per branch, test-regression only
REPAIR_INVOCATIONS = 0        # malformed output is repaired by DROPPING, never by re-asking
```

The lifetime figure is exactly `HUNT_K + (REAUDIT_MAX x K) + VERIFY_MAX`:

| Tier | K | reaudit | verify | lifetime | finding cap | ring | model |
|---|---|---|---|---|---|---|---|
| T0 | 0 | — | — | **0** | — | — | *(none — zero model calls)* |
| T1 | 1 | 1 | 2 | **4** | 4 | enclosing function | `sonnet` |
| T2 | 2 | 2 | 2 | **6** | 6 | enclosing function | `opus` |
| T3 | 3 | 3 | 3 | **9** | 8 | touched file | `fable` |

Note the two caps are different quantities. **Lifetime invocations** bound how many reviewers may
be spawned for this branch. The **finding cap** bounds how many surviving violations one audit may
report, and the six SAFETY criteria are exempt from it.

**Worst case is 10 model invocations for the life of a branch** (T3's 9, plus the ground-truth
grant).

## Scope caps

A LOC envelope per tier: 400 / 600 / 800. A diff over its envelope returns **`SEND_BACK`** — "too
large to audit at this tier; split it" — rather than a partial review wearing a complete label.

## The ledger file

`.triforce/ledger/<key>.json`, gitignored. Key is
`sha1(merge_base | audited_tree_at_first_audit | criteria_hash)`.

```json
{
  "key": "...",
  "tier": 2,
  "audited_sha": "...",
  "criteria_hash": "...",
  "invocations_used": 0,
  "reaudits_used": 0,
  "verify_used": 0,
  "grant_used": 0,
  "seen_keys": [],
  "waived": []
}
```

All four counters are **monotone**. `ledger.sh` refuses any write that would decrease one: it exits
non-zero and changes nothing on disk. This is enforced, not assumed, and it is half of acceptance
case 9.

Changing the criteria changes the key, which starts a new budget. That is correct — it is a
different audit — and it is the only legitimate reset.

## Content-addressed violation ids

```
violation_id = sha1(criterion_id + "|" + normalized_span)
```

Never a line number, never a step number. A violation that **moves** must still be recognised as
the same violation; keying on position would make every fix look like a new finding.

The auditor does not assign these. The orchestrator does.

## Dedup against everything SEEN, never everything CONFIRMED

A finding rejected in round 1 that reappears in round 3 **is not new** and must not re-enter any
counter.

Keying on `confirmed` instead is the specific mistake that makes a loop never converge — it is the
load-bearing comment on Anthropic's own `loop-until-dry` pattern:

> `// dedup vs seen, NOT confirmed — else judge-rejected findings reappear every round and it never converges.`

And note that loop-until-dry still would not work here, for a reason dedup cannot fix: fabricated
findings are **novel by construction**, so the fresh-set never empties and the dry counter never
increments. The pattern converges when the generator's output space is bounded — enumerating real
bugs — not when a critic under output pressure has an unbounded one.

## Persisting the audited bytes

`audit()` stores the exact bytes it reviewed, plus their SHA, under `.triforce/audited/<key>.audited`.

Without this, the only delta available at round 2 is the orchestrator's self-report — precisely the
input the context firewall exists to exclude, arriving through the front door.

## No statistics

No estimator is computed, displayed, or allowed to route control flow.

Coverage deficit is `f1/n`, and every off-spec tangent increments **both**, driving the ratio *up* —
the complaint restated as arithmetic. Chao1 at two observers is degenerate: a realistic case gives
~2 unseen findings with a 95% CI of [0.29, 13.97], a ~48x ratio, and `f2 = 0` is the modal case on
narrow diffs, where the standard fallback estimates +21 unseen. Printing that to a user who just
received a clean round is the worst possible failure for a tool whose job is to stop nagging.

LLM reviewer errors correlate at about phi = 0.39, which caps effective sample size near 2.5 for any
realistic panel, while the inspection literature needs four or more effectively-independent
observers before any such model is accurate.

So: no number. Not even a caveated one.
