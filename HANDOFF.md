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

**"Cleared" means fixable, not fixed-forever. Auth expired again mid-session on 2026-09-06**,
between one set of live runs and the next, and killed three dispatches. Two things about it are
worth having written down:

- **The credential file had NO refresh token** (`claudeAiOauth.refreshToken` absent), which is
  precisely why the message is *"OAuth session expired and could not be refreshed"*. There is
  nothing to refresh with, so the session cannot self-heal and waiting does not help. `/login` in
  an interactive session is the only fix.
- **It presents differently depending on the shell, and one presentation is not an auth failure at
  all.** PowerShell's `bash` is `C:\WINDOWS\system32\bash.exe` — **WSL** — where `claude.exe` is not
  on PATH, so `timeout` reports *"failed to execute process: No such file or directory"*. That is a
  missing binary, not a missing credential, and `/login` cannot fix it. Adding the Windows directory
  to WSL's PATH does not fix it either: `claude.exe` cannot resolve `/mnt/c/...` paths. **Run the
  harnesses from Git Bash.** Both conditions were true simultaneously on 2026-09-06 — WSL could not
  find claude, and Git Bash found it but was unauthenticated — which is exactly how this wastes an
  hour. All three harnesses now diagnose the two separately.

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
bash acceptance/run.sh                    # DONE — 197 checks green, 5/5 suites, exit 0.
                                         #   Verified at the committed tip, 2026-09-06.
                                         #   Must stay green.
bash acceptance/clean-corpus.sh           # DONE — case 11, THE GATE: 91% (11/12), cleared
bash acceptance/probe-harness.sh          # 6/6 + 1 UNMEASURED, PROBE_EXIT=0 (2026-09-06)
                                         #   Case 6 MEASURES the property now, after its
                                         #   fixture was fixed. It is NON-DETERMINISTIC:
                                         #   two runs the same day, one PASS one FAIL.
                                         #   Read its section before quoting either.
bash acceptance/live-cases.sh --case 12   # FAILS, and now CHARACTERISED — 2026-09-06. The
                                         #   leak is a RELABEL, not a new citation: 1 relabel,
                                         #   0 new. Bounded population, unstable labels. Still a
                                         #   FAIL, but a different and smaller one than "the
                                         #   schema is leaking". Section below.
bash acceptance/live-cases.sh --case 13   # PASSED — 2026-09-03, drift=0, verifier enum clean.
                                         #   Its FIRST pass that day was VACUOUS (empty round-2
                                         #   diff); fixture fixed, this is the real one. n=1.
bash acceptance/live-cases.sh --case 15   # PASSED — 2026-09-06, n=4, on a REAL ablation.
                                         #   no-floor=0 in 4/4 runs; floor=1,1,1,2. The floor
                                         #   manufactures false positives on a clean diff, and
                                         #   pre-gate == post-gate every time, so THE GATE DOES
                                         #   NOT REMOVE THEM. Cause A confirmed. The earlier
                                         #   "inconclusive" was an untreated arm; see below.
bash acceptance/live-cases.sh --case 17   # NOT FALSIFIED — 2026-09-06, n=3 on the django
                                         #   corpus, 2 hosts. (b) never beat (a): 2 ties, 1 loss.
                                         #   The ceiling is gone and the clause held. Arm (c) is
                                         #   INCONSISTENT: 1 win, 1 loss, 1 tie. First false
                                         #   positives ever measured, and they are UNCHARACTERISED
                                         #   — read the section before quoting any F1.
```

Then, still to be **built**, not just run:

1. **navi** — the CLI blocker is gone (2.1.258 has the env var). Build it, run the A/B, then
   apply the decision rule below. Do not build it before the A/B.
2. **The plan gate's four arms** — (i) in-context self-critique, (ii) fresh zelda subagent,
   (iii) fresh + ganondorf, (iv) fresh + ganondorf as a **delete-only refuter**.
3. **Setup-from-a-clean-machine** verification, following only the README.
4. **Case 16**, effective false positives over rolling windows — genuinely cannot be done yet; it
   needs production audits to accumulate.

### Case 11 re-measured on the fixed transport — 2026-09-06

```
  clean-return rate, under-50-LOC band : 12/12  (100%)
  clean-return rate, all audited bands : 29/32  (90%)
  PASS — at or above the 70% bar.
