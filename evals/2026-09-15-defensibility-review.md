# Adversarial review: is triforce production-defensible against a single high-effort Opus session?

> **Provenance.** Written 2026-09-15 by an independent Fable 5.1 subagent, spawned at the author's
> request with a read-only brief: assess whether the recorded evidence makes triforce defensible to
> ship INSTEAD of a single Opus agent at high effort that plans and executes with no separate
> executor, no isolated worktree, no fresh plan reviewer and no audit gate. It ran `run.sh` once and
> no live model call. The text below is its report, unedited. Three of its sharpest specific
> claims were verified by the main session afterwards and were correct: the README suite table
> summed to 224 under a headline of 255 (fixed, now checked row by row); `gate.sh` keeps
> `safety + other[:cap]` with no per-criterion dedup, so "`|blocking| ≤ |criteria|` is a theorem"
> was false as implemented (README and criteria.md corrected to the bound that holds); and
> violation ids hash the cited TEXT, so the C1 span move seen in case 12 trial 3 would be a new id
> in production. The Stop hook is prompt-type on matcher `*`. Its verdict stands as the
> measurement phase's closing assessment; see HANDOFF.

Scope respected: read-only; no live model calls; no `live-cases.sh`. I ran `bash acceptance/run.sh` once: **255 checks, 5/5 suites, exit 0**, working tree clean afterwards. I also fetched the external spec the README defers its measurements to (`cookiesncache/claude-plugins#1`).

Two housekeeping findings from that run before the substance:
- README.md:177-183's per-suite table (166/7/10/31/10) sums to 224, not 255. The live suite printed 179/7/10/49/10 = 255. The headline is right; the table is stale.
- The suite's own final block lists cases 12, 13, 15, 16, 17(d), 17(e) as "deferred/needs a live model", i.e. the offline suite green-lights nothing about reviewer behaviour. It verifies scripts and prompt text.

---

## 1. The claims

Every distinct benefit the shipped material claims over a plain session, with where it is claimed:

| # | Claim | Where |
|---|---|---|
| K1 | The reviewer **stops**: bounded, monotone invocation ledger; no loop over the generator; "worst case 10 model invocations for the life of a branch" | README.md:3, :96-119; ledger.md:1-37; terminals.md:3-14 |
| K2 | The reviewer **returns clean on clean code** because there is no finding floor (Cause A) | README.md:14-17, :193; audit-contract.md:142-150 |
| K3 | A **frozen, user-sourced criteria list + schema** bounds the finding population: "`|blocking| ≤ |criteria|` is a theorem" (Cause B) | README.md:23-27; criteria.md:3-5 |
| K4 | The **four-check gate is load-bearing** as a script ("0 survivors gated vs 4 ungated") | README.md:123-138; gate.sh |
| K5 | **One audit round is enough**; extra thoroughness is bought with K parallel reviewers, never another round | zelda.md:98; README.md:197; evals/README.md:93-101 |
| K6 | **Idempotence**: re-auditing an unchanged diff yields no new blocking findings | issue #1 case 15; HANDOFF.md:2092-2095 |
| K7 | **Fix-and-re-audit does not drift** onto new criteria | issue #1 case 16; HANDOFF.md:2089-2091 |
| K8 | **Isolation**: every executor in its own worktree, based on the orchestrator's HEAD; the user's checkout is never written; sole merge point; cleanup on success, retention on failure | zelda.md:69-76, :125-133; dispatch.md:3-11; README.md:194-195 |
| K9 | A **fresh zelda plan review** beats in-context self-critique (F1 24.6% vs 28.6%, p=0.008; re-review as round 2 is worst, F1 0.263, d=−0.97) | zelda.md:64-65 |
| K10 | A **Sonnet executor** is adequate and cheaper; failures escalate one tier reactively | README.md:37; link.md:7; zelda.md:88; link.md:64 ("a measured cost of this pin") |
| K11 | **Context firewall**: `tools: []` on ganondorf/verifier; no rebuttals or prior findings reach a reviewer; "claim, gate, then narrate" avoids a measured 2-3× wrongful-rejection multiplier | README.md:140-142; audit-contract.md:14-18, :39-41 |
| K12 | **`verify()` is structurally incapable of generating a finding** (schema has no findings array) | verifier.md:14-17; terminals.md:43-56 |
| K13 | **Tiering keeps cost low**: T0 = zero model calls; additive risk score; tiers are not renegotiable | README.md:106-113; preflight.md:1-61 |
| K14 | The **Stop hook** guarantees an audit ran or a waiver was recorded ("required but never blocking") | hooks/hooks.json; plugin.json |
| K15 | **Honest terminals**: a truncated/crashed reviewer can never produce PASS (INVARIANT 10) | terminals.md:103-104; HANDOFF.md:2024 |
| K16 | **Residual-risk honesty**: "another round is no longer worth its cost", not "the code is clean" (0.35 per-round detection; ~29% residual after three clean rounds) | zelda.md:139; terminals.md:106-114 |

