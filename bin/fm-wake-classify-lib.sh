#!/usr/bin/env bash
# fm-wake-classify-lib.sh - the one owner of pre-wake classification: which
# class a queued wake belongs to before the watcher decides whether it may
# start a model turn, how non-urgent wakes are batched, and the measurement
# record from which wake-started turns can be counted.
#
# WHY. Every wake-started turn replays the supervisor's whole context. The wake
# fold (bin/fm-wake-fold-lib.sh) already keeps repeated check output and a
# re-arm from waking the model, but it still spent one digest turn to hand the
# model rows its --ack-if-routine drain then acknowledged unread, and every
# changing-text check or idle secondmate progress line still woke at once.
#
# Secondmate routine outcomes use class secondmate-outcome, remain durable
# until a natural drain, and never start a digest turn by age alone.
# WAKE TURN STATS counts them as secondmate-outcomes-deferred.
# CLASSES (fm_wake_classify):
#   routine    a row the wake fold records (own-outbound, check-repeat) - the
#              very class bin/fm-wake-drain.sh --ack-if-routine acknowledges.
#              The watcher acknowledges these itself once they have waited
#              FM_WAKE_FOLD_DIGEST_SECS (`fm-wake-drain.sh --ack-routine-folded`),
#              so they never start a turn.
#   nonurgent  a row that needs the model eventually but not now: the new
#              output of a periodic reporter check the home opted in (the
#              shipped tool-updates check, plus the ids in config/wake-batch-checks)
#              that carries no urgency marker, and a secondmate's progress line
#              (no captain-relevant event in its new span). The watcher queues it durably in state/.wake-batch
#              without waking and raises one `check: wake digest` wake for the
#              batch once its oldest row is FM_WAKE_BATCH_SECS (default 900)
#              old and no digest wake was raised inside that window - at most
#              one batched turn per window.
#   relay-batch explicitly designated parent routine relay spans, only with
#              config/wake-relay-batch=on: each line has [relay-batch] and a
#              valid [corr=<16hex>] header, a working/paused/note/done/resolved
#              verb, and no reserved urgent vocabulary after that verb.
#              Metadata is limited to these tags and optional [at=<epoch>].
#              Only secondmate status files qualify, and every changed line
#              must qualify. These rows use the SAME queue/batch record with a
#              fixed 3600-second window, independent of FM_WAKE_BATCH_SECS.
#              Any urgent wake can carry all held evidence into its drain.
#              The absent/off/invalid/unreadable switch keeps existing behavior;
#              switching off (or disabling classification) delivers held relay
#              rows on the next digest tick without acknowledging any row.
#   urgent     everything else, flowing exactly as before: every worker status
#              line, stalls, heartbeats, merge and PR results, captain inbox
#              notes, process-event results, recovery, and any custom-check
#              output matching the urgency pattern.
# The caller supplies the hint that names what it knows about a row (the
# watcher alone knows a check is an opted-in reporter, or that a signal's files
# are secondmate lanes with no captain-relevant event); an absent or
# unrecognised hint is urgent, so classification can only ever widen what waits
# by an explicit, named class. A check is never batched merely for being a
# custom check: mail, merge, and growth checks all arrive as custom checks and
# carry things the captain waits on, so only a named reporter may wait.
#
# BATCH RECORD. "<seq>\t<epoch>\t<nonurgent|relay-batch|secondmate-outcome>" lines in $STATE/.wake-batch, appended
# under the queue lock atomically with the queue row (fm_wake_batch_append). It
# is deliberately separate from the fold record: the Pi branch dispatcher and
# the supervision host read that record as "foldable", and a batched row is an
# ordinary queued row to them, which can only make them more cautious. The
# drain never treats a batched row as routine. A record line whose row is gone
# is stale and is pruned under the queue lock.
#
# MEASUREMENT. $STATE/.wake-turns.log is append-only, one
# "<epoch>\t<event>\t<class>\t<detail>" line per event: `turn` when the watcher
# delivers a wake that starts a model turn (class urgent, batched-digest, or fold-digest), `routine-ack`
# when the watcher acknowledges a routine row itself, and `batched` when a row is
# queued without waking. fm_wake_measure_summary prints the trailing-window
# counts; bin/fm-wake-drain.sh prints that line on every non-empty presentation,
# so wake-started turns per window can be read from the session file itself.
#
# SWITCH. config/wake-classify: absent or `on` classifies; any other content
# (write `off`) restores the pre-classification behaviour exactly - routine rows
# wake through the fold digest, nothing is batched - and a batch already
# recorded is still delivered by the digest, so switching off strands no row.
# Sourced by bin/fm-watch.sh and bin/fm-wake-drain.sh after fm-wake-fold-lib.sh.