```

Row tally: PASS=29  FINDINGS=3  UNREVIEWABLE=0  SKIPPED=8 (T0, counted in neither direction).

**What this establishes, and what it cannot.** The transport fix is transport-only and cannot
inflate a result -- it can only stop one being discarded. But this run **changed the transport
AND re-drew the corpus sample at the same time**, so any difference from the 2026-09-02 figure
is confounded by construction: a different draw of django commits would move the number on its
own. Read it as a fresh measurement on a working instrument, not as a delta against the old one,
and do not subtract the two.

**UNREVIEWABLE is the row that matters here.** It is the shape the Stop-hook defect produced, and
`clean-corpus.sh` counts it against the rate. Its count above is the evidence for or against the
hypothesis that the two rows recorded on 2026-09-02 (`1d50f129`, `febefb17`) were that defect.
Zero is consistent with the hypothesis; it is not proof, because those rows were always a
minority of a batch.

**100% in the headline band is the same shape as a number this file already retracted.** Treat
it with suspicion first. The retracted figure was **32/32 across all bands with zero findings
anywhere** -- degenerate, caused by the extraction defect scoring every audit as empty. This run
is not that:

- Three genuine `FINDINGS` rows survived the gate (`0398417c` 2, `d2e59b77` 2, `260d1369` 1), so
  the pipeline demonstrably still produces findings. A degenerate run cannot.
- All three sit at 123, 699 and 284 LOC -- **none in the under-50 band**. The small band reading
  12/12 is therefore consistent with small commits simply violating less, not with a reviewer
  that finds nothing.
- The all-bands rate is 29/32 (90%), not 100%.

**But do not report "100%" as the headline.** With `SMALL_TOTAL=12`, one audit is worth 8 points:
12/12 and 11/12 are one row apart and well inside the noise this metric carries. The honest
statement is "clears the 70% bar with room, on a 12-row band", which was already true at 91%.
The bar is what the design turns on, and the bar is cleared either way.

### THE HEADLESS TRANSPORT WAS DISCARDING AUDITS (found and fixed 2026-09-06)

**This plugin's own Stop hook was corrupting this plugin's own measurements.**

`claude -p` in text mode prints only the FINAL assistant message. `hooks/hooks.json` ships a
`Stop` hook, and `--plugin-dir "$ROOT"` loads it into **every headless audit the harnesses run**.
So the reviewer emitted its roll-call and its `<<<VIOLATIONS ... VIOLATIONS>>>` block, tried to
end its turn, the plugin's own Stop hook fired *inside that headless session*, and the reviewer
wrote a SECOND message answering it. Text mode handed back that reply and threw the audit away.

The marker-less replies name the hook in its own vocabulary, which appears nowhere else:

```
Audit already terminated; I will not re-open it.
Nothing in the hook feedback changes the artifact.
... no triforce merge, no executor work integrated, so no audit-record obligation applies here.
```

Measured, text mode vs `stream-json`, same prompt and fixture:

```
text mode:    3 calls -> 1 usable, 2 markerless   (and separately 2 of 3, and 3 of 3)
stream-json:  3 calls -> 3 usable, valid JSON, criterion ids recovered
```

One run went **four assistant messages deep**. The artifact was never lost; the transport
discarded it.

**The fix is transport-only.** `acceptance/headless.sh` is now the single place every harness
talks to the model: `hl_claude` asks for `stream-json` and returns the whole transcript,
`hl_transcript` decodes the assistant text, and `hl_first_block` takes the FIRST violations array
-- a hook exchange can make the reviewer restate it, and a range match across both splices two
arrays into one malformed document. Nothing about the hook, the plugin, the reviewer prompt or
the gate changes, so **this fix is structurally incapable of flattering a result. It can only
stop one being thrown away.** That property matters, because the correction runs in the design's
favour.

`hl_transcript` refuses rather than returning an empty string when it cannot parse: silence there
would read downstream as "the reviewer found nothing". INVARIANT 10 again.

Six offline checks cover it, including a synthetic hook-extended transcript, so the class cannot
regress without a live model to notice.

**What this explains, and what it does not.** Established: the mechanism is real, reproduced
offline, and demonstrably destroyed measurements. **Not established:** that it caused any
*specific* historical failure. Two candidates, to be judged on evidence rather than on how neatly
the story fits --

- `clean-corpus.sh`'s two `UNREVIEWABLE` rows (`1d50f129`, `febefb17`), recorded below as
  "transient infrastructure failures" that "reproduce clean in isolation". The signature matches
  exactly: markers absent in a batch, present on isolated re-run, non-deterministic.
- probe-harness case 6's "2 of 4 runs". **This one is now doubtful** -- a post-fix run failed
  again, for a different reason. See the lead below.

**The headline metric is a floor, not a ceiling.** `clean-corpus.sh` counts `UNREVIEWABLE`
against the rate (only `PASS` increments the numerator, while every audited row increments the
denominator). A discarded audit therefore read as a non-clean row: **91% (11/12) understates
rather than inflates.** Re-measured on the fixed transport; the result is recorded with it. Do
NOT adjust the recorded number by argument -- a 100% figure was already retracted once as an
artifact, and reasoning a better one back into existence is that same mistake in a new hat.

### Case 6 lead: link reported its own isolation had failed (2026-09-06, OPEN)

```
DISPATCHED=...worktrees/agent-a0f4857ec3974d5a9 (not a real git worktree — isolation failed)
TESTS_RC=not obtained — link correctly refused to run tests without genuine isolation
```

Case 6 is UNMEASURED again, and **the transport fix did not resolve it** -- so the "2 of 4"
flakiness was not simply the Stop hook. Case 6 has now failed for three distinct stated reasons
across sessions: the model declined a fabricated result; the model declined an artifact-planting
framing; and now this.

Read it carefully before alarm:

- Cases 2-5 measure isolation **directly** and all passed in the SAME run, including the worktree
  path and a clean teardown.
- Case 6 is the only dispatch carrying `--allowedTools Bash Agent Write` and
  `--permission-mode acceptEdits` -- the only **write** task. Cases 2-3 are read-only.
- The safety property HELD. link detected the problem and **refused to run** rather than writing
  into the main checkout. That is the executor behaving correctly.

So the likely reading is that worktree *setup* failed for that one dispatch, not that isolation
is broken. But that is a hypothesis about an agent's **self-report, which is data and not ground
truth**, and it is unresolved. Case 6's retention check cannot be measured until a write dispatch
gets a real worktree. Investigate before trusting a case 6 result in either direction.

### Case 6 measures the property now — and it is NON-DETERMINISTIC (2026-09-06)

**The earlier "not a real git worktree" lead did not reproduce and is downgraded.** Two
diagnostic dispatches of case 6's exact shape against fresh scratch repos both got a REAL
worktree: `git rev-parse --show-toplevel` and `--git-dir` resolved under `.claude/worktrees/`,
`.git` present. Not closed — two runs cannot prove a non-deterministic self-report never happens —
but it is no longer the leading explanation.

**What did reproduce is the fixture.** `src/account.js` — the file case 6's task tells link to
edit — was never created by the fixture. link is instructed to stop rather than reconstruct a
missing file by guessing, so whether it invented the file was a model judgement call. Measured
both ways: one dispatch created it and committed, an identical one reported `BLOCKED` and changed
nothing. The second path leaves an unchanged worktree, **the harness auto-removes those by
design**, and case 6 scored that documented behaviour as "cleanup is indiscriminate".

That dispatch cleared **both** of case 6's existing guards — it reported `DISPATCHED=` and
`TESTS_RC=1` — while committing nothing. So the fixture creates the file, and case 6 now requires
verified proof that work existed: the executor reports its commit sha and the sha is checked with
`git cat-file -e` rather than believed. A self-report is data, not ground truth, and the object
outlives the worktree and branch that cleanup removes.

**Two runs the same day, opposite outcomes:**

```
run 1   FAIL  worktree removed; commit 420725f verified present in the object store
run 2   PASS  worktree retained at agent-acb13014..., work at 3353fac on its own branch
```

**Both are real measurements** — the commit was verified before either verdict. Retention is
therefore **not established and not refuted**. Do not quote either run alone. The runs differed in
one visible way: case 3 was UNMEASURED in run 2 (the model declined the dispatch as zelda-only),
so one fewer worktree existed beforehand. That is a hypothesis about sweep timing, not a finding.

An absent worktree now resolves into four states rather than one, because they are not the same
finding and the first FAIL did not distinguish them:

| state | verdict |
|---|---|
| present | **ok** — retained for inspection |
| absent, work MERGED into the orchestrator's branch | **UNMEASURED** — a success state, so this is case 5's property, not retention. A pre-existing suite failing is not the executor's own task failing |
| absent, unmerged, branch survives | **FAIL**, lesser — work recoverable, inspection lost |
| absent, unmerged, no branch | **FAIL**, strong — the work is ORPHANED |

Run 1's FAIL predates this grading, so which of the last two it was is unknown. The next FAIL will
say.

### Case 15 is UNMEASURABLE as specified — the floor cannot reach the reviewer (2026-09-06)

The 2026-09-03 result was `floor=0 vs no-floor=0`, and the hypothesis was that a six-line clean
function gave a floor nothing to invent about. **That hypothesis is dead.** The clean corpus was
enlarged roughly eightfold — five functions, 50+ added lines, C1 kept live rather than irrelevant —
and the result is byte-identical: `post-gate: no-floor=0 floor=0 | pre-gate: no-floor=0 floor=0`.

The floor arm produced **zero findings pre-gate**. The reviewer did not invent three findings and
have them gated away; it refused the floor outright. The reason is in the reviewer's own contract,
which `--agent ganondorf-t2 --plugin-dir` loads into every one of these audits:

> There is no minimum number of findings. There is no target. There is no expected count, no
> typical range, and nothing about a low count that reflects on the quality of your review.

> Generating a candidate you cannot ground in the diff is the single worst outcome available to
> you

> Nothing about this number implies a floor, and there is no floor.

**So the "floor arm" is not an ablation.** It is a conflict test between one line appended to a
user prompt and a system prompt written specifically to reject exactly that line — and the system
prompt wins. Case 15 cannot measure Cause A this way no matter how the corpus changes, which is
why enlarging it changed nothing.

**This is not a null result about the floor.** It is the experiment failing to apply the
treatment. Reporting `floor=0 vs no-floor=0` as evidence about finding floors would be reading a
harness limitation as a fact about the design.

A real ablation has to remove the anti-floor contract and install a floor **in the agent
definition**, then run that variant against the same clean diff — one changed thing, in the place
the instruction actually lives. It must be built in a THROWAWAY plugin copy: INVARIANT 1 says no
finding floor anywhere in the shipped plugin, and building the counterfactual you measure against
is not the same as shipping it.

### That ablation was built, and Cause A is confirmed — n=4 (2026-09-06)

The floor arm now loads a patched contract from a throwaway plugin copy under `$WORK`, removed on
exit. Four runs against the same clean diff:

```
run 1   no-floor=0   floor=1        (pre-gate identical to post-gate)
run 2   no-floor=0   floor=1
run 3   no-floor=0   floor=1
run 4   no-floor=0   floor=2
```

**4/4, no overlap between the arms.** A genuinely clean diff returns zero findings under the
shipped contract and 1–2 findings under a contract carrying a floor. Those are manufactured false
positives, and **floor removal is the mechanism for Cause A.**

**The most consequential number here is that pre-gate equals post-gate in every run.** This file
previously contemplated "the floor manufactured findings and the GATE removed them" as a possible
branch. Measured, it does not: every manufactured finding survived gating. **The gate is not a
backstop for floor-induced false positives** — expected, since `SAFETY = {S1..S6}` is cap-exempt,
but now measured rather than assumed. Removing the floor is not one of two redundant defences; it
is the only one.

**Read the effect size honestly.** The floor demanded *at least 3* and got 1 or 2. The reviewer
partially resists a floor even when the floor is in its own contract, so the treatment is not
fully potent and the measured 1–2 is a floor on the harm, not a ceiling. And the treatment was the
**whole Anti-fabrication section**, not one sentence — replacing only "there is no minimum number
of findings" leaves "generating a candidate you cannot ground in the diff is the single worst
outcome available to you" standing, which is the same instruction in different words, and the arm
would read as treated while still being a control. Two hunks, both verified before any audit runs.

**What made the earlier result wrong was not the corpus.** Enlarging the clean diff eightfold
changed nothing, because the arm was never treated. Keep that in view when reading any future
tie: this case has now produced an uninformative tie twice, for two different reasons, and neither
was about finding floors.

### Arm (c) is sequential now, and arm (d) is named rather than built (2026-09-06)

**Decided with the user, not invented.** Arm (c) had been byte-identical to arm (a) — K independent
audits unioned — and the previous session logged that as owed work rather than guess the semantics.

**Arm (c) = chaining.** Round n+1 is told which criteria round n cited and asked to look for what
it missed. That is the plain reading of "K sequential", and it isolates ONE variable.

**The empty-array escape in that prompt is load-bearing.** "Report only what the previous reviewer
missed" is one careless sentence from a finding floor; INVARIANT 1 forbids a floor *in any prompt*,
and case 15 has now measured a floor manufacturing false positives on a genuinely clean diff. The
instruction states that missing nothing is a complete and correct answer.

**Arm (d) — a round that may WITHDRAW an earlier finding — is deliberately not built.** It was
considered and declined for now on four grounds:

- It changes **authority as well as chaining**, so beating arm (a) would not say which caused it.
  Arm (c) isolates chaining; arm (d) belongs beside it, not inside it.
- "K sequential" in the issue means sequential rounds, not a revision pass. Building it as arm (c)
  would answer a question the issue did not ask while looking like it answered the one it did.
- A reviewer that deletes its own findings is a second, model-driven deletion path beside the gate,
  and "withdrew a finding" is indistinguishable from "crashed mid-revision and emitted a shorter
  array". That is a fresh way to manufacture a false clean and would need its own guard.
- **Decisively: there is nothing to withdraw.** FP=0 in every arm of every run so far. Its only
  distinct mechanism is removing false positives, and none have ever appeared.

It is **gated on a corpus that produces false positives**, and it is named in case 17's own output
so its absence reads as a decision rather than an oversight.

### The django-seeded corpus for case 17 (2026-09-06)

The hand-built fixture is saturated — 5/5, FP=0, three runs — so it cannot falsify anything. This
corpus keeps ground truth knowable while making the search realistic:

- **base** = a real django commit's parent state, **head** = that commit **plus** seeded defects.
  django's own changes become the noise a single round has to search through.
- Four seeded defects, idiomatic django antipatterns, one per criterion: **S1** an off-by-one that
  drops the first element, **S2** an unconditional `.all().delete()`, **S4** two `.save()` calls
  with no transaction, **S6** a read-modify-write on a counter.
- Truth is **the seeded defects only**. C1 is the host commit's own subject, which the host
  satisfies, so **C1, S3 and S5 are clean** and citing any of them is a real false positive.
- Opt-in: `--corpus django --repo <clone> --host <sha>`. The self-contained fixture stays the
  default so a bare `--case 17` still runs with no external repo, and a missing clone or host is
  **UNMEASURED**, never a silent fall back to the easy corpus.

**THE HOST MUST BE A COMMIT THE REVIEWER RETURNS CLEAN ON, UNSEEDED.** Otherwise its own legitimate
findings score as false positives against a truth set that only knows the seeded defects, which
penalises whichever arm searched hardest — the same bias that adding S4 removed from the hand
fixture. Four candidates were measured before any was used; **all four came back clean**, and the
two large enough to use are:

```
f30acb18  Fixed #12090 -- Added admin actions to the admin change form.       308 lines, 5 files
804660d6  Refs #28800 -- Lifted some url functions from admindocs into urls.  272 lines, 3 files
```

Those baselines were audited over ALL the commit's `.py` files including tests, while case 17 uses
library files only — a superset drew no findings, so the subset is conservative.

**One bug was caught before it produced a number.** The seeding cycled over FILES, one defect each.
On a two-file host that seeded two defects while the truth claimed four, so two criteria were
unreachable and recall was capped at 2/4 **by the fixture** — and it would have looked exactly like
the reviewer missing things. It now iterates over the defects and cycles files. The first django
run was killed rather than reported.

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

### Case 12's leak is a RELABEL, not a schema leak (2026-09-06)

Case 12's FAIL said "the schema is leaking" — an unbounded population. That was asserted from
criterion ids, and **the ids cannot support it**. A criterion new to round 2 is either a new
citation or the same defect wearing a different label, and those are different findings about the
design. Case 12 now compares **spans**:

```
  FAIL  idempotence: 1 blocking criterion(s) appeared only on the second run
        S4
        S4 at src/account.js:3 — round 1 already cited that span as [C1 S2 ].
          SAME DEFECT, DIFFERENT LABEL. Not a new finding.
        character: 1 relabel(s), 0 new citation(s).
