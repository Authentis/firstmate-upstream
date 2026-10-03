#!/usr/bin/env bash
# fm-wake-fold-lib.sh - the one owner of the wake fold: which wakes the watcher
# queues durably without waking the supervisor, when the folded rows come back
# as one digest wake, and when a drain may acknowledge a presentation by itself.
#
# WHY. Every wake a supervisor turn handles replays that session's whole
# context, and a measured day showed whole turns spent on events that carried
# nothing to act on: a mate's own outbound report waking its author, a check
# printing the same text it printed before, and a re-arm announcing rows that
# were only those. Folding them keeps every row durable and presented while
# spending a model turn only when something new needs one.
#
# FOLD CLASSES. A row is folded only when it matches one of these, and only
# while the fold is active (config/wake-fold is absent or `on`, and no away or
# quiet record exists):
#   - own-outbound  a signal whose only changed file is this secondmate home's
#                   own outbound parent channel (state/parent-replies.status on
#                   a remote route; bin/fm-parent-channel-lib.sh resolves it).
#                   Those lines are the home's reports TO its parent, which the
#                   parent's watcher classifies and wakes on; the author never
#                   needs a turn for its own words. Any other file in the same
#                   batch is classified exactly as before.
#   - check-repeat  a registered custom check (never a PR poll, the Relay poll,
#                   or the contributions check) whose output is byte-identical
#                   to one of the last FM_WAKE_FOLD_CHECK_MEMORY (8) outputs it
#                   already delivered. Any new text wakes at once.
#   - rearm         a fresh watcher cycle's `check: rearm-resurface` when the
#                   queue is non-empty and every queued row is a folded row.
#                   An empty queue, a crashed watcher's lock recovery, and any
#                   queued row that is not folded keep waking exactly as before.
# Nothing else folds: decisions, failures, done, blocked, needs-decision,
# acknowledgement-required recovery, merge results, PR-ready polls, captain
# inbox notes, process-event results, stale panes, heartbeats, and every worker
# status line take their unchanged paths.
#
# RECORD. A folded row is appended to the durable queue with the ordinary
# fm_wake_append_locked, and under the same queue lock one line
# "<seq>\t<epoch>\t<class>" is appended to $STATE/.wake-fold. A record line whose
# sequence is no longer queued is stale and is pruned under the queue lock.
# The queue row format and every consumer of it are unchanged, so a folded row
# rides along on the next real wake's drain like any other row.
#
# DIGEST. The watcher's poll loop calls fm_wake_fold_digest_due; once the oldest
# folded row still queued is FM_WAKE_FOLD_DIGEST_SECS old (default 900) it wakes
# with one `check: wake digest: ...` reason. The digest runs whether or not the
# switch is on, so switching the fold off never strands a folded row. Under an
# away or quiet record no digest is raised: the fold is inactive there, so the
# ordinary re-arm hands every queued row to the away daemon instead.
#
# ONE-CALL ACKNOWLEDGEMENT. bin/fm-wake-drain.sh --ack-if-routine owns the
# presentation side: it acknowledges by itself only when every row it presents
# is folded and its status and outcome sections hold nothing new.
#
# SWITCH. config/wake-fold: absent or `on` folds; any other content (write
# `off`) disables every fold class and the drain's routine acknowledgement, so
# the watcher and drain behave exactly as they did before the fold existed.
# Sourced by bin/fm-watch.sh and bin/fm-wake-drain.sh after fm-wake-lib.sh.

# shellcheck disable=SC2153 # STATE is set by bin/fm-wake-lib.sh, sourced first.
FM_WAKE_FOLD_RECORD="$STATE/.wake-fold"
FM_WAKE_FOLD_CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
FM_WAKE_FOLD_DIGEST_SECS="${FM_WAKE_FOLD_DIGEST_SECS:-900}"
case "$FM_WAKE_FOLD_DIGEST_SECS" in ''|*[!0-9]*|0) FM_WAKE_FOLD_DIGEST_SECS=900 ;; esac
FM_WAKE_FOLD_CHECK_MEMORY=8