# shellcheck disable=SC2153 # STATE is set by bin/fm-wake-lib.sh, sourced first.
FM_WAKE_BATCH_RECORD="$STATE/.wake-batch"
FM_WAKE_BATCH_LAST="$STATE/.wake-batch-last"
FM_WAKE_MEASURE_LOG="$STATE/.wake-turns.log"
FM_WAKE_CLASSIFY_CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
FM_WAKE_BATCH_SECS="${FM_WAKE_BATCH_SECS:-900}"
case "$FM_WAKE_BATCH_SECS" in ''|*[!0-9]*|0) FM_WAKE_BATCH_SECS=900 ;; esac
FM_WAKE_MEASURE_WINDOW_SECS="${FM_WAKE_MEASURE_WINDOW_SECS:-21600}"
case "$FM_WAKE_MEASURE_WINDOW_SECS" in ''|*[!0-9]*|0) FM_WAKE_MEASURE_WINDOW_SECS=21600 ;; esac
FM_WAKE_MEASURE_MAX_LINES=20000
# Periodic reporter checks every home may batch; config/wake-batch-checks adds
# more (one check id per line, an optional .check.sh suffix, # comments).
FM_WAKE_BATCH_CHECKS_DEFAULT='tool-updates'

# 0 when <check-path> names a reporter check this home batches.
fm_wake_check_batchable() {  # <check-path>
  local id file line
  id=$(basename "$1" .check.sh)
  case " $FM_WAKE_BATCH_CHECKS_DEFAULT " in *" $id "*) return 0 ;; esac
  file="$FM_WAKE_CLASSIFY_CONFIG_DIR/wake-batch-checks"
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=$(printf '%s' "$line" | tr -d '[:space:]')
    line=${line%.check.sh}
    [ -n "$line" ] && [ "$line" = "$id" ] && return 0
  done < "$file"
  return 1
}
# Even an opted-in check's output naming any of these is never batched. FM_WAKE_URGENT_RE
# replaces the default for a home that wants a different vocabulary.
FM_WAKE_URGENT_RE_DEFAULT='(^|[^[:alnum:]])(fail(ed|s|ure|ures|ing)?|error|errors|red|stall(ing|ed|s)?|stuck|block(ed|ing|er|ers|s)?|dead|down|crash(ed|es)?|broken|timeout|timed out|conflict|decisions?|pending|captain|chief|urgent|alarm|security|refus(ed|es)|done|complet(e|ed|es|ion)|finished|ready|merged|approv(ed|al)|needs?|waiting|request(ed|s)?|incomplete|invalid|unreadable|unavailable|malformed|cannot|could not|unable|missing|degraded|succeeded|success|unhealthy|offline|critical|vulnerab[a-z]*|cve|required|expired?|expiry|authenticat[a-z]*|credential[a-z]*|login|log in|unauthori[sz]ed|forbidden|denied|exhausted|quota|action)([^[:alnum:]]|$)'

# 0 when the switch allows classification. An unreadable or unrecognised file
# disables it, so a mistyped switch errs toward waking.
fm_wake_classify_enabled() {
  local file="$FM_WAKE_CLASSIFY_CONFIG_DIR/wake-classify" value
  [ -e "$file" ] || [ -L "$file" ] || return 0
  value=$(tr -d '[:space:]' < "$file" 2>/dev/null) || return 1
  [ "$value" = on ]
}