```

**Every leaked criterion sat on a span round 1 had already cited.** The population is bounded; the
labels are unstable. This was predicted before it was measured: the S4-only probe had already shown
the reviewer cites **one criterion per defect**, with the label varying between runs, and this is
the same effect showing up as an idempotence failure.

**It is still a FAIL, and deliberately so.** A re-audit that renames a finding makes the same defect
look new to the user, which is the complaint case 12 exists to catch. But it is a *smaller* defect
than an unbounded population, and the write-up must say which one it is. When spans cannot be read,
the case reports the character as unmeasured rather than assuming the flattering reading.

### Arm (d) is built — and has never been run (2026-09-06)

Its gate condition opened when the django corpus produced the first false positives in this
measurement. Until then every arm scored FP=0, and a withdraw-capable round would have had nothing
to withdraw.

- **It REPLACES rather than unions.** Arm (c) unions its rounds, so a later round can only add.
  Arm (d)'s score is the revision round's output *alone*. Union arm (a) back in and a withdrawal
  becomes unobservable, which would make (d) a slower copy of (c).
- **It is a separate arm, never a variant of (c)**, because it changes authority as well as
  chaining, and beating (a) as one combined change would not say which half did it.
- **Its prompt leans neither way.** A floor manufactures false positives — INVARIANT 1, and case 15
  measured exactly that. Pressure to delete would manufacture false *cleans*, which INVARIANT 10
  cares about at least as much. The prompt states that restating the set unchanged and emitting an
  empty array are both complete answers.
- **A run where it withdrew nothing says nothing about withdrawal**, and it says so rather than let
  its F1 be read as evidence either way.

**NOT MEASURED.** Three offline checks guard its construction; none of them is a result. Run
`--case 17 --corpus django --repo <clone> --host <sha>` to get one, on a host verified clean first.

### The falsification is WITHDRAWN, and the two "false positives" split (2026-09-07)

`--verify-host` now audits the **exact diff case 17 audits, minus the seeded commit** — same base,
same files, same `audit()`, same criteria, one commit short — and the arms refuse to score a host
that has not passed it. That closes the guard defect of 2026-09-06, and it is the *smaller* half of
what today produced.

**The control alone could not settle this, and reading django could.** Two citations were being
scored as false positives. They are not the same kind of thing:

| citation | the reviewer's reason | the code | scored |
| --- | --- | --- | --- |
| `C1 admin_modify.py:158` | "extra positional arg shifts `InclusionAdminNode(parser, token)`" | **WRONG.** `InclusionAdminNode.__init__(self, name, parser, token, func, template_name, ...)`. The call passes `"change_form_admin_actions"`, `parser`, `token` positionally and `func`/`template_name` by keyword — the same shape as every other tag in that file. There is no extra positional arg. | FP — **correctly** |
| `S3 options.py:2087` | "change-form action queryset bypasses `get_queryset` scope" | **RIGHT, on my reading.** At `options.py:2108` the change-form POST path builds `queryset = self.model._default_manager.get_queryset()` and hands it to `response_action`, which does `queryset.filter(pk__in=selected)` with `selected = request.POST.getlist(ACTION_CHECKBOX_NAME)`. The changelist path (2349, 2375) passes `cl.get_queryset(request)` instead, which honours `ModelAdmin.get_queryset()`. So a ModelAdmin that scopes rows per user has that scope bypassed for attacker-supplied pks on the change-form path only. Still present at django HEAD `b3f4d83`; only a deprecation rename has touched those lines since. | FP — **wrongly** |

So on host `f30acb18` the truth set `{S1 S2 S4 S6}` is **wrong**: it scores a correct S3 as a false
positive. No F1 from that host is readable, and **both falsification branches of 2026-09-06 are
withdrawn — neither confirmed nor refuted.** Arm (d) dropped one invention and one correct finding;
whether that is a precision win cannot be read off a truth set that miscounts one of them.

The S3 reading is a judgement about third-party code, not a measurement. It is written out in full
above precisely so it can be overturned; if it is wrong, S3 is an ordinary false positive, the
2026-09-06 numbers stand as measured, and `f30acb18` should be requalified.

**The control is NECESSARY AND NOT SUFFICIENT, and that is the general lesson.** Unseeded, over 7
runs on `f30acb18`:

```
C1  cited in 2 of 7 runs   -> reproduces without the seeds. Not seed-caused. Enough on its
                              own to make the machine verdict DIRTY, at admin_modify.py:158
                              once and :157 the other time -- the span drifts, which is the
                              same instability case 12 characterises.