---

## 2. Evidence per claim, graded

Grades: **MAB** = measured against the baseline; **MIO** = measured internally only (triforce vs a triforce variant or a property test); **MG** = mechanically guaranteed by a script, offline-tested; **AO** = asserted only.

**K1 — termination.** `test-ledger.sh` (49 checks, seen in the run) verifies caps 4/6/9, monotone counters, dedup on `seen`, UNRESOLVED escalation; `run.sh` greps zelda.md for a `while` over the generator (run.sh:124-126). **MG for the arithmetic.** Two gaps: (a) the ledger is enforced only if zelda *calls* `ledger.sh can` before dispatching — that is a prompt instruction (zelda.md:97), not a runtime hook, and no recorded run shows zelda doing it; (b) the "10 invocations" bound (README.md:113) counts only ganondorf + verifier. It excludes zelda, the fresh plan reviewer, link, and the Stop hook, which is where most of the cost lives. Against the baseline this claim is not a benefit at all: a plain session has no review loop to bound. **Comparator is "a reviewer that never stops", not the baseline.**

**K2 — clean on clean code.** Case 11: 2026-09-02, 11/12 (91%) in the <50-LOC band, 30/32 all bands, on django commits (HANDOFF.md:35-70); re-measured 2026-09-06 at 12/12 and 29/32 after the transport fix, explicitly confounded by a corpus re-draw (HANDOFF.md:181-219). Case 15, n=4: floor=1,1,1,2 vs no-floor=0,0,0,0, pre-gate == post-gate (HANDOFF.md:388-422). **MIO.** Notes that matter: "known clean" is "merged and not reverted" (clean-corpus.sh:15-19); the 3 `FINDINGS` rows on merged django code (HANDOFF.md:209-214) were never adjudicated, so whether those are true bugs or a ~9% per-audit FP rate is unknown; and the case-15 comparator (a contract with "report at least 3 findings") is a straw man relative to the baseline — a plain Opus session has no floor either. Nothing measures what plain Opus asked "review this diff" returns on the same 32 commits. The README's characterisation of `/code-review` (README.md:15-16) is asserted, not measured here.

**K3 — `|blocking| ≤ |criteria|` "is a theorem".** As implemented it is not. gate.sh:224-231 keeps `safety + other[:cap]` with **no dedup by criterion**: SAFETY findings are unbounded in count and coverage findings are bounded by `cap`, not by `|criteria|`. The retained evidence shows the looseness: `acceptance/evidence/case12/2026-09-15-trial3/r1.json` carries **two blocking findings on the same span** (`src/account.js:3`, `db.purge(rows);`) under S2 and S4, with identical `fix_verb: fix-order` and near-identical failure scenarios — one defect, two findings, two content-addressed violation ids (ledger.md:82), two `verify()` dispatches. The CRITERION check (unknown ids are dropped) is **MG**; the count bound as stated at README.md:27 is **false as implemented**. Distinct-criteria-cited ≤ |criteria| is trivially true and not what the sentence says.