# Relay batching is deliberately a second opt-in, independent of reporter checks.
# Every nonblank line in a secondmate's changed span must explicitly designate
# a relay, carry a valid correlation token, and have a known non-urgent verb.
# The reserved urgency vocabulary cannot be weakened by FM_WAKE_URGENT_RE.
fm_wake_relay_batch_enabled() {
  local file="$FM_WAKE_CLASSIFY_CONFIG_DIR/wake-relay-batch" value
  [ -f "$file" ] && [ -r "$file" ] && [ ! -L "$file" ] || return 1
  value=$(tr -d '[:space:]' < "$file" 2>/dev/null) || return 1
  [ "$value" = on ]
}

fm_wake_relay_files_batchable() {  # <status-file> ...
  local f id start size chunk line prefix verb seen=0 rc
  fm_wake_relay_batch_enabled || return 1
  [ "$#" -gt 0 ] || return 1
  for f in "$@"; do
    case "$f" in *.status) ;; *) return 1 ;; esac
    [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 1
    id=${f##*/}; id=${id%.status}
    [ "$(fm_meta_get "$STATE/$id.meta" kind 2>/dev/null)" = secondmate ] || return 1
    start=$(fm_wake_signal_seen_size "$STATE" "$f")
    size=$(_fm_status_file_size "$f") || return 1
    size=${size//[[:space:]]/}
    case "$start:$size" in *[!0-9:]*|:*|*:) return 1 ;; esac
    [ "$start" -le "$size" ] || start=0
    [ "$start" -lt "$size" ] || return 1
    # Sentinel preserves trailing newlines; the byte count rejects binary data
    # and short reads instead of classifying a truncated safe prefix.
    chunk=$(_fm_status_read_span "$f" "$start" "$((size - start))" && printf '.') || return 1
    chunk=${chunk%.}
    [ "$(printf '%s' "$chunk" | LC_ALL=C wc -c | tr -d '[:space:]')" = "$((size - start))" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in *[![:space:]]*) ;; *) continue ;; esac
      prefix=${line%%:*}
      printf '%s\n' "$line" | LC_ALL=C grep -Eq '^(working|paused|note|done|resolved)([[:space:]]+\[(relay-batch|corr=[A-Fa-f0-9]{16}|at=[0-9]+)\])+[[:space:]]*:' || return 1
      case "$prefix" in *'[relay-batch]'*) ;; *) return 1 ;; esac
      printf '%s\n' "$prefix" | LC_ALL=C grep -Eq '\[corr=[A-Fa-f0-9]{16}\]' || return 1
      verb=${line%%[[:space:]]*}
      printf '%s' "${line#"$verb"}" | LC_ALL=C grep -Eiq -- "$FM_WAKE_URGENT_RE_DEFAULT|(^|[^[:alnum:]])check[[:space:]]*:"
      rc=$?
      [ "$rc" -eq 1 ] || return 1
      seen=1
    done <<EOF
$chunk
EOF
  done
  [ "$seen" -eq 1 ]
}