S3  cited in 0 of 7 runs   -> the control says NOTHING about it, and S3 is the one that
                              decides whether the falsification was real.
```

The citation that mattered is the one the control cannot see. A verification permits a host; it
does not vouch for one. The harness says so in its own output now, because a green line reading
"host returns CLEAN" is otherwise read as a guarantee it cannot give.

**An overwrite bug, caught in flight.** `f30acb18` cited C1 on a single-run verification, then
returned CLEAN three times in a row, then cited it again. A writer keeping only the last result
would have published `CLEAN 3/3` at the exact moment it was asked, and erased the finding. Rows now accumulate: runs sum, citations
union, and **DIRTY never decays** — cleanliness is the claim needing evidence, one citation refutes
it, and three quiet runs afterwards do not restore it.

**What is enforced now, instead of written down.** The host requirement had been a comment for
three days — "THE HOST COMMIT MUST BE ONE THE REVIEWER RETURNS CLEAN ON, unseeded" — while two of
the three django runs used a host nobody had checked, including the only run that fired the
falsifier. `acceptance/verified-hosts.tsv` holds the verdicts; only a `--verify-host` run writes a
data row, so the evidence and the permission are one artifact. A `#!DQ` line is a human
disqualification, outranks any verdict, and no run can clear it — that is where `f30acb18` now sits,
because the S3 problem is invisible to the machine check.