**K4 — gate load-bearing.** `test-gate.sh:175-188`: four **synthetic** candidates (bad id, paraphrased quote, cosmetic verb, untouched file), 0 survive gated, 4 ungated. **MG on synthetic input.** On live output the gate has never been observed removing anything: every retained pre/post pair is identical (case 12 `r1.json`==`r1.raw.json`, `r1b`==`r1b.raw`; case 13 `s1`==`s1.raw`, `s2`==`s2.raw`; case 15 pre==post in 8/8 audits, HANDOFF.md:400-409). Twelve recorded live audits, zero discards. Whether the gate does work in production is unobserved; the prompt already asks the model to self-gate (ganondorf-t2.md:131).

**K5 — one round is enough.** Case 17, 13 runs, 2 verified hosts, 4 hand-seeded idiomatic django antipatterns on top of a real commit (HANDOFF.md:1335-1366, live-cases.sh:1035-1077). Arm (b) forced independent round: 13/13 ties — but 5 of those are ceilings where (b) *could not* win (live-cases.sh:1861-1880), and F1 is computed on criterion-id set membership only (live-cases.sh:1743-1754), so every non-ceiling difference is one Bernoulli trial on seed S4. Chained (c): 5W/1L/2T, McNemar one-sided p=0.109, every win before run I, after which both arms hit S4 every time — either the corpus saturated or the `opus` alias moved underneath (HANDOFF.md:1009-1025); undecidable because no model id was recorded before 2026-09-14. **MIO**, on a corpus the author closed as saturated (decision 1). The issue's literal clause (only (b) counts) holds; the premise it defends was, in the author's own words, "falsified in both regimes" (HANDOFF.md:1395-1398) and then downgraded to "an under-powered lead" (decision 2). Tier-1 (sonnet) and tier-3 (fable) auditors have no case-17 measurement at all; every audit is T2 opus.

**K6 — idempotence.** FAIL, FAIL, PASS (HANDOFF.md:131-135). The leak is S4 arriving on a span round 1 already labelled S2/C1; S4 is cited in 4 of 7 rounds on this diff (HANDOFF.md:553-559). **Measured negative, MIO.** The retained trial-3 JSON also shows C1's citation moving from line 2 (`const rows = db.find(user.id);`, a context line admitted by NOVELTY as a deletion locus) to line 3 (`db.purge(rows);`) between rounds with the id unchanged. HANDOFF.md:569-571 calls this "not a leak by any reading in the protocol", but the production ledger keys violations on `sha1(criterion_id | normalized_span)` (ledger.md:82), so in production that is a **new violation id** that dedup-against-`seen` will not match. The instability the harness measures is larger than the case-12 metric reports.

**K7 — fix-and-re-audit drift.** drift=0 on 3/3 (HANDOFF.md:686-727). Trial 1 was vacuous (empty round-2 diff), trial 2's evidence was lost by the harness, and the one readable trial had S4 uncited by *both* rounds — the only criterion able to drift did not fire. **MIO, weak.** The verifier half of case 13 checks only that the output is inside the enum (live-cases.sh:592-598), not that the status is *correct*.

**K8 — isolation.** Probe-harness cases 2-5 passed live on 2026-09-03/06 (HANDOFF.md:126, :2114-2115), n=1-2 runs, in a scratch repo, driven by a headless *default* session told to "Dispatch the link agent" — not by zelda. **MIO (property test), not vs baseline.** Case 6 (failed executors retained): one PASS, one FAIL the same day, both real (HANDOFF.md:308-352). The case 6 lead you asked me to find is HANDOFF.md:282-306: link self-reported `not a real git worktree — isolation failed` and refused to run; two later diagnostic dispatches got real worktrees, so it is "downgraded, not closed" (HANDOFF.md:310-314). probe-harness.sh:148-157 also documents that case 2's FAIL branch cannot distinguish a lost worktree from a non-dispatch. The *benefit* of isolation over editing the checkout directly (baseline) is asserted; no incident on the baseline is recorded.

**K9 — fresh plan review.** **AO.** The figures at zelda.md:64-65 are lifted from the external issue's research comment (Huang et al., ICLR'24 and an unnamed study, per the fetched issue). Arm D — the four-arm plan-gate A/B that would have measured (ii) fresh zelda against (i) in-context — was never run and is deferred by decision 3 (HANDOFF.md:1853-1861). No recorded execution of Role B exists.