# 0 when the switch allows folding. An unreadable or unrecognized file disables
# the fold, so a mistyped switch errs toward waking.
fm_wake_fold_enabled() {
  local file="$FM_WAKE_FOLD_CONFIG_DIR/wake-fold" value
  [ -e "$file" ] || [ -L "$file" ] || return 0
  value=$(tr -d '[:space:]' < "$file" 2>/dev/null) || return 1
  [ "$value" = on ]
}

# fm_wake_fold_append <kind> <key> <payload> <class>
# Queue one row and record it as folded, atomically under the queue lock. A row
# identical to one still queued adds nothing the drain would not already
# present, so it is not appended again.
fm_wake_fold_append() {
  local kind=$1 key=$2 payload=$3 class=$4 status=0 seq clean_key clean_payload
  case "$class" in own-outbound|check-repeat) ;; *) return 2 ;; esac
  clean_key=$(printf '%s' "$key" | fm_wake_clean_field)
  clean_payload=$(printf '%s' "$payload" | fm_wake_clean_field)
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || return 1
  if awk -F '\t' -v k="$kind" -v key="$clean_key" -v p="$clean_payload" '
    NF >= 5 && $3 == k && $4 == key && $5 == p { found = 1 }
    END { exit found ? 0 : 1 }' "$FM_WAKE_QUEUE" 2>/dev/null; then
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    return 0
  fi
  fm_wake_append_locked "$kind" "$key" "$payload" || status=$?
  if [ "$status" -eq 0 ]; then
    seq=$(cat "$STATE/.wake-queue.seq" 2>/dev/null || true)
    case "$seq" in ''|*[!0-9]*) status=1 ;; esac
  fi
  if [ "$status" -eq 0 ]; then
    printf '%s\t%s\t%s\n' "$seq" "$(date +%s)" "$class" >> "$FM_WAKE_FOLD_RECORD" || status=$?
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  return "$status"
}

# Print "<seq>\t<epoch>" for every folded row still queued, and prune record
# lines whose row is gone. Caller holds FM_WAKE_QUEUE_LOCK.
_fm_wake_fold_live_locked() {
  local tmp
  [ -s "$FM_WAKE_FOLD_RECORD" ] || return 0
  tmp=$(mktemp "$STATE/.wake-fold.tmp.XXXXXX") || return 1
  awk -F '\t' -v keep="$tmp" '
    FNR == NR { if (NF >= 5 && $2 ~ /^[0-9]+$/) queued[$2] = 1; next }
    $1 ~ /^[0-9]+$/ && ($1 in queued) && !seen[$1]++ { print > keep; print $1 "\t" $2 }
  ' "$FM_WAKE_QUEUE" "$FM_WAKE_FOLD_RECORD" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  if [ -s "$tmp" ]; then
    _fm_atomic_replace "$tmp" "$FM_WAKE_FOLD_RECORD" || { rm -f -- "$tmp"; return 1; }
  else
    rm -f -- "$tmp" "$FM_WAKE_FOLD_RECORD"
  fi
}

# 0 when the queue is non-empty and every structurally valid queued row is a
# folded row. Takes the queue lock.
fm_wake_fold_queue_all_folded() {
  local live status=1
  [ -s "$FM_WAKE_FOLD_RECORD" ] || return 1
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || return 1
  if live=$(_fm_wake_fold_live_locked) && [ -n "$live" ]; then
    printf '%s\n' "$live" | awk -F '\t' -v queue="$FM_WAKE_QUEUE" '
      { folded[$1] = 1 }
      END {
        rows = 0
        while ((getline line < queue) > 0) {
          n = split(line, f, "\t")
          if (n < 5 || f[2] !~ /^[0-9]+$/) continue
          rows++
          if (!(f[2] in folded)) exit 1
        }
        exit rows > 0 ? 0 : 1
      }' && status=0
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  return "$status"
}