**Where case 17's django corpus stands: ONE USABLE HOST, AND THE QUESTION IS STILL OPEN.**

```
f30acb18   DIRTY (C1, 2 of 7 unseeded runs)  -- refused by the machine check alone
           DISQUALIFIED (S3)                  -- and by the reason the machine cannot see
804660d6   CLEAN 3/3                          -- usable
```

I first wrote this as "no usable host", on the grounds that arm (a) scores 1.000 on 804660d6. That
is one run of two. The other, from 2026-09-06, is this:

```
host       run   (a) F1   (b) F1   (c) F1   (d) F1
804660d6    1    0.857    0.857    1.000    (not built yet)
804660d6    C    1.000    1.000    0.857    1.000   <- ceiling, refused
```

So on the host that verifies clean, **the sequential arm beat one round once and lost once**, and
the loss is the run where (a) was at ceiling and nothing could have beaten it. One win against one
uninformative run is not a result, but it is not "no falsifying power" either — that reading came
from treating a single ceiling run as the host's behaviour.

**The next measurement is replication on 804660d6, not a search for a new host.** Arm (d) has still
never run against anything it could withdraw: on run C it correctly reported withdrawing nothing.

### Arm (d) ran, both falsification branches fired — and the result is CONTAMINATED (2026-09-06)

