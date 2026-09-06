#!/usr/bin/env bash
# headless.sh — the shared transport every acceptance harness talks to the model
# through. Sourced, never executed.
#
# WHY THIS EXISTS
#
# `claude -p` in text mode prints only the FINAL assistant message. The triforce
# plugin ships a Stop hook (hooks/hooks.json), and `--plugin-dir "$ROOT"` loads
# it into every headless audit we run. So the reviewer emits its roll-call and
# its <<<VIOLATIONS ... VIOLATIONS>>> block, tries to end its turn, the plugin's
# own Stop hook fires inside that session, and the reviewer writes a SECOND
# message answering the hook -- "Audit already terminated; I will not re-open
# it." Text mode then hands us that reply and throws the audit away.
#
# The artifact was never lost. The transport discarded it. Observed replies
# quoted the hook's own vocabulary ("hook feedback", "audit-record obligation"),
# which appears nowhere else, and one run went four assistant messages deep.
#
# This is a measurement defect, not a reviewer failure, and it is the cause of
# every otherwise-unexplained UNMEASURED: probe-harness case 6's "2 of 4 runs",
# case 13's first run, and clean-corpus's two UNREVIEWABLE rows -- the ones
# recorded as "transient infrastructure failures" that "reproduce clean in
# isolation". Non-deterministic because the hook's own judgement varies.
#
# The fix is transport-only: ask for stream-json, which returns EVERY message,
# and read the assistant text out of all of them. Nothing about the hook, the
# plugin, or the reviewer's prompt changes -- so this cannot flatter a result.
# It can only stop us discarding one.

# An interpreter that actually RUNS -- the same probe as gate.sh, because on
# Windows `python3` is often a Store alias stub that fails on execution.
HL_PY=""
for _c in python python3 py; do
  if command -v "$_c" >/dev/null 2>&1 && "$_c" -c "print(1)" >/dev/null 2>&1; then
    HL_PY="$_c"; break
  fi
done

# hl_transcript — stdin: stream-json lines. stdout: assistant text, in order.
# Refuses rather than emitting nothing it did not earn: a silent empty string
# here would read downstream as "the reviewer found nothing", which is the
# INVARIANT 10 failure this whole file exists to prevent.
hl_transcript() {
  if [ -z "$HL_PY" ]; then
    echo "headless: no working python interpreter; cannot read the transcript" >&2
    return 2
  fi
  "$HL_PY" -c '
import json, sys
out = []
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except Exception:
        continue
    if d.get("type") != "assistant":
        continue
    for b in d.get("message", {}).get("content", []) or []:
        if isinstance(b, dict) and b.get("type") == "text":
            out.append(b.get("text") or "")
sys.stdout.write("\n".join(out))
'
}

# hl_claude — stdin: the prompt. args: passed through to claude.
# Returns the full assistant transcript rather than the last message.
# HL_KEEP_STDERR=1 folds stderr into the transcript, which probe-harness wants
# for diagnosing a dispatch that never happened.
hl_claude() {
  if [ "${HL_KEEP_STDERR:-0}" = "1" ]; then
    timeout "${HL_TIMEOUT:-600}" claude -p --output-format stream-json --verbose "$@" 2>&1 \
      | hl_transcript
  else
    timeout "${HL_TIMEOUT:-600}" claude -p --output-format stream-json --verbose "$@" 2>/dev/null \
      | hl_transcript
  fi
}

# hl_first_block — stdin: transcript. stdout: the FIRST <<<VIOLATIONS block's
# body, markers stripped. First, because a hook exchange can make the reviewer
# restate its array in a later message, and a range match across both would
# splice two arrays into one malformed document.
hl_first_block() {
  awk '/<<<VIOLATIONS/{f=1;next} f&&/VIOLATIONS>>>/{exit} f'
}
