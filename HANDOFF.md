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
bash acceptance/run.sh                    # DONE — 93 checks green, offline, must stay green
bash acceptance/clean-corpus.sh           # DONE — case 11, THE GATE: 91% (11/12), cleared
bash acceptance/probe-harness.sh          # PARTIAL — case 2 green, then hits the line-55 bug
bash acceptance/live-cases.sh --case 12   # NOT RUN — idempotence
bash acceptance/live-cases.sh --case 13   # NOT RUN — fix-and-re-audit, the literal complaint
bash acceptance/live-cases.sh --case 15   # NOT RUN — floor ablation
bash acceptance/live-cases.sh --case 17   # NOT RUN — THE FALSIFIER
```

Then, still to be **built**, not just run:

1. **navi** — needs CLI ≥ 2.1.219 first. Build it, run the A/B, then apply the decision rule below.
2. **The plan gate's four arms** — (i) in-context self-critique, (ii) fresh zelda subagent,
   (iii) fresh + ganondorf, (iv) fresh + ganondorf as a **delete-only refuter**.
3. **Setup-from-a-clean-machine** verification, following only the README.
4. **Case 16**, effective false positives over rolling windows — genuinely cannot be done yet; it
   needs production audits to accumulate.

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

- **`probe-harness.sh:55` writes to `src/app.js` in a sandbox that has no `src/`.**
  The redirect fails, `git commit -qam` then has nothing to commit, its failure is
  swallowed by `>/dev/null 2>&1`, and `ORCH_COMMIT` silently becomes the *previous*
  HEAD. Case 3 would then assert that an executor can see a commit that was never
  created. **Not yet fixed.** Case 2's checks pass before this point; 3–6 are
  unverified rather than failing.

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
- **`acceptance/run.sh`** — **93** checks (89 + 4 guarding the extraction defect),
  offline, currently green. Keep it green.
- Installed as `triforce@cookiesncache-marketplace`, **~694 tokens always-on** (the recorded baseline).

## Definition of done — current state

**2 of 10 met.** `Tier 1 checks pass` ✅ and `clean-return rate ≥ 70%` ✅ (91%, 11/12).

Nothing is blocked on access any more — all three environmental blockers are cleared.
The remaining eight are blocked on **work**, not permission, except case 16, which
needs production audits to accumulate. The next session can run cases 12, 13, 15 and 17
immediately; fix `probe-harness.sh:55` first if cases 3–6 are wanted.

**navi and the plan gate remain CUT and DEFERRED.** The CLI now permits their A/Bs, but
permitting is not measuring, and the issue's decision rule turns on the measurement.
Do not build either until its A/B has run.

Do not close the issue until the remaining nine are either met or explicitly waived by the author.