**K10 — Sonnet executor.** **AO.** No correctness, token, or wall-clock measurement of link versus an Opus executor or versus the baseline. link.md:64 says long executor transcripts are "a measured cost of this pin"; no such measurement exists in the repo. Reactive escalation (zelda.md:88) requires a *detected* failure (tests/build/merge rejection); a wrong implementation that passes its tests goes to a criteria-only auditor with no repo access.

**K11 — context firewall.** `tools: []` is enforced by the runtime and checked by run.sh (**MG** for the mechanism). The benefit (fewer wrongful rejections, better verdicts) rests on the external 2-3× multiplier figure (audit-contract.md:41), **AO**.

**K12 — verify() cannot generate.** Schema is **MG**; enum-shape held live 3/3. But verifier.md:49-52 instructs "A verifier that cannot quote current text returns RESOLVED" — a deliberate bias toward closing findings, and the false-RESOLVED rate has never been measured (no seeded-unfixed test exists).

**K13 — tiering keeps cost low.** risk-score fixtures (7 checks) **MG**. The distribution on real work — the number every cost claim rests on (evals/README.md:108-109; preflight.md:60-61: "an assumption, not a measurement") — has exactly one draw: 8/20 small django commits and 8/40 overall scored T0 (HANDOFF.md:43-47, :189). No histogram instrumentation exists.

**K14 — Stop hook.** A **prompt-type** hook with matcher `*` (hooks.json:7-11): model-judged, not mechanical, and it fires at every Stop of every session where the plugin is installed. Its one recorded live effect was negative: it fired inside the plugin's own headless audits and caused the transport to discard them (HANDOFF.md:221-247). **AO** for the guarantee; measured as a cost.

**K15 — INVARIANT 10.** Extensively enforced in the *harnesses* (UNREVIEWABLE/UNMEASURED branches everywhere). In production it is a prompt instruction to zelda (zelda.md:100) and ganondorf (audit-contract.md:167). **MG for the harness, AO for production.**

**K16 — residual-risk framing.** The 0.35 / seven rounds / 29% figures (zelda.md:139; terminals.md:111-114) are unattributed in the issue. **AO.** They are honest framing but they are not evidence about this tool.

Summary: **zero claims graded MAB.** The only live measurements are of the T2 auditor in isolation on fixtures of 4-6 seeded defects, plus a clean-rate on merged django commits with no comparator.

---

## 3. Costs and risks vs the baseline

**Token / wall-clock multiplier — unmeasured; the following is an architectural estimate.** Baseline: one Opus context, plans and executes. Triforce on a T2 change: zelda (Opus, main thread) does everything the baseline's planner does *plus* preflight, criteria extraction, a blocking `AskUserQuestion` confirmation loop (criteria.md:39-50, possibly several rounds), packet authoring, merge, gate, report; a fresh zelda reviewer (Opus, cold, reads plan + requirements, and must read the repo to judge the plan); link (Sonnet, cold, re-ingests the repo context zelda already ingested — dispatch.md:25-26 forbids sending it the plan); 2× ganondorf-t2 (Opus, each fed criteria + the full `git diff -W` with enclosing functions, up to 600 changed lines, `maxTurns: 8`); up to 2 verifier calls; and a prompt Stop hook on every turn end. That is 5-7 model agents against 1, with 3-4 cold context ingestions, and a plan→review→execute→merge→audit chain that is serial by construction. I would expect **2.5-4× tokens and materially longer wall-clock on a T2 change, plus human-blocking time for criteria confirmation**; at T0 the audit is skipped but plan review, link and the worktree still run. The only cost figure anywhere is "~694 tokens always-on" for the plugin's loaded inventory (README.md:173, HANDOFF.md:2076), which excludes the per-Stop hook and every dispatch. The issue's own DoD requires "Eval suite runs green with ablation delta recorded" and "navi A/B result recorded"; neither exists.