# fm_wake_fold_rows_all_folded <seq>...
# 0 when at least one sequence is named and every named sequence is recorded
# as folded. The drain calls it under the queue lock it already holds.
fm_wake_fold_rows_all_folded() {
  [ "$#" -gt 0 ] && [ -s "$FM_WAKE_FOLD_RECORD" ] || return 1
  printf '%s\n' "$@" | awk -F '\t' -v record="$FM_WAKE_FOLD_RECORD" '
    BEGIN { while ((getline line < record) > 0) { split(line, f, "\t"); folded[f[1]] = 1 } }
    !($1 in folded) { bad = 1 }
    END { exit bad ? 1 : 0 }'
}

# Print the digest reason and return 0 once the oldest folded row still queued
# is at least FM_WAKE_FOLD_DIGEST_SECS old. Returns 1 when nothing is due.
fm_wake_fold_digest_due() {
  local live now oldest count
  [ -s "$FM_WAKE_FOLD_RECORD" ] || return 1
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || return 1
  live=$(_fm_wake_fold_live_locked) || live=
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  [ -n "$live" ] || return 1
  now=$(date +%s)
  oldest=$(printf '%s\n' "$live" | awk -F '\t' 'NR == 1 || $2 < m { m = $2 } END { print m + 0 }')
  count=$(printf '%s\n' "$live" | awk 'END { print NR }')
  [ $((now - oldest)) -ge "$FM_WAKE_FOLD_DIGEST_SECS" ] || return 1
  printf 'check: wake digest: %s folded routine wake row(s) queued, oldest %ss\n' "$count" "$((now - oldest))"
}

_fm_wake_fold_check_memory_path() {  # <check-path>
  printf '%s/.wake-fold-check-%s' "$STATE" "$(basename "$1")"
}

_fm_wake_fold_output_sum() {  # <output>
  printf '%s' "$1" | cksum | awk '{ print $1 "-" $2 }'
}

# 0 when <output> is byte-identical to one of the check's remembered outputs.
fm_wake_fold_check_repeat() {  # <check-path> <output>
  local memory sum
  memory=$(_fm_wake_fold_check_memory_path "$1")
  [ -f "$memory" ] && [ ! -L "$memory" ] || return 1
  sum=$(_fm_wake_fold_output_sum "$2")
  grep -Fqx -- "$sum" "$memory"
}

# Remember <output> as delivered for the check, keeping the newest few.
fm_wake_fold_check_remember() {  # <check-path> <output>
  local memory sum tmp
  memory=$(_fm_wake_fold_check_memory_path "$1")
  [ ! -L "$memory" ] || return 1
  sum=$(_fm_wake_fold_output_sum "$2")
  tmp=$(mktemp "$memory.tmp.XXXXXX") || return 1
  if { grep -Fvx -- "$sum" "$memory" 2>/dev/null; printf '%s\n' "$sum"; } \
    | tail -n "$FM_WAKE_FOLD_CHECK_MEMORY" > "$tmp" && mv -f -- "$tmp" "$memory"; then
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

# 0 when <status-file> is this home's own outbound parent channel. A main home,
# a local route (whose channel lives in the parent's state), or an unusable
# binding is never one.
fm_wake_fold_own_outbound() {  # <status-file>
  local dest
  if ! declare -F fm_parent_channel_destination >/dev/null; then
    # shellcheck source=bin/fm-parent-channel-lib.sh
    . "$FM_WAKE_LIB_DIR/fm-parent-channel-lib.sh" || return 1
  fi
  dest=$(fm_parent_channel_destination "$FM_HOME" "$STATE" 2>/dev/null) || return 1
  [ -n "$dest" ] && [ "$dest" = "$1" ]
}

# Print the status-log task name of this home's own outbound parent channel
# (its file name without .status), or fail when the home has none in $STATE.
fm_wake_fold_own_outbound_task() {
  local dest task
  if ! declare -F fm_parent_channel_destination >/dev/null; then
    # shellcheck source=bin/fm-parent-channel-lib.sh
    . "$FM_WAKE_LIB_DIR/fm-parent-channel-lib.sh" || return 1
  fi
  dest=$(fm_parent_channel_destination "$FM_HOME" "$STATE" 2>/dev/null) || return 1
  task=$(basename "$dest" .status)
  [ "$dest" = "$STATE/$task.status" ] || return 1
  printf '%s\n' "$task"
}
