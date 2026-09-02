# Criteria — sourcing, confirmation, freezing

**The orchestrator must not author the criteria.** An auditee that writes its own exam sets its
own blocking budget in both directions, and the bound `|blocking| <= |criteria|` collapses. This
is the single most load-bearing rule in the audit design.

## Where each kind comes from

| Kind | Source | Rule |
|---|---|---|
| `C*` coverage | The **user's own request text** | Transcribe, never compose. Each carries the span of their words it came from. If you cannot point at what they wrote, it is not a criterion. |
| `V*` verification | The plan's **pre-existing** `## Verification` section | It must pre-exist the audit as ordinary practice. Writing rows *for* the auditor is the failure mode this guards against. |
| `S1`-`S6` safety | Fixed closed set | Always present. Never edited, never extended, never dropped. |

## The six SAFETY criteria

```
S1  incorrect output or silently wrong result
S2  data loss or irreversible destruction
S3  security exposure
S4  failed or impossible rollback
S5  unbounded resource consumption
S6  concurrency or ordering hazard
```

Exactly six. Cap-exempt. Sort above every coverage criterion.

## Extraction

Read the user's request and pull out every statement that asserts something the finished work must
be true of. Keep their wording. Prefer a slightly awkward verbatim phrase over a tidy paraphrase —
the auditor must quote the criterion verbatim to cite it, so a paraphrase you introduce here
becomes a quote-match failure later.

Do not extract: pleasantries, context, background, or anything phrased as a preference rather than
a requirement. Do not invent a criterion because a category "should" be covered. A short criteria
list is a normal outcome for a small request.

## Confirmation — batched, never truncated

Confirm with `AskUserQuestion` before freezing:

- At most 4 options per question, at most 4 questions per call.
- **Loop over as many calls as the list needs.** If 11 criteria do not fit, they get another round
  of questions. They never get shorter.
- Multi-select keep/drop. The automatic "Other" option is how the user adds one you missed.
- Show the source span alongside each candidate so the user can see it is their own wording.

**Truncating the list silently shrinks the blocking budget**, which is the same failure as writing
the criteria yourself, arriving by a quieter route.

## The frozen file

One criterion per line, `<id><TAB><verbatim text>`, written to `.triforce/criteria.tsv`:

```
C1	the audit must run on every merge
C2	model pins must survive a model release
V1	acceptance script exits 0
S1	incorrect output or silently wrong result
S2	data loss or irreversible destruction
S3	security exposure
S4	failed or impossible rollback
S5	unbounded resource consumption
S6	concurrency or ordering hazard
```

`gate.sh` reads exactly this format, and the CRITERION check compares the auditor's quote against
this text with whitespace normalised and nothing else. A criterion containing a literal tab cannot
be represented; rewrite it.

## Freezing

Hash the file and record the hash in the ledger at first audit:

```
sha1sum .triforce/criteria.tsv
ledger.sh key <merge_base> <audited_tree> <criteria_hash>
```

The criteria hash is part of the ledger key, so changing the criteria starts a **new budget** —
correct, because it is a different audit. That is also the only legitimate way the budget resets.

**Never recompute the criteria.** Not after a fix, not at round 2, not when they turn out to be
inconvenient. If the auditor reports criteria that do not match its hash, the terminal is
`UNREVIEWABLE`, not a re-derivation.
