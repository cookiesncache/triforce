# ▲ Triforce

> An orchestrated build-and-audit workflow whose reviewer **stops**.

---

## The problem it solves

Point an adversarial code reviewer at your diff and it finds something. Fix it, ask again, and it
finds something else. Every round produces findings and they drift further off-spec each time.

That failure has two unrelated causes, and they need opposite fixes:

- **Output pressure.** The model is rewarded for producing findings and never for producing none.
  Anthropic's own `/code-review` says "return `[]`" five separate ways and still emits, because
  those five permissions compete in-prompt against one finding floor — and the floor wins.
  → **No floors here. Anywhere. In any tier.**
- **Unbounded scope.** Even a perfectly honest reviewer has an infinite admissible population,
  because *"is there anything else worth saying about this?"* has no zero. Four production reviewers
  on the same 146 PRs flagged 617 locations: **93.4% found by exactly one tool, zero by all four.**
  Greptile's own breakdown is **79% nits vs 2% factually incorrect** — the findings are mostly
  *true* and *unwanted*.
  → **No instruction bounds an unbounded set. Only a schema does.**

So ganondorf does not hunt. It **renders a verdict on a frozen, enumerated criteria list**, and a
finding that cannot name a criterion has no field in the output schema to occupy. The bound
`|blocking| ≤ |criteria|` is a theorem over an artifact the auditee did not write.

---

## The roster