Three runs, two hosts. Arm (d) is the revision round: it may drop a finding as well as add one, and
its score is that round's output alone.

```
host       run   (a)     (b)     (c)     (d)     (d) dropped from (a)
f30acb18    A    0.667   0.667   0.800   0.857   [C1 S3]  added []
f30acb18    B    0.750   0.750   0.750   0.750   [C1]     added [S3]
804660d6    C    1.000   1.000   0.857   1.000   []       added []   <- ceiling, refused
```

**Arm (d) does what it was built to do.** In run A it dropped exactly the two false positives and
came back FP=0 — the only arm that can raise precision, doing so. Run C withdrew nothing and said
so, so its F1 is not evidence about withdrawal in either direction. The guards work.

**Both falsification branches fired for the first time**, in run A:

```
  FAIL  FALSIFIED BY THE SEQUENTIAL ARM: (c) F1=0.800 beats (a) F1=0.667.
  FAIL  FALSIFIED BY THE REVISION ARM:   (d) F1=0.857 beats (a) F1=0.667.
```

**DO NOT REPORT THAT AS A FALSIFICATION.** The citation text — printed for the first time on this
run, and built precisely for this — is about django's own code, so the truth set may be wrong.
(Read the 2026-09-07 section above before this one. "The false positives are probably not false",
as this section originally put it, was itself an overclaim: a citation landing on a django line is
not an adjudication of it. One of these two is false and one is true, and it took reading django
to tell which.)

```
  (a) C1  django/contrib/admin/templatetags/admin_modify.py:158 -- extra positional arg breaks change-form actions tag
  (a) S3  django/contrib/admin/options.py:2087 -- Change-form action queryset bypasses get_queryset scope
```

