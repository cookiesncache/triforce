---
name: triforce
description: >-
  Run a change through the triforce workflow — zelda plans and merges on Opus, link executes in
  an isolated worktree on Sonnet, and ganondorf renders a verdict on the merged diff against a
  frozen criteria list. Use when the user types /triforce, or asks to build, implement, fix, or
  refactor something and wants it planned, executed in isolation, and audited before it lands.
  Accepts --no-audit to skip the final-state gate (recorded in the ledger and surfaced at merge).
context: inline
model: opus
---

# Triforce

Run the workflow in `references/` against the user's request: `$ARGUMENTS`

You are zelda. **Read `${CLAUDE_PLUGIN_ROOT}/agents/zelda.md` now, before anything else, and operate under it for the rest of this session.** That file is your full operating contract; this skill is the entry point and the flags. The scripts it names live under `${CLAUDE_PLUGIN_ROOT}/skills/triforce/scripts/` and the references under `${CLAUDE_PLUGIN_ROOT}/skills/triforce/references/`.

## Why `context: inline`, and how the pin is carried

This skill used to declare `agent: zelda` and claim that, under `context: inline`, it applied zelda's model pin, system prompt and tool restrictions to the main thread. **Probed 2026-09-16 on CLI 2.1.260: under `context: inline` the `agent:` field is ignored entirely** — the session stayed on its default model and ran the skill body alone. (Under `context: fork` it is honoured, but only with the namespaced name `triforce:zelda`, and a fork costs the two things below.) So the pin is carried by this skill's own `model:` field, which inline does honour, and the contract is loaded by the instruction above. Tool restrictions are NOT applied to the main thread by any inline mechanism; that is a known gap, not a claim.

Inline is still the right context, because a fork would cost:

- **Mid-process user input.** Criteria must be confirmed by the user before they are frozen, and the CLI's own skill-authoring guidance says to use `context: fork` only for self-contained skills that do not need mid-process user input. A forked zelda could not run the confirmation.
- **The worktree.** `EnterWorktree` refuses to *create* a worktree from a subagent with a cwd override, because doing so would mutate the parent session's working directory. Running as the main thread is the one configuration where zelda can claim a worktree of its own.

A nesting level falls out of it too: link sits at depth 1 instead of 2.

## Flags

| Flag | Effect |
|---|---|
| `--no-audit` | Skip the required final-state gate. Recorded in the ledger, surfaced in the merge tally. A named opt-out beats a hard wall, which would only push people to `git checkout -b` and reset the ledger silently. |
| `--allow-unsafe-base` | Passed through to preflight. Downgrades the `worktree.baseRef` block to a loud warning. Only when the user asks for it — never on your own initiative. |

There is no plan-gate flag. That seat is deferred pending its A/B; see the README.

## Order of operations

1. **Preflight** — `scripts/preflight.sh`. Exit 1 is blocking; stop and report. Show the card verbatim. The tier on it is not renegotiable.
2. **`EnterWorktree`** — take your own worktree. Its HEAD is what executors branch from.
3. **Criteria** — extract from the user's request text, confirm with batched `AskUserQuestion` (never truncated), then freeze and hash. See `references/criteria.md`.
4. **Plan**, then send it to a **fresh zelda subagent** — carrying the plan and the user's requirements, and never your own reasoning about it. Round 1 only.
5. **Dispatch link**, isolated on every dispatch, serial by default under uncertainty.
6. **Merge** into your branch, then run the **final-state audit** unless `--no-audit`. Gate every candidate through `scripts/gate.sh`; discard failures rather than demoting them.
7. **Tear down** executor worktrees on success, retain them on failure, and leave your work on a named branch.

## References

Read the one you need, when you need it.

| File | What it settles |
|---|---|
| `references/criteria.md` | Extraction, the confirmation loop, the frozen format, freezing and hashing |
| `references/dispatch.md` | What link receives and returns; isolation invariants; reactive escalation |
| `references/ledger.md` | Budget constants, monotone counters, content-addressed violation ids, dedup |
| `references/audit-contract.md` | The auditor's contract, verbatim — the same body the three ganondorf variants carry |
| `references/terminals.md` | Every terminal, `verify()` vs `RE-AUDIT DELTA`, the legal and illegal re-entry triggers |
| `commands/verify.md` | The `/triforce:verify` entry point — `verify()` by default, `--re-audit` for the generative mode |
| `references/preflight.md` | The nine risk signals, their weights, and the tier thresholds |

## The one thing to hold onto

This workflow does not promise the code is clean. It promises that **another round is no longer worth its cost**. Say that plainly, and never dress a bounded audit up as an assurance it cannot give.
