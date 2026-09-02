# Preflight — the risk score and the tier

The tier is computed **before any reviewer is spawned** and printed as a non-renegotiable preflight
card. Nothing downstream may lower it.

## Design constraints

**Additive, never multiplicative.** A product zeroes out exactly the case that matters most: a
four-line change to an auth guard scores near zero on spread, churn and fragmentation, so any
multiplicative combination drives the whole score to nothing. Components are summed, each capped
independently.

**Categorical floors raise only.** A floor can promote a tier. Nothing demotes one. There is no code
path in `risk-score.sh` that lowers a tier.

**Unknown never reads as LOW.** Shallow history yields the neutral mid value, not zero. A repo we
cannot characterise is not thereby safe. The same rule applies to churn when the touched files
cannot be measured (all-new or all-deleted files): neutral mid, never zero.

## The nine signals

| # | Signal | Cap | Notes |
|---|---|---|---|
| 1 | spread | 12 | files touched |
| 2 | **relative** churn | 15 | changed lines / total lines of touched files. Absolute churn is a poor predictor; only churn normalised by component size discriminates. |
| 3 | fragmentation | 10 | hunks per file |
| 4 | interface change | 12 | exported/public signature touched — **floor T2** |
| 5 | danger domains | 15 | by path *and* content — **floor T2**, or **T3** at two or more distinct domains |
| 6 | guard deletion | 14 | net removed guards; a removed check is not the same as an added one — **floor T2** |
| 7 | boundary/arithmetic | 10 | comparisons, increments, indexing, length/offset/limit |
| 8 | test gap | 12 | production code moved, tests did not. Suppressed when no executable line moved. |
| 9 | history | 10 | prior revert/hotfix/regression commits over these paths; **floored to a neutral 5 when history is shallow** |

Sum, then clamp to 100.

## Thresholds

```
T0   the audit does not run   (zero model calls)
T1   score < 35
T2   score < 60
T3   score >= 60
```

Then categorical floors are applied. They raise only.

## How T0 is reached

T0 keys on the **content class of the change**, not on the accumulated score:

- an empty diff, or
- no categorical signal *and* nothing executable moved (comment-only, whitespace-only, docs-only), or
- no categorical signal *and* score < 12 *and* fewer than 25 changed lines.

The content-class route matters. Without it, the shallow-history neutral mid (5) plus the test gap
(6) put a one-line comment reword at 11 points before anything else is counted, and T0 becomes
unreachable in any repo with a short history. Every cost claim for a required gate rests on the tier
distribution being T0/T1-heavy, so an unreachable T0 is a cost bug, not a rounding error.

**Instrument the tier histogram from week one.** If the real corpus skews T2/T3, this is the number
that will hurt.

## What preflight checks besides the score

| Check | Why it blocks |
|---|---|
| `worktree.baseRef == "head"` | Unset or `fresh` means executors branch from the **default branch**, not the orchestrator's work — and the run still looks entirely normal. A plugin cannot write a user's settings.json, so this is a verified prerequisite. |
| `CLAUDE_CODE_SUBAGENT_MODEL` unset | It outranks agent frontmatter in model resolution, so every pin and the whole cost design are silently overridden. |
| version from `claude --version` | **Never** `CLAUDE_CODE_VERSION`, which has been observed carrying a malformed value (2.1.42) predating features the environment demonstrably has. |
| spawn depth | Reported, not blocked. `context: fork` does not consume a level, so depth 1 costs only navi. |
| `.worktreeinclude` | Warned when the repo has `.env`-ish files. A worktree is a fresh checkout; gitignored files are absent and tests that need them fail confusingly. |

Exit 1 = blocking, stop. Exit 2 = preflight could not run, stop. Only exit 0 proceeds.

`--allow-unsafe-base` downgrades the `baseRef` block to a loud warning. It exists for scripted
testing and for users who understand the consequence. The orchestrator never passes it on its own
initiative.

## Effective false positives

Track Google's definition — **a true finding nobody acted on is a false positive** — over rolling
windows of 10 audits. Warn at 5%. Above **10%**, auto-tighten the confidence bar and say so on the
preflight card. This is a direct port of Tricorder's disable action, whose policy is that analyzers
exceeding a 10% not-useful rate get turned off.

That definition is the point: it removes the reviewer's "but it was technically true" defence.