| Agent | Role | Pin | Does |
|---|---|---|---|
| **zelda** | Wisdom | `opus` | Orchestrates. Plans, dispatches, merges, renders the verdict. Sole merge point. |
| **ganondorf** | Power | `sonnet` / `opus` / `fable` | Audits the merged diff against frozen criteria. Three tier variants, selected by the preflight risk score. |
| **link** | Courage | `sonnet` | Executes one task in its own worktree. Never merges. |
| **verifier** | — | `sonnet` | Answers one question — did the fix land. Its schema has no findings array, so it cannot generate. |
| ~~navi~~ | — | — | **Cut.** Did not earn its seat; see [Seats](#seats-that-are-empty-on-purpose). |

Pins are **aliases**, never dated model ids, so they survive a model release.

---

## Install

```bash
claude plugin marketplace add cookiesncache/claude-plugins
```

```bash
claude plugin install triforce@cookiesncache-marketplace
```

### Required setup — one setting, and it fails silently without it

Add to `.claude/settings.json`:

```json
{ "worktree": { "baseRef": "head" } }
```

**This is not optional.** Subagent worktrees branch from the repository's **default branch** unless
`baseRef` is `"head"`. Without it every executor quietly builds on `main` instead of the
orchestrator's work — and the run still looks completely normal. A plugin cannot write your
settings, so triforce verifies it at preflight and **refuses to start** if it is wrong.

Optionally, list any gitignored files your tests need in `.worktreeinclude`. A worktree is a fresh
checkout, so `.env` and friends are absent from it.

---

## Use

```bash
/triforce add rate limiting to the upload endpoint
```

Then, after you make fixes:

```bash
/triforce:verify
```

That is the cheap, non-generative mode — it answers *did my fixes land* and cannot produce a new
finding. `--re-audit` buys a fresh roll-call over the **same** frozen criteria and costs one capped
invocation; it is deliberately not the default, because only a human should buy another round.

| Flag | Effect |
|---|---|
| `--no-audit` | Skip the required final-state gate. Recorded in the ledger and surfaced at merge — *"11 commits: 9 audited, 2 skipped by hand."* |
| `--allow-unsafe-base` | Downgrade the `baseRef` block to a loud warning. |

---

## How it terminates

**The orchestrator contains no loop over the generator.** `audit()` returns; re-entry is a fresh
top-level call gated on persisted ledger state.

*Termination proof:* `audit()` and `verify()` each increment a monotone integer and compare it to a
per-tier constant **before doing any work**. No path decrements any counter. No path calls itself.
`REPAIR_INVOCATIONS = 0` closes the one uncounted loop — malformed output is repaired by
**dropping**, never by re-asking.

| Tier | K | Ring | Finding cap | Lifetime invocations | Pin |
|---|---|---|---|---|---|
| **T0** | 0 | — | — | **0** — zero model calls | *(none)* |
| **T1** | 1 | enclosing function | 4 | 4 | `sonnet` |
| **T2** | 2 | enclosing function | 6 | 6 | `opus` |
| **T3** | 3 | touched file | 8 | 9 | `fable` |

**Worst case is 10 model invocations for the life of a branch.**

Re-entry has exactly three legal triggers: **E1** the artifact changed, **E2** a test that passed at
baseline now fails, **E3** the user asked. Everything else is refused *by name* — including the
severity of what was found, because a blocker buys a fix, not a round.

**No statistic is computed, displayed, or allowed to route control flow.**

---

## The four-check gate

Every candidate passes all four or it does not exist. Failures are **discarded, never demoted to a
nit** — demoting guarantees the findings array is never empty, which is the reported failure.

| Check | Test |
|---|---|
| **CRITERION** | names one frozen criterion id and quotes it verbatim |
| **RING** | cited line inside the enclosing function per `git diff -W` |
| **NOVELTY** | cited line was **changed** by this diff (added lines *and* deletion loci) |
| **BEHAVIOR-DELTA** | `fix_verb` from a closed enum; cosmetic verbs fail by construction |

The gate is **a script, not a prompt paragraph** (`scripts/gate.sh`). That is deliberate: an
ablation that disables an instruction proves nothing, because the model may comply anyway. An
ablation that disables a filter proves the filter was load-bearing. On synthetic candidates it
shows **0 survivors gated vs 4 ungated**.

Ganondorf ships with `tools: []` — no file tools at all — so "never a full repo re-read" is a type,
not a request. `git diff -W` already carries the enclosing function, so it never needs to look
anything up.

---

## What this does *not* claim

It does not tell you when your code is clean. It tells you **another round is no longer worth its
cost.**

At a per-round detection probability of 0.35, reaching under 10% residual risk takes seven
consecutive clean rounds — and detection *declines* each round, because surviving defects are
selected for difficulty. **Roughly 29% residual risk after three clean rounds is the floor of the
method, not a bug in it.**

Accepted recall costs, named rather than assumed away: T0 forfeits real defects (~31% of sub-50-line
PRs contain findings); the ring discards real bugs outside it; dropping ambiguity as a blocking
class loses a real class.

---

## Status — measured, and not

Everything below is either a number or an honest blank. Nothing deferred is reported as passing.

### Verified

`bash acceptance/run.sh` — **87 checks green**:

| Suite | Checks | Covers |
|---|---|---|
| static | 29 | manifests, pins resolve as aliases (none `inherit`), no `allowed-tools` in agents, no `xhigh` effort, tier variants in sync, no while-loop over the generator, no finding floor anywhere, `tools: []` on every non-writing agent, verifier has no findings array |
| risk score | 7 | additive scoring, categorical floors, T0 content class. Includes a 4-line auth-guard removal reaching **T3** — the case a multiplicative score zeroes out |
| preflight | 10 | case 1: `baseRef` unset/`fresh` **blocks**, `CLAUDE_CODE_SUBAGENT_MODEL` blocks, version read from the binary |
| ledger | 31 | cases 8 + 9: caps hold at 4/6/9, counters monotone under every command sequence, dedup on `seen`, and `UNRESOLVED` escalating to a human on the third |
| gate | 10 | cases 10 + 14: each check kills its own candidate, severity-first ordering, ablation 0 vs 4 |

### Not measured

| | Status |
|---|---|
| **Clean-return rate** (the headline metric, bar ≥70%) | **UNMEASURED.** `acceptance/clean-corpus.sh` is written and gated on auth. |
| Tier-2 cases 2–6 (isolation, base-targets-orchestrator, cleanup, retention) | **UNMEASURED.** `acceptance/probe-harness.sh`, gated on auth. |
| navi A/B, plan-gate four-arm A/B, floor ablation, the one-round falsifier | **NOT RUN.** See [`evals/README.md`](evals/README.md). |
| with/without ablation delta | **NOT RECORDED.** |

The blocker is environmental: `claude -p` reports "Not logged in" in the build environment, and
`claude plugin eval` is early-access gated at CLI v2.1.195. Every harness is written and runs on an
authenticated machine.

### Seats that are empty on purpose

- **navi is cut.** The premise was that routing boilerplate to the cheapest model saves money.
  Against it: fixed spawn overhead can exceed the work; the handoff cost lands on the *expensive*
  side; a wrong boilerplate edit costs a Sonnet correction round; and it does not exist on the web
  anyway, where nesting is off by platform policy. It ships only if an A/B shows it wins on tokens
  or wall-clock **without losing correctness**. Shipping an unmeasured fourth agent is not an
  acceptable outcome.
- **The plan gate is deferred.** Once zelda's plan review is a fresh subagent, ganondorf-at-plan-time
  is that same reviewer minus the model pin. The candidate ship configuration is the **delete-only
  refuter** — the one multi-model arrangement the research supports. Until its A/B runs, only the
  fresh-zelda plan review ships, and it is required rather than optional.

---

## Two things that will bite you

**`CLAUDE_CODE_SUBAGENT_MODEL` outranks frontmatter.** If it is set, every pin here is overridden and
the entire cost design is void. Preflight blocks on it.

**`CLAUDE_CODE_VERSION` can be malformed.** It has been observed reporting `2.1.42` in an environment
demonstrably newer. Preflight reads `claude --version` from the binary instead, and says so.

---

## Layout

```
agents/          zelda, link, verifier, ganondorf-t1/t2/t3
commands/        verify.md  (context: fork — the E3 "user explicitly asked" path)
skills/triforce/ SKILL.md, references/, scripts/
  scripts/       preflight, risk-score, ledger, gate   (pure bash + git)
hooks/           Stop hook: the audit ran, or a waiver is recorded
acceptance/      run.sh (offline) + probe-harness.sh, clean-corpus.sh (live)
evals/           trigger cases + the measurement arms, specified
```

The three ganondorf variants are **generated** from one shared contract
(`acceptance/gen-ganondorf.sh`); `--check` re-derives them and fails on any hand edit, so the tiers
cannot drift.

---

## Licence

CC BY-NC 4.0. See [LICENSE](LICENSE).