# fm_wake_classify <kind> <key> <payload> [hint]
# Print routine, nonurgent, relay-batch, or urgent. <hint> is one of:
#   fold:own-outbound | fold:check-repeat   the fold record's class for the row
#   batch-check                             new output of an opted-in reporter check
#   secondmate-progress                     secondmate files with no captain-relevant event
#   relay-batch                             verified explicit routine parent relay spans
# Anything else, including no hint, is urgent.
fm_wake_classify() {
  local kind=${1:-} payload=${3:-} hint=${4:-} re
  case "$kind" in signal|stale|check|heartbeat) ;; *) printf 'urgent\n'; return 0 ;; esac
  case "$hint" in
    fold:own-outbound|fold:check-repeat)
      printf 'routine\n'
      ;;
    batch-check)
      [ "$kind" = check ] || { printf 'urgent\n'; return 0; }
      re=${FM_WAKE_URGENT_RE:-$FM_WAKE_URGENT_RE_DEFAULT}
      # Only a clean no-match (status 1) may wait; a match or a pattern error
      # (status 2) is urgent.
      printf '%s' "$payload" | fm_wake_clean_field | LC_ALL=C grep -Eiq -- "$re" 2>/dev/null
      case "$?" in
        1) printf 'nonurgent\n' ;;
        *) printf 'urgent\n' ;;
      esac
      ;;
    relay-batch)
      if [ "$kind" = signal ] && fm_wake_relay_batch_enabled; then
        printf 'relay-batch\n'
      else
        printf 'urgent\n'
      fi
      ;;
    secondmate-progress)
      if [ "$kind" = signal ]; then printf 'nonurgent\n'; else printf 'urgent\n'; fi
      ;;
    *) printf 'urgent\n' ;;
  esac
}

# fm_wake_measure <event> <class> <detail>
# Append one best-effort measurement line, bounded to a few thousand lines.
fm_wake_measure() {
  local event=$1 class=$2 detail=${3:-} lines tmp
  detail=$(printf '%s' "$detail" | fm_wake_clean_field | cut -c1-160)
  printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$event" "$class" "$detail" >> "$FM_WAKE_MEASURE_LOG" 2>/dev/null || return 0
  lines=$(awk 'END { print NR }' "$FM_WAKE_MEASURE_LOG" 2>/dev/null || echo 0)
  case "$lines" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$lines" -gt "$FM_WAKE_MEASURE_MAX_LINES" ]; then
    # Drop what has aged out of the window first, so a burst of batched rows
    # cannot push an in-window turn out of the count; only then cap by length.
    # Every in-window turn record is kept; only the auxiliary rows are capped.
    tmp=$(mktemp "$FM_WAKE_MEASURE_LOG.tmp.XXXXXX") || return 0
    if {
      awk -F '\t' -v cutoff="$(( $(date +%s) - FM_WAKE_MEASURE_WINDOW_SECS ))" '$1 ~ /^[0-9]+$/ && $1 >= cutoff && $2 == "turn"' "$FM_WAKE_MEASURE_LOG"
      awk -F '\t' -v cutoff="$(( $(date +%s) - FM_WAKE_MEASURE_WINDOW_SECS ))" '$1 ~ /^[0-9]+$/ && $1 >= cutoff && $2 != "turn"' "$FM_WAKE_MEASURE_LOG" \
        | tail -n "$FM_WAKE_MEASURE_MAX_LINES"
    } > "$tmp" 2>/dev/null; then
      mv -f -- "$tmp" "$FM_WAKE_MEASURE_LOG" 2>/dev/null || rm -f -- "$tmp"
    else
      rm -f -- "$tmp"
    fi
  fi
  return 0
}

# The watcher's wake(): count every wake that starts a model turn. A batched
# digest is its own class so the two can be read apart.
fm_wake_measure_turn() {  # <reason>
  case "$1" in
    # A batched digest starts its window only once it was actually delivered.
    'check: wake digest: '*' batched non-urgent'*) fm_wake_batch_digest_mark "$1"; fm_wake_measure turn batched-digest "$1" ;;
    'check: wake digest'*) fm_wake_measure turn fold-digest "$1" ;;
    *) fm_wake_measure turn urgent "$1" ;;
  esac
}