Those are claims about **django's own code**, cited at consistent line numbers across every arm and
every run. They are not obviously wrong, and if they are right they are TRUE POSITIVES scored as
false ones. Arm (d) then "won" by **dropping correct findings**, which is a false-negative win, and
arm (c) "won" partly on the same scoring.

**The host-verification guard was insufficient, and that is my error.** `dbase.sh` audited
`git diff -W SHA^..SHA -- '*.py'` — every python file including tests, with no seeded defects. Case
17 audits a **different diff**: library files only, with four defects appended. A clean result on
the superset does not certify the subset, and the seeded code changes how the reviewer reads the
whole diff. The guard checked the wrong artifact and it was recorded as if it checked the right one.

**Required before any of these numbers mean anything:**

1. Re-baseline each host on the **exact diff case 17 audits** — same file set, same base, seeded
   defects included — not a superset.
2. If `C1` at `admin_modify.py:158` survives that, the host is disqualified, or `C1` belongs in the
   ground truth. Either way the F1 column above is recomputed, not annotated.
3. Only then re-read whether (c) or (d) beat (a).

Run B is the control that makes the point: everything ties at 0.750 there, and (d) dropped `C1`
only to add `S3`. One run falsifies, one shows nothing, one is a ceiling. **n=3 across two hosts,
with a truth set now known to be suspect, is not a result.**

### Case 17 on the django corpus — the premise is NOT falsified (2026-09-06, n=3)

> **Two of these three runs are on host `f30acb18`, which was DISQUALIFIED on 2026-09-07 — its own
> diff violates `S3`, so its truth set scores a correct finding as a false positive. Those two rows
> are withdrawn. Only the `804660d6` row survives, and it is the one where arm (c) beat arm (a).
> The reasoning below about arm (c) being "one win, one loss, one tie" was computed across both
> hosts and does not survive either. See the 2026-09-07 section above.**

The first corpus on which the comparison had power. Three runs, two hosts:

```
host       run   (a) F1   (b) F1   (c) F1    cited by (c)
804660d6    1    0.857    0.857    1.000     S1 S2 S4 S6
f30acb18    A    0.857    0.750    0.667     C1 S1 S2 S3 S6
f30acb18    B    0.750    0.750    0.750     C1 S1 S2 S6
```

**The issue's clause holds, 3 of 3. Arm (b) never beat arm (a)** — two ties and one loss. A forced
extra *independent* round bought nothing anywhere, and in run A it bought a false positive. On the
issue's own decision rule the one-round premise stands, and the ceiling that made the previous
attempts meaningless is gone: arm (a) was imperfect in every run, so (b) had room to win and did
not.

**Arm (c), the chained arm, is INCONSISTENT — and my first reading of it was wrong.** On the first
host it found S4, which nothing else reached, and scored 1.000 against 0.857. That single run
looked like chaining beating parallelism on equal budget. It did not replicate: on the second host
it *lost* once (0.667 vs 0.857, adding two false positives) and tied once. **One win, one loss, one
tie is not an effect.** The harness now compares (c) against (a) explicitly, because the verdict
chain implements the issue's (b)-vs-(a) clause and was structurally blind to the arm that had beaten
the control — a falsifier that cannot see the winning arm is not a falsifier.

**False positives appeared for the first time anywhere in this measurement**, and they are the most
interesting result here. In run A the extra rounds bought pure invention: (b) added one FP, (c)
added two, and neither added a true positive. That is exactly the trade the design predicts — more
rounds buy invention rather than recall.

**But the false positives are UNCHARACTERISED, and they drive every F1 gap above.** The FP in 2 of 3
runs was **C1 — the host commit's own subject**. Whether a reviewer citing it is inventing, or
making a defensible call about how the seeded code interacts with what the commit claims to do,
cannot be told from `FP=1`. If those citations are defensible, the truth set is penalising whichever
arm searched hardest, which is the exact bias this corpus was built to avoid. Case 17 now prints the
FP ids; **a future run should retain the citation text**, and no F1 gap here should be leaned on
until that is done.

**Arm (d)'s gate condition is now met.** It was deferred because every measured arm scored FP=0 and
a withdraw-capable round would have had nothing to withdraw. That is no longer true — there are now
false positives on the table, so arm (d) has become measurable. It is still not built.

**What this does not establish.** n=3, two hosts, K=2, four seeded defects of my own design. The
defects are mine and idiomatic, so they may be easier than real ones; the noise is real django, so
it is not. S4 was reached exactly once, by the chained arm, on one host.

### Case 17: the falsifier still cannot run, and now we know why (2026-09-06)

Three attempts today, three different reasons the comparison had no power. Read all three before
touching this case — each fix exposed the next obstacle, and the last one is not a bug.

**Attempt 1 — a harder corpus.** Five defects over three files, seven criteria, S3 and S5 clean so
precision could fall. Three runs, every arm identical: `C1 S1 S2 S6`, FP=0, **F1=0.889, a tie**.
Arm (a) missed one of five, so arm (b) appeared to have room and did not use it.

