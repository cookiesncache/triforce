#!/usr/bin/env bash
# ledger.sh — the per-branch invocation ledger.
#
# This is what makes termination a proof rather than a hope. Every counter is
# monotone: a write that would decrease one exits non-zero and changes nothing
# on disk. Budget is checked BEFORE any work is dispatched, never after.
#
# Termination argument, in full:
#   audit() and verify() each increment a monotone integer and compare it to a
#   per-tier constant before doing any work. No path decrements any counter. No
#   path calls itself. REPAIR_INVOCATIONS = 0 closes the one uncounted loop —
#   malformed reviewer output is repaired by DROPPING it, never by re-asking.
#   Therefore invocations per ledger key are bounded above by
#   INVOCATION_CAP[tier] + GROUND_TRUTH_GRANT.
#
# Usage:
#   ledger.sh key <merge_base> <audited_tree> <criteria_hash>
#   ledger.sh vid <criterion_id> <normalized_span>
#   ledger.sh init <key> <tier> <audited_sha> <criteria_hash>
#   ledger.sh get  <key> <field>
#   ledger.sh can  <key> <counter>            exit 0 if budget remains
#   ledger.sh bump <key> <counter>            monotone +1, refuses over cap
#   ledger.sh seen-has <key> <violation_id>   exit 0 if already seen
#   ledger.sh seen-add <key> <violation_id>
#   ledger.sh waive    <key> <violation_id>
#   ledger.sh persist  <key> <file>           store the exact audited bytes
#   ledger.sh show <key>
#
# Counters: invocations_used, reaudits_used, verify_used, grant_used.
#
# No jq dependency: this script is the only writer of these files, so the JSON
# shape is fixed at one scalar per line and read back with sed.

set -uo pipefail

LEDGER_DIR="${TRIFORCE_LEDGER_DIR:-.triforce/ledger}"
AUDITED_DIR="${TRIFORCE_AUDITED_DIR:-.triforce/audited}"

# --- budget constants -------------------------------------------------------
cap_invocations() { case "$1" in 0) echo 0 ;; 1) echo 4 ;; 2) echo 6 ;; 3) echo 9 ;; *) echo 0 ;; esac; }
cap_hunt_k()      { case "$1" in 1) echo 1 ;; 2) echo 2 ;; 3) echo 3 ;; *) echo 0 ;; esac; }
cap_verify()      { case "$1" in 1) echo 2 ;; 2) echo 2 ;; 3) echo 3 ;; *) echo 0 ;; esac; }
REAUDIT_MAX=1
GROUND_TRUTH_GRANT=1
REPAIR_INVOCATIONS=0     # never raise this; it is the uncounted-loop closure

die() { echo "ledger: $*" >&2; exit 2; }

hash_of() { printf '%s' "$1" | sha1sum | cut -d' ' -f1; }

ledger_path() { printf '%s/%s.json' "$LEDGER_DIR" "$1"; }

require_ledger() {
  local p; p="$(ledger_path "$1")"
  [ -f "$p" ] || die "no ledger for key $1 (run init first)"
  printf '%s' "$p"
}

# read a numeric or string scalar out of our own fixed-shape JSON
get_field() {
  local p="$1" field="$2" v
  v=$(sed -n "s/.*\"$field\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",]*\)\"\{0,1\}.*/\1/p" "$p" | head -1)
  printf '%s' "$v"
}

write_ledger() {
  # write_ledger <path> <key> <tier> <audited_sha> <criteria_hash> <inv> <re> <ver> <grant>
  local p="$1" key="$2" tier="$3" sha="$4" ch="$5" inv="$6" re="$7" ver="$8" grant="$9"
  local seen waived
  seen=$(sed -n 's/^  "seen_keys": \(.*\)$/\1/p' "$p" 2>/dev/null | head -1)
  waived=$(sed -n 's/^  "waived": \(.*\)$/\1/p' "$p" 2>/dev/null | head -1)
  [ -n "$seen" ]   || seen='[],'
  [ -n "$waived" ] || waived='[]'
  {
    echo '{'
    echo "  \"key\": \"$key\","
    echo "  \"tier\": $tier,"
    echo "  \"audited_sha\": \"$sha\","
    echo "  \"criteria_hash\": \"$ch\","
    echo "  \"invocations_used\": $inv,"
    echo "  \"reaudits_used\": $re,"
    echo "  \"verify_used\": $ver,"
    echo "  \"grant_used\": $grant,"
    echo "  \"seen_keys\": $seen"
    echo "  \"waived\": $waived"
    echo '}'
  } > "$p.tmp" && mv "$p.tmp" "$p"
}