# Print one summary line for the trailing window (default six hours).
fm_wake_measure_summary() {
  local now cutoff
  now=$(date +%s)
  cutoff=$((now - FM_WAKE_MEASURE_WINDOW_SECS))
  awk -F '\t' -v cutoff="$cutoff" -v win="$FM_WAKE_MEASURE_WINDOW_SECS" '
    $1 ~ /^[0-9]+$/ && $1 >= cutoff {
      if ($2 == "turn") { turns++; if ($3 == "batched-digest") digests++; else if ($3 == "fold-digest") folds++; else urgent++ }
      else if ($2 == "routine-ack") acked++
      else if ($2 == "batched") { batched++; if ($3 == "secondmate-outcome") outcomes++ }
    }
    END {
      printf "WAKE TURN STATS (last %dh): turns=%d (urgent=%d, batched-digest=%d, fold-digest=%d) routine-acked-by-watcher=%d batched-rows=%d secondmate-outcomes-deferred=%d\n",
        win / 3600, turns, urgent, digests, folds, acked, batched, outcomes
    }' "$FM_WAKE_MEASURE_LOG" 2>/dev/null
}

# fm_wake_batch_append <kind> <key> <payload> [nonurgent|relay-batch]
# Queue one non-urgent row and record it as batched, atomically under the queue
# lock. A row identical to one still queued adds nothing the drain would not
# already present, so it is not appended again. A secondmate outcome must also
# match the batch class, so queued progress cannot hide its deferred-row counter.
fm_wake_batch_append() {
  local kind=$1 key=$2 payload=$3 class=${4:-nonurgent} status=0 seq clean_key clean_payload
  case "$class" in nonurgent|relay-batch|secondmate-outcome) ;; *) return 1 ;; esac
  clean_key=$(printf '%s' "$key" | fm_wake_clean_field)
  clean_payload=$(printf '%s' "$payload" | fm_wake_clean_field)
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || return 1
  if awk -F '\t' -v k="$kind" -v key="$clean_key" -v p="$clean_payload" \
    -v class="$class" -v record="$FM_WAKE_BATCH_RECORD" '
    BEGIN { while ((getline line < record) > 0) { split(line, f, "\t"); classes[f[1]] = f[3] } }
    NF >= 5 && $3 == k && $4 == key && $5 == p && (class != "secondmate-outcome" || classes[$2] == class) { found = 1 }
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
    printf '%s\t%s\t%s\n' "$seq" "$(date +%s)" "$class" >> "$FM_WAKE_BATCH_RECORD" || status=$?
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  [ "$status" -ne 0 ] || fm_wake_measure batched "$class" "$kind $key"
  return "$status"
}

# Print "<seq>\t<epoch>\t<class>" for every batched row still queued, and prune record
# lines whose row is gone. Caller holds FM_WAKE_QUEUE_LOCK.
_fm_wake_batch_live_locked() {
  local tmp
  [ -s "$FM_WAKE_BATCH_RECORD" ] || return 0
  tmp=$(mktemp "$STATE/.wake-batch.tmp.XXXXXX") || return 1
  awk -F '\t' -v keep="$tmp" '
    FNR == NR { if (NF >= 5 && $2 ~ /^[0-9]+$/) queued[$2] = 1; next }
    $1 ~ /^[0-9]+$/ && ($1 in queued) && !seen[$1]++ { print > keep; print $1 "\t" $2 "\t" $3 }
  ' "$FM_WAKE_QUEUE" "$FM_WAKE_BATCH_RECORD" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  if [ -s "$tmp" ]; then
    _fm_atomic_replace "$tmp" "$FM_WAKE_BATCH_RECORD" || { rm -f -- "$tmp"; return 1; }
  else
    rm -f -- "$tmp" "$FM_WAKE_BATCH_RECORD"
  fi
}