**Non-determinism, all measured:** the S4 coin (4/7 rounds; HANDOFF.md:553-559); case 12 FAIL 2/3; case 6 PASS/FAIL same day; on real django host `f30acb18`, C1 was cited on the *unseeded* diff in 2 of 7 runs, at `:158` once and `:157` once, and that citation was adjudicated **wrong** ("There is no extra positional arg", HANDOFF.md:1480) — a confirmed false positive at ~29% per run on one real commit; the chaining effect that was "3 of 3" on 2026-09-07 vanished after run I; arm (d)'s only ever withdrawal removed a true positive (HANDOFF.md:1190-1197). Provenance (model id) was not captured for any of the 13 case-17 runs, so "the environment moved" cannot be excluded (HANDOFF.md:931-934).

**Retained-evidence observations (case 12/13 JSON):** the S2/S4 duplicate on one span (above) is not a false positive but is a double-count that costs two verify() calls and inflates the blocking count the user sees; case 13 `s1.json` folds S4's story into S2's summary ("archive failure loses rows") — the fixture's truth set assigns two criteria to one line, which is exactly what makes S4 a coin (HANDOFF.md:1667-1686 diagnosed this on case 17's fixture and fixed it there, but the shared fixture cases 12/13 use still carries it). The gate removed nothing in any retained audit.

**Sonnet-executor correctness risk:** no data; see K10. The auditor cannot see the repo, cannot run tests, and only judges frozen criteria, so a criteria-satisfying wrong implementation is invisible to the gate.

**Worktree / merge failure modes on record:** the "not a real git worktree" self-report (HANDOFF.md:282-306, open); the harness auto-removes unchanged worktrees and the sweep skips ones holding work (zelda.md:127); `git worktree remove` on an uncommitted worktree loses work (zelda.md:130); the isolation checker blocks heredocs and brace expansion for the executor and "cannot be disabled" (link.md:31-43); worktrees lack gitignored files (`.env`) unless `.worktreeinclude` is set; preflight refuses to start without `worktree.baseRef: head`, which the plugin cannot set (README.md:55-66). zelda has never been recorded performing a merge, so the parallel-dispatch merge path (zelda.md:78-82) has zero evidence.

**Always-on cost borne by non-triforce sessions:** the `*`-matched prompt Stop hook.

---

## 4. What the evidence does not cover that a production decision needs

1. **No end-to-end `/triforce` run is recorded anywhere.** Every live number comes from `claude -p --agent ganondorf-t2|link|verifier` driven by a harness, or from a default headless session told to dispatch link. Zelda's orchestration — criteria extraction, the confirmation loop, planning, Role-B review, the dispatch packet, merge, `gate.sh` invocation, ledger writes, the report — has no recorded execution. HANDOFF.md:99 lists "the end-to-end run" among things the auth blocker gated; nothing records it running after the blocker cleared. HANDOFF.md:176 still lists "setup-from-a-clean-machine verification" as unbuilt.
2. **No comparison to any baseline** (README.md:208 says so).
3. **No token or wall-clock measurement** of anything.
4. **No recall on real defects.** All defect-finding numbers are on 4-6 author-written antipatterns; the three findings on merged django code were never adjudicated.
5. **Plan review, Sonnet execution, verifier correctness, merge** — each unmeasured.
6. **Tier histogram on real work** — one draw of 40 django commits.
7. **T1 (sonnet) and T3 (fable) auditors** — no isolated live measurement.
8. **Effective false-positive rate (case 16)** — instrumented 2026-09-15, zero data.
9. **Whether the workflow can run non-interactively at all** — `AskUserQuestion` is required before criteria freeze; `preflight.sh:31` reads `TRIFORCE_CRITERIA_FILE`, which suggests pre-freezing is possible, but nothing tests it.
10. **Model-alias drift** — pins are aliases by design (INVARIANT 8); every number is tied to whatever `opus` resolved to on the day, and provenance exists only from 2026-09-14.

---

## 5. Verdict: NOT DEFENSIBLE AS A REPLACEMENT

