# Handoff — finishing triforce

The plugin is built, installed, and shipping. What remains is **measurement**, not construction.

Read this before touching anything. Several decisions below look like bugs and are not; a cold
session that "fixes" them will quietly undo work that was settled deliberately.

Spec of record: [cookiesncache/claude-plugins#1](https://github.com/cookiesncache/claude-plugins/issues/1)
and its research comment. Treat the issue as authoritative and **quote it rather than paraphrase**
— the design turns on exact wording in several places.

---

## Step 1 is a gate, not a task

```bash
bash acceptance/clean-corpus.sh
```

This measures the **clean-return rate on known-clean diffs** — the headline metric. The issue's bar:

> at or above 70% in the under-50-LOC band. *Below 50% the whole criteria contract is decorative
> and the design has failed.*

**Branch on the result before doing anything else:**

| Result | What it means |
|---|---|
| **≥ 70%** | The contract works. Proceed to step 2. |
| **50–69%** | The contract works but needs tuning. Tune the criteria prompt, **not** the gate — the gate is already proven load-bearing (0 survivors gated vs 4 ungated). Do not add a finding floor. |
| **< 50%** | **Stop.** The design has failed on its own terms. Do not build the remaining arms — they would be work spent on a failed premise. Report the number and revisit the criteria reframe with the user. |

Everything below assumes step 1 cleared.

### Measured — 2026-09-02: 91% (11/12), the bar is cleared

```bash
bash acceptance/clean-corpus.sh --repo <django> --n 40
#   under-50-LOC band : 11/12  (91%)   <- the headline
#   all audited bands : 30/32  (93%)
```

**Read the denominator, not just the percentage.** 20 small commits were drawn; 8
scored T0 and were SKIPPED (correctly counted in neither direction), leaving 12. One
audit is worth 8 points, so this is "clears the bar with one unexplained row", not a
precise rate. Pass `--n 40`, not the default 20 — at `--n 20` the band yields
`SMALL_TOTAL=7`.

**An earlier run of this same harness reported 100% (32/32). That number was an
artifact and is retracted** — see the extraction defect under "Things that will bite".
It is recorded here because a cold session that finds "100%" in old notes and "91%"
here must know which one is real.

The two `UNREVIEWABLE` rows (`1d50f129`, `febefb17`) each reproduce **clean** in
isolation — 50s and 87s, both markers present, empty array. They were transient
infrastructure failures during a 32-call batch, not reviewer failures. The measured
91% deliberately still counts them against the rate; the harness has no retry, and
adding one is a judgement call, since retries also mask systematic failure.

**Corpus.** The default `--repo` is this repo, which cannot support the metric: it has
2 commits under 50 LOC and only 1 is auditable. Local repos were all unfit — the
binding constraint is not size but commit-subject quality, because `clean-corpus.sh`
lifts criterion C1 *verbatim from the commit subject*, and "Update content.js" is not a
criterion. django/django was chosen for descriptive subjects, a real review gate, and
264 of 400 commits under 50 LOC. It lives in the scratchpad and will not survive;
recreate with:

```bash
git clone --depth 400 --single-branch https://github.com/django/django.git django
```

---

## Blockers, and what each one gates

Nothing outstanding is blocked on missing code. All three blockers were environmental,
and **as of 2026-09-02 all three are CLEARED** on CLI **2.1.258**. The table is kept
because the symptoms recur and are each mistakable for something else.

| Blocker | Gates | Status |
|---|---|---|
| **No authenticated `claude -p`** — reports "Not logged in" even with valid credentials on disk | cases 2–6, 11, 12, 13, 15, 17, the plan-gate A/B, the end-to-end run | **CLEARED.** Probe returns `READY` |
| **`claude plugin eval` not exposed** at CLI 2.1.195 — *in* the binary but early-access gated | the eval suite and the with/without ablation delta | **CLEARED** at 2.1.258. Its help advertises a **no-plugin baseline arm**, which is the ablation delta |
| **`CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH` absent** before CLI **2.1.219** | navi's A/B and the depth-1 / depth-3 arms | **CLEARED** — present in the 2.1.258 binary |

Two traps this cost time on, both worth knowing:

- **The two shells report auth differently.** Git Bash says `Not logged in · Please run
  /login`; PowerShell says `Failed to authenticate: OAuth session expired and could not
  be refreshed`. The second is the true diagnosis. `~/.claude/.credentials.json` can
  exist, carry `"subscriptionType":"pro"`, and still have `"expiresAt":0`.
- **`claude.exe` self-updates mid-session.** A version read at the start of a session can
  be stale by the middle of it — this box went 2.1.195 → 2.1.258 in place, at the same
  path, without a reinstall. **Re-probe the CLI version before trusting a blocker
  claim**, including the ones in this table.

Every harness is already written and gates on an auth probe, reporting **UNMEASURED** rather than
skipping quietly. A case that did not run must never be counted as one that passed.

---

## The work, in order

```bash
bash acceptance/run.sh                    # DONE — 105 checks green, offline, must stay green
                                         #   verified at the committed tip, 2026-09-03
bash acceptance/clean-corpus.sh           # DONE — case 11, THE GATE: 91% (11/12), cleared
bash acceptance/probe-harness.sh          # DONE — 7/7 green, PROBE_EXIT=0 (2026-09-03)
                                         #   case 6 is dispatch-flaky: 2 of 4 runs came back
                                         #   UNMEASURED because the model declined the prompt.
                                         #   That is the guard working, not a regression. Re-run.
bash acceptance/live-cases.sh --case 12   # FAILED — 2026-09-03, on the CORRECTED blocking-only
                                         #   population. S4 leaked. This one is real. Section below.
bash acceptance/live-cases.sh --case 13   # PASSED — 2026-09-03, drift=0, verifier enum clean.
                                         #   Its FIRST pass that day was VACUOUS (empty round-2
                                         #   diff); fixture fixed, this is the real one. n=1.
bash acceptance/live-cases.sh --case 15   # INCONCLUSIVE — 2026-09-03. floor=0 vs no-floor=0.
                                         #   The ablation does NOT confirm the floor is the
                                         #   mechanism. Read its section before re-running.
bash acceptance/live-cases.sh --case 17   # RAN — but UNINFORMATIVE. All three arms scored
                                         #   F1=1.000. Ceiling effect: (b) COULD NOT beat (a).
                                         #   The corpus is too easy. Read its section.
```

Then, still to be **built**, not just run:

1. **navi** — the CLI blocker is gone (2.1.258 has the env var). Build it, run the A/B, then
   apply the decision rule below. Do not build it before the A/B.
2. **The plan gate's four arms** — (i) in-context self-critique, (ii) fresh zelda subagent,
   (iii) fresh + ganondorf, (iv) fresh + ganondorf as a **delete-only refuter**.
3. **Setup-from-a-clean-machine** verification, following only the README.
4. **Case 16**, effective false positives over rolling windows — genuinely cannot be done yet; it
   needs production audits to accumulate.

### Case 12's FAIL is VOID — it counted the wrong population (harness fixed 2026-09-03)

The 2026-09-03 result

```
case 12 — idempotence
  FAIL  idempotence: 1 criterion(s) appeared only on the second run — the schema is leaking
```

**does not stand — and it is not evidence of a clean design either.** It measured a population
the case was never specified over. Both items this section used to list are now done, and two
further defects surfaced underneath them.

1. **DONE — the population is blocking-only.** The spec says *"ZERO new **blocking** entries."*
   `crits()` extracted every `criterion_id` regardless of severity, so a second-run `minor`
   finding tripped a check written about blockers. `bcrits()` filters on `severity == "blocking"`
   and treats an absent severity as `minor`, exactly as `gate.sh`'s own sort does. Case 13 shared
   the helper and is fixed with it. Case 12 now prints the all-severity delta beside the blocking
   one, so neither number is hidden and neither population is swapped in silently.

2. **DONE — case 12 names the ids that leaked**, through the same `comm -13` output case 13 had.

3. **FOUND — `nviol()` never returned a usable integer.** `grep -c` prints `0` and exits 1 on no
   match, so the `|| echo 0` fallback appended a *second* zero and the function returned two
   lines. Every `[ "$n" -eq 0 ]` against it died with "integer expression expected" and fell
   through to its else branch — the FAILING one. Consequences: **case 15 could never have
   reported its own success condition** (a clean diff returning zero violations), and the new
   UNMEASURED guards would have been inert on precisely the emptiness they exist to catch.
   `risk-score.sh` had already hit this trap and documented it verbatim; the acceptance harness
   was carrying the unfixed version.

4. **FOUND — `bcrits` emitted CRLF.** Python's text-mode stdout translates on Windows, so the ids
   would have sorted and compared as `C1\r` against grep's plain `C1`. Stripped at the source.

All four are locked in by seven offline checks in `run.sh`, two of which **lift the real helpers
out of `live-cases.sh` and run them** rather than grepping for their presence — a filter that
exists but does not filter is the same false green as no filter at all.

### The re-run happened. Case 12 FAILS, and this result is real

```
case 12 — idempotence
  FAIL  idempotence: 1 blocking criterion(s) appeared only on the second run — the schema is leaking
        S4
```

2026-09-03, on the corrected blocking-only population, with the leaked id named. **The leak
survived. Say it plainly: the schema is leaking.** Re-auditing an unchanged diff produced a
blocking finding the first audit did not produce, so the finding population is not bounded by
the diff and the criteria — it varies with the run. That is the defect the case exists to catch,
and it is now measured rather than inferred.

**Do not discount it on any of the following, all of which were checked first:**

- It is not the wrong population. The filter is blocking-only, matching the spec's own words.
- It is not a non-execution. Both rounds returned findings; the UNMEASURED branch did not fire.
- It is not a broken counter. `nviol` and `bcrits` are both exercised by `run.sh` against
  fixtures shaped like real gate output.

**One observation, offered as a lead and not as an excuse:** the leaked criterion is **S4**,
and S1–S6 are the SAFETY set, which `gate.sh` holds **exempt from the finding cap**
(`kept = safety + other[:cap]`). A SAFETY finding therefore always survives truncation. Whether
the leak is specific to cap-exempt criteria is unknown from one trial and is the obvious next
measurement — but it does not soften the verdict, and a second trial must be run as a
pre-declared characterisation, never as a retry hoping for green.

An earlier attempt the same day was refused by the auth gate (`OAuth session expired`) and was
recorded as UNMEASURED, not as a pass. The token refreshed and the run above is the real one.

If a blocking criterion still appears only on the second run, the leak is real and it is the
schema leaking — say so plainly. The asymmetry is deliberate and correct: the check counts
criteria present in run 2 and absent from run 1, because a *new* finding on re-audit is precisely
the bug. Noise in the other direction is not.

One further deviation worth knowing about, deliberate and **not** a reason to discount the
re-run when it happens: the spec
frames case 12 as a re-run *"on an unchanged diff that returned PASS"*, and the shared fixture
diff carries seeded defects, so round 1 does not return PASS. The harness is testing the
stronger property — stability of the finding set on any unchanged diff.

### Case 13 passes — but its first pass that day was vacuous, and that matters

```
case 13 — fix-and-re-audit (rounds 1..3)
  ok    round 2 cites no criterion that was not blocking in round 1 (drift=0)
  ok    verifier emitted a closed-enum status and nothing outside it
```

**The first run of this on 2026-09-03 printed the identical two lines and meant nothing.** The
fixture's "fix" wrote the base content back byte for byte, so `git diff HEAD~2..HEAD` was empty
— round 2 audited nothing, returned nothing, and `drift=0` held by construction. Same tree SHA,
zero-byte diff. It was a green that could not have been red, exactly like case 3 before its
fixture was repaired.

The fix now repairs C1 (the confirmation guard returns) and **deliberately leaves the destructive
purge**, so S2 and S4 stay live and round 2 has 325 bytes of real code to audit. The case aborts
at runtime if the round-2 diff is ever empty again, and two offline checks in `run.sh` lift the
base and fix bodies out of this file and compare them, so a restated copy cannot drift into
agreement with a broken original.

**What the pass does and does not establish.** It is a real measurement: round 2 cited no
criterion that was not blocking in round 1, and it could have failed. But **n=1, and case 12
demonstrated that round 1's recall varies on exactly S4.** Had this run's round 1 drawn the
unlucky sample and missed S4, round 2 would have cited it and drift would have been 1. So the
result is "drift was 0 on one trial", not "drift is reliably 0". Treat repeat trials as
characterisation, and declare the protocol before running them.

**The verifier half was always sound** — the closed-enum check tests the verify agent's output
vocabulary and never depended on the diff being non-empty. That line was a real pass both times.

**Not retained, and it should be.** Neither case keeps its round-1/round-2 gated JSON — `WORK` is
removed by the `trap` — so which criteria each round actually cited cannot be recovered after the
fact. That is why case 12's leak can only be characterised by hypothesis. Retaining those two
files under an opt-in flag is the obvious next harness change.

### Case 15 is INCONCLUSIVE — the floor did not manufacture findings

```
case 15 — floor ablation
  ok    no floor: clean diff returns zero violations
  FAIL  ABLATION inconclusive: floor=0 vs no-floor=0. The floor should force findings onto clean code.
```

Told **"Report at least 3 findings."** with no escape hatch, on a clean diff, the reviewer
returned zero. Both arms parsed — no decline, no UNREVIEWABLE — so it complied with the truth
over the quota.

**Say it plainly: the ablation does not confirm that floor removal is the mechanism for Cause A.**
The spec requires the clean rate to fall to ~0 under a reinstated floor. It did not fall at all.
The no-floor invariant may still be right on principle, but *this* evidence for it is absent.

Two defects were fixed in the case before it was run, and both had made every previous run
meaningless:

1. **It audited the wrong diff when run standalone.** The comment claimed "a genuinely clean
   diff: the fixture, already fixed" — but the fix commit is created by **case 13**. Run as
   `--case 15`, case 13 has not run, `$FIX`'s HEAD is the DEFECTIVE commit, and the case audited
   the defect-introducing diff while asserting it was clean. It now commits its own clean state
   and aborts on an empty diff.
2. **Its floor arm was not a floor.** It said *"Target at least 3 findings … do not invent to hit
   the floor"* — a suggestion with an escape hatch. Invariant 1 forbids a floor *anywhere*, and
   this case's own spec says to reinstate "report at least 3 findings". Ablating a softened floor
   cannot show the floor is the mechanism. It is now the literal text.

#### The instrument was fixed, and the result held

The first run could not carry its own causal claim: `nviol` counts **post-gate** survivors, and
`audit()` wrote every call's pre-gate array to the same `$WORK/raw.json`, each overwriting the
last. So "the floor produced nothing" and "the floor produced findings the gate removed" — which
are *opposite* conclusions about whether the floor is harmful — were indistinguishable.

`audit()` now keeps a per-call pre-gate array at `${out%.json}.raw.json`, and case 15 reports
both populations. Re-measured as a declared follow-up on 2026-09-03:

```
case 15 — floor ablation
        post-gate: no-floor=0 floor=0   |   pre-gate: no-floor=0 floor=0
  ok    no floor: clean diff returns zero violations
  FAIL  ABLATION inconclusive: floor=0 vs no-floor=0 post-gate, 0 vs 0 PRE-gate.
        The floor produced nothing to gate away, so floor removal is NOT
        shown to be the mechanism for Cause A on this corpus.
```

**Pre-gate is 0 for both arms.** The gate was not masking a floor effect — there was no floor
effect to mask. The earlier reading stands and is now better supported, not overturned: told
*"Report at least 3 findings."* on a clean diff with no escape hatch, the reviewer returned
nothing, before gating and after.

The ablation now has three outcomes rather than two, and names which one holds. The middle branch
— *"the floor DID manufacture findings and the GATE removed them"* — did not fire, and it is the
one that would have changed the conclusion.

**What remains unshown is the causal claim, not the invariant.** The no-floor rule may still be
right; this corpus simply does not demonstrate that the floor is what produced Cause A. As with
case 17, the corpus is the limiting factor — a clean six-line function gives a reviewer almost
nothing to invent about. Test the floor on a larger clean diff before concluding either way.

### Case 17 ran — and it could not have falsified anything (2026-09-03)

#### The result, verbatim

```
case 17 — the one-round premise, against its own falsifier
  (a) K parallel, one round          findings=3   TP=3   FP=0   precision=1.000  F1=1.000
  (b) + forced second round          findings=3   TP=3   FP=0   precision=1.000  F1=1.000
  (c) K sequential rounds            findings=3   TP=3   FP=0   precision=1.000  F1=1.000
        NOTE: arm (c) is NOT yet distinct from arm (a) — both are K
        independent audits unioned, with no round-to-round chaining.
        Its number is reported, but it is not a sequential arm yet.

  ok    one-round premise holds on this corpus: (a) F1=1.000 >= (b) F1=1.000

  1 passed, 0 failed
```

#### What it means: a ceiling, not a corroboration

Every arm found exactly `{C1, S2, S4}` — all of ground truth, no false positives. **Arm (a) hit
the ceiling.** Arm (b) is *constructed* as arm (a) ∪ one extra audit, so `b ⊇ a` by construction:
with (a) at TP=3/3 and FP=0, (b) cannot raise TP and can only add false positives. **`b > a` was
mathematically impossible in this run.** The printed `ok` line overstates what happened.

So the honest reading is **not** "the one-round premise holds". It is: **this corpus cannot test
the premise.** Six lines, three seeded defects, and the reviewer saturates it every time. The
falsifier needs a corpus where one round demonstrably misses things. **That is now the blocker on
case 17 — not anything about the design.**

The case now refuses this itself: when arm (a) scores every truth criterion with zero FPs it
prints `UNINFORMATIVE … THE COMPARISON HAD NO POWER TO FALSIFY`. This run predates that guard;
its numbers stand, and the guard is what stops the next reader taking them for a corroboration.

One connection worth drawing to case 12, which is suggestive and **not** a result: case 12 showed
the reviewer's recall on S4 varies between single audits. Here every arm unions 2–3 audits and
all found S4. Those are consistent — unioning is precisely what masks per-audit recall variance.
It hints that K-parallel is doing real work, but this test was not designed to show that and
n=1 cannot carry it.

#### Three defects had to be fixed first, two of them fatal

Read this before trusting any case 17 number printed by an older checkout.

1. **Its diff never existed.** `git diff -W HEAD~2..HEAD~1` needs three commits; the fixture makes
   two. Standalone it exited 128 — *"ambiguous argument … unknown revision"* — wrote a zero-byte
   diff, and every arm audited nothing. After cases 13 or 15 the range pointed at *their* commits.
   The range is now pinned by SHA at fixture time, before any case commits on top of `$FIX`.

2. **The verdict was a lexical comparison of two labels.** `score()` printed its row *and* the F1
   to stdout and was called as `F1A=$(score …)`, so `F1A` held the whole row. `awk -v` then
   compared two non-numeric strings — a *string* comparison — and `"(b) …"` sorts after `"(a) …"`,
   so **`b>a` was TRUE unconditionally and the case reported FALSIFIED on every run**. Shown
   directly: arm (a) F1=1.000 against arm (b) F1=0.800 still returned `b>a is TRUE`. Under the
   standing rule not to rationalise a falsifying result, this would have forced a design revision
   on the alphabetical order of a label. `score()` now sets `SCORE_F1`.

3. **Ground truth omitted S4.** The seeded code purges *before* archiving, so a failing archive
   leaves rows deleted and unarchived — S4 is genuinely violated, judged from the code alone.
   Scoring it as a false positive penalised whichever arm searched hardest, which is **arm (b)**.
   Adding it makes falsification *easier*, so the correction cannot be read as protecting the
   premise.

**Owed, not silently fixed: arm (c) is not a sequential arm.** It is identical in construction to
arm (a) — K independent audits unioned, no round-to-round chaining. Its number is printed with
that stated inline. Building a real sequential arm means deciding how rounds chain, which is a
design decision.

### Case 17 deserves special attention

It can falsify the design. If arm (b) — one forced second hunting round — beats arm (a) on F1, then
per the issue the one-round premise **"is wrong for this workload and the design must be revised,
not defended."** Do not rationalise a falsifying result. Report it.

**Case 17 could not falsify anything before 2026-09-02.** The extraction defect above
made every arm score zero findings, so its F1 comparison was degenerate — it would have
returned a tie and looked like a corroboration. It is only now a real experiment. Any
case 17 result recorded before that date is void.

---

## Decisions that are settled — do not re-litigate

### Two deviations from the issue's literal text, both deliberate

**1. `context: inline` + `agent: zelda`, not `context: fork`.**
The issue lists `context: fork` as the answer to *"How should `/triforce` pin zelda to Opus?"* — that
was its only rationale. `agent:` under `context: inline` applies the same model pin, prompt, and tool
restrictions, and fork would cost two things:

- **Mid-process user input.** The CLI's own authoring guidance, read from the binary:
  *"Only set `context: fork` for self-contained skills that don't need mid-process user input."*
  Criteria confirmation is exactly that.
- **The worktree.** `EnterWorktree` refuses to *create* one from a subagent with a cwd override —
  *"it would mutate the parent session's process-wide working directory."* Running as the main thread
  is the only configuration where zelda can claim a worktree.

A verified bonus: **`context: fork` does not consume a spawn-depth level.** Every `agentType:"subagent"`
context in the binary is built with `depth: K4(parent)+1` on the Agent/Task path; the fork handlers
build a base agent and track a separate `queryTracking.depth`. So under a depth-1 policy only navi is
lost, exactly as the issue says.

**2. NOVELTY admits deletion loci, not just added lines.**
As literally specced ("the cited line was introduced by this diff") a pure deletion is uncitable —
nothing is added. That would make a removed auth guard **structurally invisible**, contradicting the
risk scorer, which treats guard deletion as a categorical T2 floor. The admissible set is lines
*changed* by the diff: added lines **∪** deletion loci. Covered by a fixture in `test-gate.sh`.

### Two spec readings fixed in place

**The tier table's `Cap` column is the FINDING cap, not the invocation cap.** The table reads 4/6/8
while `INVOCATION_CAP` is {T1:4, T2:6, T3:9}. They reconcile once `Cap` is read as the finding cap —
the thing SAFETY rows are described as exempt from. The arithmetic confirms it: lifetime invocations
are exactly `HUNT_K + (REAUDIT_MAX × K) + VERIFY_MAX` = 4 / 6 / 9.

**The six SAFETY criteria are a construction, not quoted from the issue.** The issue references
"the six SAFETY criteria" throughout but never enumerates them. S1–S4 are lifted from its own
`blocking` definition; **S5 (unbounded resource consumption) and S6 (concurrency or ordering hazard)
are invented.** If the author wants different ones, they are in
`skills/triforce/references/audit-contract.md` and mirrored in `gate.sh`.

### Seats that are empty on purpose

**navi is CUT** and **the plan gate is DEFERRED**. Neither is an oversight. The issue's decision rule
is explicit that shipping either unmeasured is not an acceptable outcome. A cold session will be
tempted to helpfully build them — don't, until their A/Bs run.

If the plan gate ships at all, the candidate configuration is **(iv), the delete-only refuter** —
the one multi-model arrangement the research supports.

---

## Things that will bite

- **A line-oriented violations extraction silently turns every audit into a PASS.**
  Both live harnesses used `sed -n 's/.*<<<VIOLATIONS//p'`, which prints only the
  *remainder of the marker's own line* — never the following lines, which is where the
  JSON array lives. The whitespace fallback then wrote `[]`, `nblock` came out 0, and
  the verdict was `PASS`. This made `clean-corpus.sh` report **100% unconditionally**,
  for every commit, regardless of what any auditor found. Fixed 2026-09-02 with a range
  extraction, `sed -n '/<<<VIOLATIONS/,/VIOLATIONS>>>/p' | sed '1d;$d'`, guarded by four
  offline checks in `run.sh` so it cannot regress without a live model to notice.
  **The gate was innocent throughout** — `gate.sh` discarded nothing, because it was
  never handed a candidate. Verifying that the *model* emits findings does not verify
  that the *harness* can read them; check the whole path.

- **A NON-EXECUTION IS NOT A DEFECT.** This bit three times in one session, in three
  different disguises, and every disguise produced a *confident false alarm* rather than
  an error. Fixed 2026-09-03; four offline checks in `run.sh` now hold the line.
  - *The fixture never built.* `probe-harness.sh:55` wrote to `src/app.js` in a scratch
    repo whose `mkdir -p "$R/.claude/src"` never created `src/`. The redirect failed, the
    commit had nothing to commit, its failure was swallowed by `>/dev/null 2>&1`, and
    `ORCH_COMMIT` became main's own tip. **Case 3 — the highest-value test in the file —
    then passed vacuously**, asserting that an executor could see a commit reachable from
    main no matter where it branched. There is now a fixture guard that aborts if
    `ORCH_COMMIT` is an ancestor of `main`, and `run.sh` lifts and runs the real fixture
    block rather than restating it, so a restated copy cannot drift into agreement with a
    broken original.
  - *The sandbox refused the command.* Case 3 asked for `git merge-base --is-ancestor X
    HEAD; echo ANCESTOR=$?`; link's sandbox intermittently declined the compound form as
    too complex to verify. No assertion ran, and the harness reported **"executors are
    building on the DEFAULT BRANCH"** — a serious false alarm, and a flaky one: the same
    command had passed twice before. Case 3 now asks for one bare `git rev-list HEAD` and
    greps the ancestry directly. No exit-code plumbing, nothing to refuse.
  - *The model declined the task.* Case 6 asked link to "report TESTS -> FAIL", which is a
    request to fabricate a result; it was declined, no executor was ever dispatched, and
    the harness reported indiscriminate cleanup. Two further framings were also declined —
    "use the link agent" for a **write** task reads as misuse (link is dispatched by zelda,
    which is why read-only cases 2–3 slipped through and this one did not), and "create
    FAILED_MARKER containing 'left behind' … do not clean up" reads as artifact-planting.
    What works is an ordinary development task against a suite that fails on its own.
  **The general rule: any case that dispatches an agent must be able to distinguish
  "the assertion ran and was false" from "the assertion never ran," and must report the
  second as UNMEASURED.** This is invariant 10 wearing different clothes.

- **`python3` on Windows is a Store alias stub** that exists on PATH and fails on exec. `gate.sh`
  probes interpreters by running them. This once made five negative assertions go green against a
  crashed gate — which is why **every negative assertion now requires the gate to exit 0 and name
  the check that fired.** Keep that discipline: asserting "zero findings" alone is satisfied by a
  tool that never ran.
- **Assertions must be positive.** A wrong `worktree.baseRef` produces a completely normal-looking
  run. "No error was raised" proves nothing here.
- **`grep -c` prints `0` and exits 1**, so `|| echo 0` appends a *second* zero and breaks every
  later arithmetic test. `risk-score.sh` has a `count_matches` helper for this.
- **Bash heredocs fight this repo's content.** Prompt contracts are full of backticks, braces and
  JSON. Use the `Write` tool for file contents; multi-line `python - <<'PY'` string replacement
  fails silently often enough to be a poor tool for editing prompts.
- **The ledger's `unresolved` line carries a trailing comma.** Strip it before manipulating the
  array or `${rest%]}` removes nothing and the JSON corrupts.

---

## Invariants that must survive any change

Check these before committing anything. `acceptance/run.sh` enforces most mechanically.

1. **No finding floor.** Anywhere, in any tier, in any prompt. A floor and a stopping rule are
   mathematically incompatible.
2. **No loop over the generator.** `audit()` returns; re-entry is a fresh top-level call gated on
   persisted ledger state. Legal triggers are E1/E2/E3 only, and the illegal list is refused *by
   name* — including **the severity of what was found**.
3. **Counters are monotone.** Any write that would decrease one exits non-zero and changes nothing.
4. **Dedup against `seen`, never `confirmed`.** Keying on `confirmed` is what makes a loop never
   converge.
5. **The orchestrator never authors criteria.** They come from the user's request text, confirmed via
   batched `AskUserQuestion` — **never truncated.** If they don't fit, ask another round of
   questions; the list never gets shorter.
6. **No statistic** is computed, displayed, or allowed to route control flow.
7. **`tools: []`** on ganondorf and verifier. The context firewall is a type, not a request.
8. **Model pins are aliases** (`opus`/`sonnet`/`fable`/`haiku`), never dated IDs.
9. **The README carries shape, not figures** — no benchmark percentages or dollar amounts; they go
   stale. The project's own bars (70%/50%) are spec constants and may stay. Enforced by a check.
10. **A truncated, crashed, or timed-out reviewer can never produce `PASS`.**

---

## Repo state

- **`cookiesncache/triforce`** — `main` only, no PRs, catalog pins its tip.
- **Catalog** — merged as `b5b4c46` in `cookiesncache/claude-plugins`; re-pin the SHA there on every
  release, and bump `.claude-plugin/plugin.json` alongside it.
- **`acceptance/run.sh`** — **122** checks (89 + 4 guarding the extraction defect,
  + 5 guarding the probe-harness fixture and the non-execution class, + 7 guarding the
  blocking-only population and the counters it rests on, + 2 guarding case 13's fixture
  against reproducing the base tree, + 3 guarding case 15's self-containment and its
  floor text, + 9 guarding the falsifier's ability to falsify, including a three-way
  test that drives its verdict chain to every outcome, + 3 guarding per-call pre-gate
  retention), offline, currently green. Keep it green.
- Installed as `triforce@cookiesncache-marketplace`, **~694 tokens always-on** (the recorded baseline).

## Definition of done — current state

**2 of 10 met, one definitively NOT met, one inconclusive.** `Tier 1 checks pass` ✅ and
`clean-return rate ≥ 70%` ✅ (91%, 11/12). **Idempotence ❌** — case 12 measured and failed
(S4 leaked on re-audit of an unchanged diff); a measured negative, not an open item.
**Fix-and-re-audit drift ✅** — case 13, drift=0 on a fixture that can now show drift, n=1.
**Floor ablation ⚠️** — case 15 ran twice, the second time with pre-gate visibility, and did
not confirm the floor is the mechanism (0 vs 0 both post- and pre-gate). Not a gating artifact.
**The one-round premise ⚠️ UNTESTED** — case 17 ran, every arm scored F1=1.000, and arm (b)
could not beat a perfect arm (a). A ceiling, not a corroboration. The corpus is the blocker.

Nothing is blocked on access any more — all three environmental blockers are cleared.
The remaining eight are blocked on **work**, not permission, except case 16, which
needs production audits to accumulate.

Cases 2–6 are green as of 2026-09-03, and green *meaningfully* for the first time:
case 3 previously could not have failed. **Case 12 has now failed for real**, on the corrected
population, leaking S4 — and **case 13 passes**, drift=0, on a fixture that can now actually
show drift. Read both sections above before touching cases 15 or 17. The `nviol()` defect found
alongside them made case 15's success condition unreportable until 2026-09-03.

**navi and the plan gate remain CUT and DEFERRED.** The CLI now permits their A/Bs, but
permitting is not measuring, and the issue's decision rule turns on the measurement.
Do not build either until its A/B has run.

Do not close the issue until the remaining nine are either met or explicitly waived by the author.