# Print the digest reason and return 0 once the oldest batched row still queued
# has waited its class window and no digest for that class was raised inside it.
# Returns 1 when nothing is due. The digest runs whether or not the switch is
# on, so switching classification off strands no batched row.
fm_wake_batch_digest_due() {
  local live now oldest count last relay_last due suffix=
  [ -s "$FM_WAKE_BATCH_RECORD" ] || return 1
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || return 1
  live=$(_fm_wake_batch_live_locked) || live=
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  [ -n "$live" ] || return 1
  now=$(date +%s)
  last=$(cat "$FM_WAKE_BATCH_LAST" 2>/dev/null || echo 0)
  relay_last=$(cat "$STATE/.wake-relay-batch-last" 2>/dev/null || echo 0)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  case "$relay_last" in ''|*[!0-9]*) relay_last=0 ;; esac
  due=$(printf '%s\n' "$live" | awk -F '\t' -v now="$now" -v normal="$FM_WAKE_BATCH_SECS" \
    -v last="$last" -v relay_last="$relay_last" -v classify_on="$(fm_wake_classify_enabled && echo 1)" \
    -v relay_on="$(fm_wake_relay_batch_enabled && fm_wake_classify_enabled && echo 1)" '
    $3 == "secondmate-outcome" && classify_on == 1 { next }
    $3 == "relay-batch" {
      if (relay_on != 1 || (now - $2 >= 3600 && now - relay_last >= 3600)) relay=1
      next
    }
    now - $2 >= normal && now - last >= normal { normal_due=1 }
    END { if (relay) print "relay-batch"; else if (normal_due) print "nonurgent" }')
  [ -n "$due" ] || return 1
  oldest=$(printf '%s\n' "$live" | awk -F '\t' 'NR == 1 || $2 < m { m = $2 } END { print m + 0 }')
  count=$(printf '%s\n' "$live" | awk 'END { print NR }')
  [ "$due" != relay-batch ] || suffix=" (relay-batch)"
  printf 'check: wake digest: %s batched non-urgent wake row(s) queued, oldest %ss%s\n' "$count" "$((now - oldest))" "$suffix"
}

# Remember actual delivery, independently for the two window lengths.
fm_wake_batch_digest_mark() {  # [reason]
  case "${1:-}" in
    *'(relay-batch)') date +%s > "$STATE/.wake-relay-batch-last" 2>/dev/null || true ;;
    *) date +%s > "$FM_WAKE_BATCH_LAST" 2>/dev/null || true ;;
  esac
}

# The watcher's routine self-acknowledgement. Best effort: the drain owns the
# queue, claim, and recovery-generation mechanics (`--ack-routine-folded`), and
# a refusal or a held lock leaves every row queued for the next tick.
fm_wake_routine_ack_tick() {  # <drain-script>
  local out cutoff
  # shellcheck disable=SC2034 # Read by the watcher's digest tick.
  FM_WAKE_ROUTINE_ACK_HELD=0
  [ -s "$FM_WAKE_FOLD_RECORD" ] || return 0
  # Spawn the drain only when some recorded routine row has actually aged.
  cutoff=$(( $(date +%s) - FM_WAKE_FOLD_DIGEST_SECS ))
  # A record line whose row is no longer queued is stale and spawns nothing.
  awk -F '\t' -v cutoff="$cutoff" -v queue="$FM_WAKE_QUEUE" '
    BEGIN { while ((getline line < queue) > 0) { n = split(line, f, "\t"); if (n >= 5) queued[f[2]] = 1 } }
    ($3 == "own-outbound" || $3 == "check-repeat") && $2 ~ /^[0-9]+$/ && $2 + 0 <= cutoff && ($1 in queued) { due = 1 }
    END { exit due ? 0 : 1 }' "$FM_WAKE_FOLD_RECORD" 2>/dev/null || return 0
  # A failing drain must not silence the rows: fall back to the fold digest.
  out=$(FM_SUPERVISION_ACTOR=main "$1" --ack-routine-folded "$FM_WAKE_FOLD_DIGEST_SECS" 2>/dev/null) || {
    # shellcheck disable=SC2034 # Read by the watcher's digest tick.
    FM_WAKE_ROUTINE_ACK_HELD=1
    return 0
  }
  [ -z "$out" ] || triage_log "$out"
  # The drain holds when unread status lines are pending: those need a model
  # turn, so the caller falls back to the fold digest for them.
  # shellcheck disable=SC2034 # Read by the watcher's digest tick.
  case "$out" in *'ROUTINE-HELD:'*) FM_WAKE_ROUTINE_ACK_HELD=1 ;; esac
  return 0
}
