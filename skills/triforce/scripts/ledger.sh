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
#   ledger.sh waive    <key> <violation_id>   a human dismissed it: NOT acted on
#   ledger.sh resolve  <key> <violation_id>   verify() returned RESOLVED: acted on
#   ledger.sh persist  <key> <file>           store the exact audited bytes
#   ledger.sh show <key>
#   ledger.sh rate [window]                   effective-false-positive rate over
#                                             the last <window> audits (default 10)
#
# Counters: invocations_used, reaudits_used, verify_used, grant_used.
#
# Dispositions: seen_keys is every finding ever cited under this key; resolved
# and waived are the two dispositions a finding can reach, each append-only and
# idempotent. A finding in neither is OPEN. `rate` reads all three across
# ledgers, and it is the only reader that crosses ledgers.
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
  local seen waived unres resolved
  seen=$(sed -n 's/^  "seen_keys": \(.*\)$/\1/p' "$p" 2>/dev/null | head -1)
  waived=$(sed -n 's/^  "waived": \(.*\)$/\1/p' "$p" 2>/dev/null | head -1)
  unres=$(sed -n 's/^  "unresolved": \(.*\)$/\1/p' "$p" 2>/dev/null | head -1)
  resolved=$(sed -n 's/^  "resolved": \(.*\)$/\1/p' "$p" 2>/dev/null | head -1)
  [ -n "$seen" ]     || seen='[],'
  [ -n "$waived" ]   || waived='[]'
  [ -n "$unres" ]    || unres='[]'
  [ -n "$resolved" ] || resolved='[]'
  unres="${unres%,},"          # normalise to exactly one trailing comma
  resolved="${resolved%,},"
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
    echo "  \"unresolved\": $unres"
    echo "  \"seen_keys\": $seen"
    echo "  \"resolved\": $resolved"
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
    printf '{\n  "unresolved": [],\n  "seen_keys": [],\n  "resolved": [],\n  "waived": []\n}\n' > "$p"
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

  unresolved-bump)
    # "A violation may return UNRESOLVED at most twice; the third escalates to
    # a human." Mechanical, because a rule the orchestrator has to remember is a
    # rule it can talk itself out of. Prints the new count and exits 1 once the
    # violation has crossed into escalation territory.
    [ $# -eq 2 ] || die "usage: unresolved-bump <key> <violation_id>"
    p="$(require_ledger "$1")" || exit 2
    # Normalise FIRST: the stored line carries a trailing comma, and stripping
    # "]" from "[...]," removes nothing, which silently corrupts the array.
    line=$(sed -n 's/^  "unresolved": \(.*\)$/\1/p' "$p" | head -1)
    line="${line%,}"
    [ -n "$line" ] || line="[]"
    n=$(printf '%s' "$line" | grep -o "\"$2:[0-9]*\"" | sed "s/\"$2://; s/\"//" | head -1)
    [ -n "$n" ] || n=0
    new=$((n + 1))
    # Drop this violation's existing entry, then re-add it with the new count.
    rest=$(printf '%s' "$line" \
           | sed "s/\"$2:[0-9]*\", \{0,1\}//; s/, \{0,1\}\"$2:[0-9]*\"//; s/\"$2:[0-9]*\"//")
    rest=$(printf '%s' "$rest" | sed 's/\[ *, */[/; s/, *\]/]/; s/, *, */, /')
    [ -n "$rest" ] || rest="[]"
    if [ "$rest" = "[]" ]; then merged="[\"$2:$new\"]"; else merged="${rest%]}, \"$2:$new\"]"; fi
    if grep -q '^  "unresolved":' "$p"; then
      sed -i "s|^  \"unresolved\": .*$|  \"unresolved\": $merged,|" "$p"
    else
      sed -i "s|^  \"seen_keys\":|  \"unresolved\": $merged,\n  \"seen_keys\":|" "$p"
    fi
    echo "$new"
    [ "$new" -ge 3 ] && { echo "ESCALATE: $2 returned UNRESOLVED $new times; a human decides" >&2; exit 1; }
    exit 0
    ;;

  unresolved-count)
    [ $# -eq 2 ] || die "usage: unresolved-count <key> <violation_id>"
    p="$(require_ledger "$1")" || exit 2
    n=$(sed -n 's/^  "unresolved": \(.*\)$/\1/p' "$p" | head -1 \
        | grep -o "\"$2:[0-9]*\"" | sed "s/\"$2://; s/\"//" | head -1)
    printf '%s' "${n:-0}"
    ;;

  waive)
    # A human dismissed the finding: it was NOT acted on. Idempotent -- a
    # disposition recorded twice must count once, or `rate` inflates.
    [ $# -eq 2 ] || die "usage: waive <key> <violation_id>"
    p="$(require_ledger "$1")" || exit 2
    cur=$(sed -n 's/^  "waived": \(.*\)$/\1/p' "$p" | head -1)
    [ -n "$cur" ] || cur="[]"
    printf '%s' "$cur" | grep -q "\"$2\"" && exit 0
    if [ "$cur" = "[]" ]; then new="[\"$2\"]"; else new="${cur%]}, \"$2\"]"; fi
    sed -i "s|^  \"waived\": .*$|  \"waived\": $new|" "$p"
    ;;

  resolve)
    # verify() returned RESOLVED: the finding was acted on. This is the other
    # half of the disposition that "effective false positives" needs -- a true
    # finding nobody acted on is a false positive, and until this existed the
    # ledger recorded the citation and the dismissal but never the fix.
    # Append-only and idempotent, like waive. The line sits before "waived" so
    # the last line of the file stays comma-free and older ledgers, which lack
    # it, get it inserted rather than rewritten.
    [ $# -eq 2 ] || die "usage: resolve <key> <violation_id>"
    p="$(require_ledger "$1")" || exit 2
    cur=$(sed -n 's/^  "resolved": \(.*\)$/\1/p' "$p" | head -1)
    cur="${cur%,}"
    [ -n "$cur" ] || cur="[]"
    printf '%s' "$cur" | grep -q "\"$2\"" && exit 0
    if [ "$cur" = "[]" ]; then new="[\"$2\"]"; else new="${cur%]}, \"$2\"]"; fi
    if grep -q '^  "resolved":' "$p"; then
      sed -i "s|^  \"resolved\": .*$|  \"resolved\": $new,|" "$p"
    else
      sed -i "s|^  \"waived\":|  \"resolved\": $new,\n  \"waived\":|" "$p"
    fi
    ;;

  rate)
    # EFFECTIVE FALSE POSITIVES, read and never acted on.
    #
    # preflight.md: "a true finding nobody acted on is a false positive", over
    # rolling windows of 10 audits; warn at 5%, tighten above 10%. This command
    # is the READER. It walks the last <window> ledgers -- one ledger is one
    # audit -- and reports the dispositions. It changes nothing, tightens
    # nothing and warns about nothing: the 5% / 10% behaviour is HELD until a
    # full window of production data exists to design it against (author
    # decision 4, 2026-09-15). The thresholds are printed as reference only.
    #
    # Two rates, because the ledger cannot tell an ignored finding from one
    # still in progress:
    #   lower  = waived / cited            findings a human dismissed
    #   upper  = (waived + open) / cited   ...plus every finding never dispositioned
    # The true not-useful rate lies between them. Neither is printed when
    # nothing was cited: 0 of 0 is not a rate, it is an absence of data.
    #
    # Recency is file mtime -- the ledger carries no timestamp, and mtime is
    # the last write, which is the last time the audit was touched.
    n="${1:-10}"
    case "$n" in ''|*[!0-9]*|0) die "usage: rate [window >= 1]" ;; esac
    [ -d "$LEDGER_DIR" ] || { echo "rate: no ledgers under $LEDGER_DIR; nothing has been audited here."; exit 0; }
    files=$(ls -t "$LEDGER_DIR"/*.json 2>/dev/null | head -n "$n")
    [ -n "$files" ] || { echo "rate: no ledgers under $LEDGER_DIR; nothing has been audited here."; exit 0; }
    audits=0; cited=0; resolved=0; waived=0; escalated=0
    count_ids() { printf '%s' "$1" | grep -o '"[^"]*"' | grep -c . 2>/dev/null || true; }
    for f in $files; do
      audits=$((audits + 1))
      s=$(sed -n 's/^  "seen_keys": \(.*\)$/\1/p' "$f" | head -1)
      r=$(sed -n 's/^  "resolved": \(.*\)$/\1/p' "$f" | head -1)
      w=$(sed -n 's/^  "waived": \(.*\)$/\1/p' "$f" | head -1)
      u=$(sed -n 's/^  "unresolved": \(.*\)$/\1/p' "$f" | head -1)
      cited=$((cited + $(count_ids "$s")))
      resolved=$((resolved + $(count_ids "$r")))
      waived=$((waived + $(count_ids "$w")))
      escalated=$((escalated + $(printf '%s' "$u" | grep -o '"[^"]*:[0-9]*"' | grep -cE ':([3-9]|[1-9][0-9]+)"$' 2>/dev/null || true)))
    done
    open=$((cited - resolved - waived)); [ "$open" -lt 0 ] && open=0
    echo "audits     $audits of a $n-audit window$([ "$audits" -lt "$n" ] && printf ' (PARTIAL: fewer than %s ledgers exist)' "$n")"
    echo "cited      $cited"
    echo "resolved   $resolved     acted on (verify returned RESOLVED)"
    echo "waived     $waived     dismissed by a human: not acted on"
    echo "open       $open     no disposition recorded"
    echo "escalated  $escalated     UNRESOLVED three times; a human decides"
    if [ "$cited" -eq 0 ]; then
      echo "rate       UNDEFINED: nothing was cited in this window, so there is no rate to report."
    else
      lo=$(awk -v w="$waived" -v c="$cited" 'BEGIN{printf "%.1f", 100*w/c}')
      hi=$(awk -v w="$waived" -v o="$open" -v c="$cited" 'BEGIN{printf "%.1f", 100*(w+o)/c}')
      echo "rate       not-useful $lo% (waived only) .. $hi% (waived + open)"
      echo "reference  preflight.md warns at 5% and tightens above 10%. NOT WIRED: this command"
      echo "           reports and does nothing else. See HANDOFF, author decision 4."
    fi
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
