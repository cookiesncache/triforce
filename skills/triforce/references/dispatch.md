# Dispatch — what crosses the boundary

## The four invariants

1. **Every executor dispatch is isolated** — always, not only when fanning out. Serial dispatch is
   fan-out of one, so there is one dispatch path rather than two that drift apart.
2. **Executors base off the orchestrator's state**, not the repository's default branch. This
   requires `worktree.baseRef: "head"`, which resolves to *zelda's worktree's* HEAD.
3. **zelda is the sole merge point.** Executors never merge into each other, never write the main
   checkout, never target the default branch.
4. **Isolation is torn down at terminal state** — including, and especially, on success.

## What link receives

Subagents start cold. Everything it needs must be in the packet:

```
TASK        one task, stated as an outcome, not a procedure
CONSTRAINTS what it must not change; conventions to follow
FILES       the paths that matter, and why each one is listed
TESTS       the exact command to run, and what passing looks like
DONE        how link knows it is finished
```

Do **not** include: the plan in full, the audit criteria, other executors' work, or the
conversation. A packet that carries the whole plan invites the executor to re-plan.

## What link returns

```
BRANCH   <branch name>
COMMITS  <sha  subject>
FILES    <path>  +added/-removed
TESTS    <command>  ->  PASS | FAIL | NOT RUN (why)
SCOPE    asked-for work NOT done, and why
BLOCKED  what stopped it, or NONE
```

`SCOPE` is where an executor reports things it noticed but did not touch. That is the correct
destination for them — an executor that widens its own scope produces a diff nobody can review
against a plan.

## Parallel vs serial — the orchestrator's call

- **Parallel** when sub-tasks are genuinely independent: disjoint files, no ordering dependency,
  no shared interface being defined by one of them.
- **Serial** when a task defines something later tasks build on, when sub-tasks touch overlapping
  files, or when unsure.
- **Default to serial.** A wrong serial call costs wall-clock; a wrong parallel call costs a messy
  merge and an unreviewable diff.

Do not implement a concurrency ceiling. `CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS` is user config and
the harness already enforces it.

## Reactive escalation, never predictive

A **failed** dispatch — tests fail, build breaks, or zelda rejects at merge — may be retried one
model tier up. That is exogenous evidence of difficulty, consistent with the exogenous-trigger
discipline everywhere else in this design.

Choosing a higher tier up front because a task *looks* hard is predictive tiering, and it is a
self-report from the party whose plan is being executed. The risk score measures **consequence of
being wrong**, not **difficulty of doing it right**, and those come apart: a one-line change to an
auth guard is maximum consequence and minimum difficulty.

## Command shape inside isolation

The isolation checker blocks commands whose shape it cannot trace, and **this cannot be disabled**:

- heredocs with unquoted delimiters (`cat > f <<EOF`)
- brace expansion (`mkdir -p src/{a,b}`)

Executor prompts must steer to the `Write` tool for file contents and plain separate commands for
everything else.

## Teardown

The harness will not do this. Auto-cleanup fires only for agents finishing with **no changes**, and
the periodic sweep skips any worktree holding changed files or unpushed commits — a merged but
unpushed executor branch qualifies as "holds work" indefinitely.

- Remove executor worktrees after a successful merge: `git worktree remove` (`--force` if needed).
- **Never remove a worktree with uncommitted work or an unnamed branch.** Removal leaves the branch,
  so committed work survives; uncommitted work does not.
- **Retain failed executors** for inspection. Cleanup is terminal-state-aware, not indiscriminate.
- Worktrees are locked while their agent runs; tear down after completion.
