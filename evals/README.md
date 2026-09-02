# Evals

Two layers, because the harness only supports the first one today.

## Layer 1 — trigger tests (runnable)

The `*.md` files here are trigger cases in the schema this CLI documents:
frontmatter `query` + `should_trigger`, body treated as notes.

```bash
claude plugin eval
```

**Availability:** `claude plugin eval` is present in the CLI binary but is **not exposed as a
subcommand at v2.1.195** — it is early-access gated, and one of its own strings reads *"Model
evaluation not yet wired up."* These files are written and correct; they run when it is enabled.

## Layer 2 — the measurement arms (specified, not yet expressible)

The issue specifies graded arms with ablation (`--ablation with-without`, `--max-cost-usd`,
`--judge-model`). The eval schema in this CLI version carries only `query` / `should_trigger`, so
those arms cannot be expressed here yet. They are recorded below with their decision rules so that
nothing has to be re-derived, and so that **no seat gets filled by an unmeasured agent**.

Two of them have bash implementations that need only an authenticated `claude -p`:
`acceptance/clean-corpus.sh` and `acceptance/probe-harness.sh`.

### Arm A — with/without ablation

Same prompts, plugin enabled vs disabled. Records the score delta: the honest measure of whether the
orchestration earns its overhead against a plain session.

*Status: not run.*

### Arm B — the clean corpus (THE HEADLINE METRIC)

20 known-clean merged diffs, size-stratified, one audit each.

- **Bar: clean-return rate ≥ 70% in the under-50-LOC band.**
- Below 50%, the criteria contract is decorative and the design has failed.

Implemented as `acceptance/clean-corpus.sh`. *Status: UNMEASURED — needs an authenticated
`claude -p`.*

### Arm C — navi's A/B

Same task set, navi enabled vs disabled, scored on total tokens, wall-clock, and correctness.

**Decision rule:** navi ships only if it wins on tokens or wall-clock **without losing on
correctness**. Otherwise the seat is cut and the roster is three agents by design rather than by
environment.

*Status: navi is **CUT**. It ships only after clearing this bar. Shipping an unmeasured fourth agent
is not an acceptable outcome, so the seat stays empty rather than provisional.*

Note this arm also needs `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH`, which is not implemented before
CLI v2.1.219.

### Arm D — the plan gate, four ways

On the same plan corpus:

1. in-context self-critique
2. fresh zelda subagent
3. fresh subagent + ganondorf
4. fresh subagent + ganondorf as a **delete-only refuter** (may delete findings, never add)

Scored on findings, TP, FP, precision, F1, and blocking-findings-acted-upon.

**Decision rule:** if (iii) does not beat (ii) on F1, the plan gate ships as (iv) or not at all.

The research points at (iv) already: *"multiple LLM models largely detect the same bugs; adding
additional models introduces false positives without meaningfully increasing true positives"*, and
the one multi-model configuration that helps is a one-directional refuter.

*Status: plan gate is **DEFERRED**; (iv) is the candidate ship configuration. Only the fresh-zelda
plan review (ii) ships today, and it is required rather than optional.*

### Arm E — gate and floor ablations

- **Gate ablation** — disable the four checks. Clean rate must collapse and blocking volume must
  multiply. This proves the *gate*, not the prompt, is load-bearing.
- **Floor ablation** — reinstate "report at least 3 findings". Clean rate must fall to ~0,
  confirming floor removal is the mechanism for Cause A.

The gate ablation has a mechanical implementation already: `gate.sh --disable`, exercised in
`acceptance/test-gate.sh`, which shows 0 survivors gated vs 4 ungated on the same candidates. That
demonstrates the filter is load-bearing **on synthetic candidates**; the model-facing version of the
arm still needs a live run.

*Status: gate ablation demonstrated mechanically; both model-facing arms not run.*

### Arm F — the falsifier

Run the seeded fixture three ways: (a) K parallel in one round, (b) the same plus one **forced**
second hunting round, (c) K sequential rounds. Report findings / TP / FP / precision / F1 for each.

**If (b) beats (a) on F1 on this corpus, the one-round premise is wrong for this workload and the
design must be revised, not defended.**

*Status: not run. The design ships with its own falsifier unfired, which is worth stating plainly.*

## Instrumentation to start on day one

Both come from the issue's own open questions, and both are numbers that will hurt if they go the
wrong way:

1. **The tier histogram.** Every cost claim for a required gate rests on the distribution being
   T0/T1-heavy. That is an assumption, not a measurement.
2. **The fraction of `## Verification` rows that actually run and pass** at the final-state audit.
   Above ~0.8 the source holds. Drifting toward 0.5 means the section is being written *for the
   auditor*, and criteria must fall back to user-authored text alone.