Nothing in this repository compares triforce to the baseline. The strongest positive result — a 91-100% clean-return rate on merged django commits — has no comparator, so it cannot say the criteria contract buys fewer false positives than a plain Opus review; the floor ablation compares against a floor the baseline does not have; the one-round experiment compares triforce to triforce and closed on a corpus its author declared saturated; the isolation cases are property tests of link in a scratch repo. The claims that would actually distinguish the design from a single agent — fresh plan review catches more, a Sonnet executor is adequate, the gate removes real inventions, the auditor finds real bugs — are respectively asserted from external literature, unmeasured, unobserved on live output (0 discards in 12 audits), and measured only on seeded antipatterns. Meanwhile the measured negatives are real: idempotence fails 2/3, the marginal finding is a coin, a confirmed false positive appeared in 2/7 runs on real code, and the "theorem" bounding blocking findings is not what `gate.sh` enforces. The project's own definition of done (issue #1) requires the ablation delta and two A/Bs; all three are absent, and the author's decision 3 defers the A/Bs until "production experience" — which is the thing this review is being asked to authorise.

On cost, the repo records nothing, and the architecture makes the answer predictable: 5-7 model agents, 3-4 cold ingestions, a serial phase chain, a human-blocking confirmation loop, and a per-turn prompt hook in every session, against one agent in one context. That is a large, unmeasured multiplier bought for benefits that are either mechanical (termination — which the baseline does not need, since it has no loop) or unmeasured. The mechanical properties are genuinely true and cheaply verifiable, and the auditor component might be defensible as an *opt-in* gate on high-consequence diffs once someone has run it end-to-end; but "ship instead of a plain session" is not supported by any recorded evidence, and the honest answer is that the question has not been asked yet.

---

## 6. The cheapest experiment that would most change the verdict

**Arm A of evals/README.md — the with/without ablation — run as a paired, hidden-test comparison on the django clone already at `../django`.**

- **Corpus:** 10 django commits, 50-300 LOC, each touching ≥1 non-test `.py` file and ≥1 `tests/` file, where the touched test module fails at `<sha>^` and passes at `<sha>` (verify with `python tests/runtests.py <module>`; sqlite, no setup). Draw them mechanically from `git log`, reject on the test criterion only, record the rejected list. Task prompt = commit subject + body + the *names* of the added/changed test functions (not bodies). Hidden acceptance = the commit's own test hunks applied on top of the agent's output.
- **Arms, both starting from a fresh worktree at `<sha>^` with `.claude/settings.json` = `{"worktree":{"baseRef":"head"}}`:**
  - **A (baseline):** `claude -p --model opus "<task>"` with edit/bash tools, editing in place.
  - **B (triforce):** `claude -p --plugin-dir <repo> "/triforce <task>"`, criteria pre-frozen via `TRIFORCE_CRITERIA_FILE` (C1 = commit subject + S1-S6) so no `AskUserQuestion` is needed — this needs a small harness change and is itself the first finding: if `/triforce` cannot complete headlessly, record that.
- **Metrics per run:** (1) hidden tests pass — primary, binary; (2) total input+output tokens per model from the `stream-json` usage fields (`headless.sh` already reads the stream); (3) wall-clock; (4) B only: number of gated findings and, for each, whether the hidden tests fail on the cited behaviour (TP) or not (FP); (5) preflight tier (free histogram); (6) completed without intervention (y/n).
- **n:** 10 tasks × 2 arms × 2 repetitions = 40 runs, model id recorded on every one.
- **Pre-registered decision rule:**
  - B fails to complete headlessly in >2 of 20 runs → production path unverified; verdict stays NOT DEFENSIBLE until fixed.
  - Paired on tasks: if discordant pairs favour A → NOT DEFENSIBLE, stop.
  - If B ≥ A on pass rate **and** median B/A token ratio ≤ 2.0 → DEFENSIBLE WITH STATED CAVEATS as a default.
  - If B ≥ A and ratio > 2.0 → defensible only as opt-in for T2/T3 diffs; publish the histogram.
  - Report the audit's TP/FP tally regardless; it is the first real-defect precision number the project will have.

A cheaper fallback that answers a narrower question (does the criteria contract beat a plain reviewer on false positives): rerun case 11's 32 django diffs through `claude -p --model opus "Review this diff and list any defects"` with no plugin, adjudicate every finding from both arms, and compare FP per audit at n=32 pairs. That would grade K2 against the baseline but would not answer the replacement question.