CMD="${1:-}"; shift 2>/dev/null || true

case "$CMD" in

  key)
    # Ledger key = sha1(merge_base | audited_tree_at_first_audit | criteria_hash).
    # Changing any of the three starts a new budget, which is correct: it is a
    # different audit. Nothing else may reset it.
    [ $# -eq 3 ] || die "usage: key <merge_base> <audited_tree> <criteria_hash>"
    hash_of "$1|$2|$3"
    ;;

  vid)
    # Violation ids are CONTENT-ADDRESSED, never a line or step number, so a
    # violation that MOVES is still recognised as the same violation.
    [ $# -eq 2 ] || die "usage: vid <criterion_id> <normalized_span>"
    norm=$(printf '%s' "$2" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
    hash_of "$1|$norm"
    ;;

  init)
    [ $# -eq 4 ] || die "usage: init <key> <tier> <audited_sha> <criteria_hash>"
    key="$1"; tier="$2"; sha="$3"; ch="$4"
    mkdir -p "$LEDGER_DIR"
    p="$(ledger_path "$key")"
    if [ -f "$p" ]; then
      # Re-init must never reset counters. Idempotent by design.
      echo "ledger: key $key already exists; counters preserved" >&2
      exit 0
    fi
    printf '{\n  "seen_keys": [],\n  "waived": []\n}\n' > "$p"
    write_ledger "$p" "$key" "$tier" "$sha" "$ch" 0 0 0 0
    echo "$p"
    ;;

  get)
    [ $# -eq 2 ] || die "usage: get <key> <field>"
    p="$(require_ledger "$1")" || exit 2
    get_field "$p" "$2"
    ;;

  can)
    # Budget check BEFORE work. Exit 0 = proceed, 1 = exhausted.
    [ $# -eq 2 ] || die "usage: can <key> <counter>"
    p="$(require_ledger "$1")" || exit 2
    counter="$2"
    tier=$(get_field "$p" tier)
    inv=$(get_field "$p" invocations_used)
    used=$(get_field "$p" "${counter}")
    invcap=$(cap_invocations "$tier")
    # The lifetime invocation ceiling dominates every per-counter cap.
    if [ "$inv" -ge $((invcap + GROUND_TRUTH_GRANT)) ]; then
      echo "BUDGET_EXHAUSTED_OPEN: invocations_used=$inv cap=$invcap+grant=$GROUND_TRUTH_GRANT" >&2
      exit 1
    fi
    case "$counter" in
      invocations_used)
        [ "$inv" -lt "$invcap" ] || { echo "BUDGET_EXHAUSTED_OPEN: invocation cap $invcap reached" >&2; exit 1; } ;;
      reaudits_used)
        [ "$used" -lt "$REAUDIT_MAX" ] || { echo "BUDGET_EXHAUSTED_OPEN: reaudit cap $REAUDIT_MAX reached" >&2; exit 1; } ;;
      verify_used)
        vcap=$(cap_verify "$tier")
        [ "$used" -lt "$vcap" ] || { echo "BUDGET_EXHAUSTED_OPEN: verify cap $vcap reached" >&2; exit 1; } ;;
      grant_used)
        [ "$used" -lt "$GROUND_TRUTH_GRANT" ] || { echo "BUDGET_EXHAUSTED_OPEN: ground-truth grant already used" >&2; exit 1; } ;;
      *) die "unknown counter: $counter" ;;
    esac
    exit 0
    ;;

  bump)
    [ $# -eq 2 ] || die "usage: bump <key> <counter>"
    p="$(require_ledger "$1")" || exit 2
    counter="$2"
    "$0" can "$1" "$counter" >/dev/null 2>&1 || {
      echo "ledger: refusing to bump $counter — budget exhausted" >&2
      exit 1
    }
    tier=$(get_field "$p" tier)
    sha=$(get_field "$p" audited_sha)
    ch=$(get_field "$p" criteria_hash)
    inv=$(get_field "$p" invocations_used)
    re=$(get_field "$p" reaudits_used)
    ver=$(get_field "$p" verify_used)
    grant=$(get_field "$p" grant_used)
    old=""
    case "$counter" in
      invocations_used) old=$inv;   inv=$((inv + 1)) ;;
      reaudits_used)    old=$re;    re=$((re + 1));   inv=$((inv + 1)) ;;
      verify_used)      old=$ver;   ver=$((ver + 1)); inv=$((inv + 1)) ;;
      grant_used)       old=$grant; grant=$((grant + 1)) ;;
      *) die "unknown counter: $counter" ;;
    esac
    # MONOTONE GUARD — belt and braces. Nothing may ever decrease.
    new=$(eval "echo \$$( case "$counter" in
              invocations_used) echo inv ;; reaudits_used) echo re ;;
              verify_used) echo ver ;; grant_used) echo grant ;; esac )")
    if [ "$new" -le "$old" ]; then
      die "MONOTONE VIOLATION: $counter would go $old -> $new; refusing to write"
    fi
    write_ledger "$p" "$1" "$tier" "$sha" "$ch" "$inv" "$re" "$ver" "$grant"
    echo "$new"
    ;;

  seen-has)
    # DEDUP AGAINST EVERYTHING SEEN, NEVER AGAINST EVERYTHING CONFIRMED.
    # A finding rejected in round 1 that reappears in round 3 is not new and
    # must not re-enter any counter. Keying on `confirmed` instead is the
    # specific mistake that makes a review loop never converge.
    [ $# -eq 2 ] || die "usage: seen-has <key> <violation_id>"
    p="$(require_ledger "$1")" || exit 2
    grep -q "\"$2\"" <(sed -n 's/^  "seen_keys": \(.*\)$/\1/p' "$p") && exit 0 || exit 1
    ;;

  seen-add)
    [ $# -eq 2 ] || die "usage: seen-add <key> <violation_id>"
    p="$(require_ledger "$1")" || exit 2
    if "$0" seen-has "$1" "$2" 2>/dev/null; then exit 0; fi
    cur=$(sed -n 's/^  "seen_keys": \(.*\),$/\1/p' "$p" | head -1)
    [ -n "$cur" ] || cur="[]"
    if [ "$cur" = "[]" ]; then new="[\"$2\"]"; else new="${cur%]}, \"$2\"]"; fi
    sed -i "s|^  \"seen_keys\": .*$|  \"seen_keys\": $new,|" "$p"
    ;;

  waive)
    [ $# -eq 2 ] || die "usage: waive <key> <violation_id>"
    p="$(require_ledger "$1")" || exit 2
    cur=$(sed -n 's/^  "waived": \(.*\)$/\1/p' "$p" | head -1)
    [ -n "$cur" ] || cur="[]"
    if [ "$cur" = "[]" ]; then new="[\"$2\"]"; else new="${cur%]}, \"$2\"]"; fi
    sed -i "s|^  \"waived\": .*$|  \"waived\": $new|" "$p"
    ;;

  persist)
    # audit() MUST persist the exact audited bytes and their SHA. Without this
    # the only delta available at round 2 is the orchestrator's self-report —
    # the forbidden input arriving through the front door.
    [ $# -eq 2 ] || die "usage: persist <key> <file>"
    [ -f "$2" ] || die "no such file: $2"
    mkdir -p "$AUDITED_DIR"
    cp "$2" "$AUDITED_DIR/$1.audited"
    sha1sum < "$2" | cut -d' ' -f1
    ;;

  show)
    [ $# -eq 1 ] || die "usage: show <key>"
    p="$(require_ledger "$1")" || exit 2
    cat "$p"
    ;;

  *)
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
