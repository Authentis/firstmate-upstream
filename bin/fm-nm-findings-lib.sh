#!/usr/bin/env bash
# fm-nm-findings-lib.sh - the single owner of the no-mistakes finding-retention
# ledger format and its fold/report/completion logic.
#
# WHY THIS EXISTS: a no-mistakes worker drives review gates through the
# registered `axi respond --action fix --findings <ids>` interface, which
# selects only the named findings for that round. A finding left unselected is
# not re-surfaced by the tool's own status/response output on a later round,
# so nothing about the registered interface itself preserves an unresolved
# finding's identity, verbatim text, or provenance once a round moves past it
# (observed 2026-09-06, run 01M1TB9ZZQGN0JQ1RYV3WERD4S review round3: an
# earlier upgrade-condition finding had already vanished between rounds 2 and
# 3, and round3 then dropped two more independent findings the same way).
# This library never reads or writes any no-mistakes pipeline state - it owns
# a separate, durable, firstmate-side ledger that a no-mistakes worker
# hand-appends to at every gate (bin/fm-dod-lib.sh's no-mistakes Definition of
# done block is the one policy owner telling the worker what to append and
# when), so the ledger is the append-only record of record regardless of what
# the pipeline itself resurfaces on a later round.
#
# LEDGER FORMAT (this header is the one owner of the format).
#   Path: <data-dir>/<task-id>/nm-findings-ledger.jsonl
#   Append-only, one JSON object per line, one of two event shapes:
#     seen:        {"round":<n>,"step":"<step>","finding":{"id":"<id>", ...
#                    every other field exactly as the gate reported it}}
#     disposition: {"round":<n>,"step":"<step>","finding_id":"<id>",
#                    "disposition":"fixed"|"skipped-closed"|"deferred",
#                    "deferred_owner":"<owner>","deferred_id":"<external-id>"}
#   "deferred_owner" and "deferred_id" are required together and only for
#   disposition "deferred"; a disposition line missing one while claiming
#   the other, or carrying either for a non-deferred disposition, is a
#   malformed line and is excluded from the fold rather than trusted.
#   A `finding` object's only required field is a non-empty string `id`;
#   every other field is caller-defined and preserved verbatim.
#   Lines are never rewritten, reordered, or deleted; an absent ledger file
#   is a valid empty ledger (a task with no no-mistakes findings yet, or a
#   task predating this contract), never an error.
#
# FOLD SEMANTICS.
#   Every distinct finding id folds to exactly one current record:
#     - `finding`: the verbatim finding object from that id's FIRST seen
#       event (the original text and fields the reviewer actually reported),
#       never a later round's rephrasing.
#     - `first_seen` / `last_seen`: {"round","step"} of the earliest and
#       latest seen event for that id, so provenance survives even when the
#       finding was not repeated verbatim on a later round's gate.
#     - `disposition`: "open" when no disposition event exists for the id,
#       or when that id's latest seen event follows its latest disposition
#       event in ledger order (a gate presented it again after it was
#       disposed of, so it is reopened until a newer disposition closes it);
#       otherwise the LATEST disposition event's value. A finding is never
#       silently dropped: the only way off "open" is an explicit disposition
#       line naming that exact id, appended after its latest seen line.
#     - `deferred_owner` / `deferred_id`: from the latest disposition event
#       when the folded disposition is "deferred", otherwise null.
#   A disposition event for an id with no matching seen event is dropped from
#   the fold (it cannot prove what it is disposing of) rather than accepted
#   as a fabricated closure.
#
# USAGE.
#   fm-nm-findings-lib.sh fold <data-dir> <task-id>
#     Prints the current folded state as a JSON array (see FOLD SEMANTICS).
#     An absent or empty ledger prints [].
#   fm-nm-findings-lib.sh open <data-dir> <task-id>
#     Prints only the still-open folded records, as a JSON array.
#   fm-nm-findings-lib.sh report <data-dir> <task-id>
#     Prints a plain-text summary in three sections - Closed, Deferred, Open -
#     each finding shown by id plus its first line of verbatim text (deferred
#     also shows owner/id), ending with a one-line rollup count. This is the
#     text a final handoff summary must never contradict by omission.
#   fm-nm-findings-lib.sh all-addressed <data-dir> <task-id>
#     Exits 0 only when the fold has zero open records; otherwise exits 1 and
#     prints the still-open ids to stderr. A final handoff must not claim
#     every finding addressed unless this exits 0.
#
# Sourcing this file (rather than executing it) exposes the same behavior as
# fm_nm_findings_fold / fm_nm_findings_open / fm_nm_findings_report /
# fm_nm_findings_all_addressed, each taking <data-dir> <task-id>.

fm_nm_findings_ledger_path() {  # <data-dir> <task-id>
  printf '%s/%s/nm-findings-ledger.jsonl' "$1" "$2"
}