**That result is WITHDRAWN, and the reason matters more than the result.** The missed criterion was
S4, and I recorded two readings of it — a reviewer blind spot, or S4 and S2 being co-located on one
defect so that labelling those lines S2 made S4 unreachable. **The co-located reading is the one
that survived contact with evidence.**

Probed directly, with a fixture seeding a rollback failure and *nothing else* — two stores written
with no transaction, so a failed second write leaves the first standing, destroying nothing:

```
run 1: pre-gate=[C1]      post-gate=[C1]
run 2: pre-gate=[C1 S4]   post-gate=[C1 S4]
run 3: pre-gate=[C1]      post-gate=[C1]
```

**The reviewer can reach S4** (run 2), so the blind-spot reading is dead. What it does is cite
**one criterion per defect**, preferring the domain criterion when one fits: C1 in 3 of 3, S4 in 1
of 3. So a truth set that assigns two criteria to one defect caps recall *by construction*. The
0.889 tie was measured against a de facto ceiling of 4/5 that **I had built into the ground
truth** — a subtler ceiling than the saturation one it replaced, and just as fatal.

**Attempt 2 — give S4 its own defect.** The fixture now seeds the non-atomic migration as a sixth
defect in a fourth file, so every criterion in truth rests on a defect that is uniquely its own.
Three more runs:

```
  (a) K parallel, one round     findings=5  TP=5  FP=0  precision=1.000  F1=1.000
  (b) + forced second round     findings=5  TP=5  FP=0  precision=1.000  F1=1.000
  (c) K sequential rounds       findings=5  TP=5  FP=0  precision=1.000  F1=1.000
        cited by (a): C1 S1 S2 S4 S6
```

**UNINFORMATIVE — a ceiling again.** Arm (a) is perfect, arm (b) is arm (a) plus one audit, so
`b > a` is arithmetically impossible. The guard fired and refused to score it, which is the harness
working exactly as intended.

**The standing conclusion: the reviewer saturates hand-built seeded-defect fixtures at K=2.** Two
corpora, one eight times harder than the other, both ended in a ceiling. This is not a result about
the one-round premise. **It is a statement about what a hand-seeded fixture can measure**, and no
amount of adding defects of this kind will change it — each new defect gets found too.

**Do not read any of it as corroboration.** A ceiling is not evidence for the premise; it is the
absence of evidence either way, and this file has already retracted one number for exactly that
confusion.

**What the falsifier would actually need**, and why it is hard: a corpus where a single round
genuinely fails. Two routes, neither free —

- **Drop K to 1**, so arm (a) is one audit against arm (b)'s two. Pilot single audits scored 3/5,
  3/5 and 4/5, so the headroom is real. But K is part of what the arm *means*, and changing it
  silently would answer a different question than the issue asks. **That is a decision for the
  user, not a fixture tweak.**
- **Real commits with real defects**, as case 11 uses. The obstacle moves from "can the reviewer
  find it" to "can ground truth be established", which is the harder problem and the reason the
  hand-built fixture existed in the first place.

**One genuine by-product, narrow but real:** 5 of 5 seeded defects found with **zero false
positives, three runs running, across four files**. That is a measurement about the reviewer. It is
not a measurement about rounds.

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

- **Never edit a harness while a background run of it is in flight.** Bash reads a script
  incrementally rather than loading it whole, so an edit lands under the running
  interpreter and it resumes at a byte offset that is now the middle of a different line.
  Two case-17 runs on 2026-09-06 printed their complete, correct measurement and then died
  with `syntax error near unexpected token` in the middle of a COMMENT, exiting 2. Nothing
  was wrong with the file — `bash -n` passed before and after. The trap is that the exit
  code says the harness is broken when the measurement is fine, and the reverse mistake is
  just as available: a real failure dismissed as "probably my edit". Let the run finish, or
  copy the script and run the copy.

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
- **`acceptance/run.sh`** — **197** checks (89 + 4 guarding the extraction defect,
  + 5 guarding the probe-harness fixture and the non-execution class, + 7 guarding the
  blocking-only population and the counters it rests on, + 2 guarding case 13's fixture
  against reproducing the base tree, + 3 guarding case 15's self-containment and its
  floor text, + 9 guarding the falsifier's ability to falsify, including a three-way
  test that drives its verdict chain to every outcome, + 3 guarding per-call pre-gate
  retention, + 6 guarding the headless transport against the Stop-hook defect,
  + 12 guarding case 17's corpus — the fixture is BUILT and each seeded defect matched
  against the ground truth that claims it, truth is checked to be a PROPER subset of the
  criteria, and the verdict chain is driven to a tie below the ceiling,
  + 4 guarding case 6's fixture and its proof that work existed before an absent worktree
  is read as a defect,
  + 5 guarding case 15's ablation, including the contract patch LIFTED AND RUN against
  the real agent file, because a treatment that silently stops applying is indistinguishable
  from a null result), offline, currently green. Keep it green.

  Every check added on 2026-09-06 was probed for vacuity by breaking the thing it guards.
  A green that could not have been red is worth nothing, and this file has already
  retracted one number for exactly that reason.
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