# Read the ledger (absent file => empty) one line at a time so a line that is
# not valid JSON at all (unlike a structurally invalid-but-parseable event,
# which the fold below rejects) never aborts the whole read; only lines that
# parse as a JSON object reach the fold.
_fm_nm_findings_valid_events() {  # <ledger-path>
  local path=$1
  if [ -f "$path" ]; then
    jq -R -c 'fromjson? | select(type=="object")' "$path" 2>/dev/null
  fi
}

fm_nm_findings_fold() {  # <data-dir> <task-id>
  local data=$1 id=$2 ledger
  ledger=$(fm_nm_findings_ledger_path "$data" "$id")
  _fm_nm_findings_valid_events "$ledger" | jq -s '
    # Keep only structurally valid seen/disposition events.
    def valid_seen: (.round != null) and (.step != null)
      and (.finding? | type == "object")
      and ((.finding.id? | type == "string") and (.finding.id | length > 0));
    def valid_disp: (.round != null) and (.step != null)
      and (.finding_id? | type == "string") and (.finding_id | length > 0)
      and (.disposition? as $d | ["fixed","skipped-closed","deferred"] | index($d) != null)
      and (
        if .disposition == "deferred" then
          (.deferred_owner? | type == "string") and (.deferred_owner | length > 0)
          and (.deferred_id? | type == "string") and (.deferred_id | length > 0)
        else
          (.deferred_owner == null) and (.deferred_id == null)
        end
      );
    to_entries | map(.value + {_pos: .key})
    | (map(select(valid_seen))) as $seens
    | (map(select(valid_disp))) as $disps
    | ($seens | group_by(.finding.id) | map(sort_by(._pos)) | map({
        id: .[0].finding.id,
        finding: .[0].finding,
        first_seen: {round: .[0].round, step: .[0].step},
        last_seen: {round: (.[-1].round), step: (.[-1].step)},
        _last_seen_pos: .[-1]._pos
      })) as $folded_seen
    | ($disps | group_by(.finding_id) | map(max_by(._pos))) as $latest_disp
    | $folded_seen | map(
        . as $f
        | ($latest_disp | map(select(.finding_id == $f.id and ._pos > $f._last_seen_pos)) | .[0]) as $d
        | ($f | del(._last_seen_pos)) + {
            disposition: ($d.disposition // "open"),
            deferred_owner: (if ($d.disposition // "") == "deferred" then $d.deferred_owner else null end),
            deferred_id: (if ($d.disposition // "") == "deferred" then $d.deferred_id else null end)
          }
      )
  '
}

fm_nm_findings_open() {  # <data-dir> <task-id>
  fm_nm_findings_fold "$1" "$2" | jq -c '[.[] | select(.disposition == "open")]'
}

_fm_nm_findings_first_line() {  # <text>
  printf '%s' "$1" | awk 'NR==1{print; exit}'
}

fm_nm_findings_report() {  # <data-dir> <task-id>
  local data=$1 id=$2 folded closed_n deferred_n open_n
  folded=$(fm_nm_findings_fold "$data" "$id")
  if [ "$(printf '%s' "$folded" | jq 'length')" -eq 0 ]; then
    printf 'No no-mistakes findings recorded for this task.\n'
    return 0
  fi
  printf 'Closed:\n'
  printf '%s' "$folded" | jq -r '.[] | select(.disposition=="fixed" or .disposition=="skipped-closed") | "  - " + .id + " (" + .disposition + ")"'
  printf 'Deferred:\n'
  printf '%s' "$folded" | jq -r '.[] | select(.disposition=="deferred") | "  - " + .id + " -> " + .deferred_owner + "/" + .deferred_id'
  printf 'Open:\n'
  printf '%s' "$folded" | jq -r '.[] | select(.disposition=="open") | "  - " + .id'
  closed_n=$(printf '%s' "$folded" | jq '[.[] | select(.disposition=="fixed" or .disposition=="skipped-closed")] | length')
  deferred_n=$(printf '%s' "$folded" | jq '[.[] | select(.disposition=="deferred")] | length')
  open_n=$(printf '%s' "$folded" | jq '[.[] | select(.disposition=="open")] | length')
  printf 'Total: %s closed, %s deferred, %s open.\n' "$closed_n" "$deferred_n" "$open_n"
}

fm_nm_findings_all_addressed() {  # <data-dir> <task-id>
  local open_ids
  open_ids=$(fm_nm_findings_open "$1" "$2" | jq -r '.[].id')
  if [ -n "$open_ids" ]; then
    printf 'still open: %s\n' "$(printf '%s' "$open_ids" | tr '\n' ' ')" >&2
    return 1
  fi
  return 0
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -eu
  case "${1:-}" in
    fold) fm_nm_findings_fold "$2" "$3" ;;
    open) fm_nm_findings_open "$2" "$3" ;;
    report) fm_nm_findings_report "$2" "$3" ;;
    all-addressed) fm_nm_findings_all_addressed "$2" "$3" ;;
    *)
      echo "usage: fm-nm-findings-lib.sh fold|open|report|all-addressed <data-dir> <task-id>" >&2
      exit 2
      ;;
  esac
fi
