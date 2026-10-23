#!/usr/bin/env bash
# shellcheck disable=SC2034 # FM_QF_* output globals are read by sourcing callers.
# fm-quota-failover-lib.sh - provider-quota failover for persistent secondmates.
#
# A coordinator whose provider pool is exhausted stays "alive" to every
# liveness classifier: its agent process runs, it simply answers every turn
# with a quota error. Liveness recovery never fires for it, so without this
# library such a mate sits wedged until a human notices. bin/fm-watch.sh's
# secondmate liveness pass drives fm_quota_failover_tick for every mate it
# reads alive.
#
# The fallback chain is local data, never code: config/secondmate-quota-chain
# holds ordered lines in the keyed secondmate-pin shape
#
#   <id> <harness> <model> <effort>
#
# and the lines for one id, in file order, are that mate's chain (link 0 first).
# Blank lines and lines starting with # are ignored. A mate with fewer than two
# links has no failover and its pane is never read. Only a mate's own lines are
# validated: a malformed one stops that mate's failover and is reported once as
# a check, and every other mate is unaffected.
#
# Behavior, per mate with a chain:
#   - Detection: the newest 12 non-blank pane lines are matched against the
#     provider-quota signatures (fm_quota_failover_matches), each anchored to
#     error context, so a quota error counts only while it is the agent's
#     latest output, not while it merely sits in scrollback. Signature lines on screen right after a
#     relaunch are recorded in state/.quota-failover-<id>.stale and ignored for
#     one window unless they repeat, because the replacement shares the old
#     endpoint's scrollback.
#   - Recurrence: each capture showing a signature is kept in
#     state/.quota-failover-<id>.seen. A sighting is a capture holding more
#     signature lines than the previous one, or one whose lines ending at the
#     newest signature line - bottom-aligned, over the length both captures
#     share - changed while that line stayed no farther from the bottom. Lines
#     below it are ignored, including their height: signature lines exposed at
#     the top of a full window only because lines below shrank are not
#     counted. A wedged agent
#     printing the same error every turn therefore keeps counting even once
#     that error fills the newest lines, while one static error line - a
#     relayed crew error, or the old agent's last words - never counts twice,
#     whether it sits unchanged, a spinner or status line below it redraws in
#     place or appears and clears, or the agent's later output scrolls it
#     upward. These recurrence
#     semantics are final. Known limitation: a strictly periodic wedge - the
#     same input every turn (such as only the fixed steering doorbell), a
#     byte-identical error reply, and a constant footer - shifts a full
#     12-line window by exactly one period, so consecutive captures are
#     identical and never recur. Line snapshots cannot tell that apart from a
#     static error line with an in-place redraw, which must not count. A local
#     mate in this wedge never consumes its inbox, so the watcher's secondmate
#     wake-loop stall check and the steering doorbell's re-ring escalation
#     still surface it. Neither covers a remote mate - the watcher skips
#     remote_host metas there and the remote steer leg has no watcher ladder -
#     so a remote mate in this wedge has only pending-reply recovery
#     escalation for sends that expect a reply, operator-side liveness and
#     context alarms outside this home, and periodic supervision review. The
#     planned follow-up is a turn-counted or cursor/history-position signal on
#     both capture paths.
#   - Window: the first sighting is recorded durably in
#     state/.quota-failover-<id>, so the sustained window survives watcher
#     restarts. A clear capture resets it.
#   - Advance: a signature first sighted at least FM_QUOTA_FAILOVER_WINDOW_SECS
#     (300) ago and sighted again since rewrites the mate's keyed pin in
#     config/secondmate-harness to the next link and restarts the mate through
#     bin/fm-secondmate-restart.sh --failover, the persist-first restart owner. No separate restart path
#     exists here. The target link is recorded before the pin moves. A restart
#     refused before the agent was touched restores the exact prior pin line
#     and re-arms, retrying each window and reporting once per refused
#     episode; one whose outcome is unknown keeps the target pin, so
#     liveness recovery relaunches onto that link rather than the exhausted one.
#   - Exhausted: on the last link a sustained signature is reported once per
#     episode. Once link 0's reset period (FM_QUOTA_FAILOVER_RESET_SECS) has
#     passed since the mate left it, the mate is moved back to link 0 the same
#     way it advances; a pool that has not reset simply fails over again.
#   - Return: a mate on a later link whose captures stay free of every
#     signature for FM_QUOTA_FAILOVER_RESET_SECS (18000, one common provider
#     window) is moved back to link 0 through the persist-gated restart, so a
#     mate that cannot confirm its open work within the persist wait keeps
#     running where it is and retries after the next clear period.
# Every restart here passes --no-nudge or --failover, so a mate that is not
# restarted is never sent the instruction-update re-read message.
#
# State file fields (key=value): link=<n>, first_seen=<epoch|empty>,
# recurred=<1|empty>,
# clear_since=<epoch|empty>, left0=<epoch the mate left link 0|empty>,
# episode=<exhausted|refused|malformed|empty>, stale_until=<epoch|empty>. Teardown of
# the mate may remove it; an absent file means link 0 with no sighting.
# state/.quota-failover-<id>.lock serializes checks of one mate, so an
# overlapping watcher pass skips a mate whose failover is still in flight.
#
# Environment knobs:
#   FM_QUOTA_FAILOVER_WINDOW_SECS    sustained-signature window (300)
#   FM_QUOTA_FAILOVER_RESET_SECS     provider reset period before returning to link 0 (18000)
#   FM_QUOTA_FAILOVER_PERSIST_WAIT   persist-answer wait for a failover or return restart (120)
#
# Callers set STATE and either FM_HOME or FM_CONFIG_OVERRIDE before sourcing.

set -u

FM_QF_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# shellcheck source=bin/fm-backend.sh
. "$FM_QF_LIB_DIR/fm-backend.sh"

fm_quota_failover_config() {
  printf '%s\n' "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
}

fm_quota_failover_knob() {  # <value> <default>
  case "$1" in ''|*[!0-9]*) printf '%s\n' "$2" ;; *) printf '%s\n' "$1" ;; esac
}

fm_quota_failover_require_locks() {
  command -v fm_lock_try_acquire >/dev/null 2>&1 && return 0
  # shellcheck source=bin/fm-wake-lib.sh
  . "$FM_QF_LIB_DIR/fm-wake-lib.sh"
}

# Print the lines of <text> that carry a provider-quota signature,
# case-insensitively: a 429 status in error context ("Error: 429",
# "status=429", "HTTP 429", "429 Too Many Requests"), the
# exceeded_current_quota error code, or a reached/exceeded usage limit. A bare
# 429 such as an issue or PR number is not a signature.
FM_QF_SIGNATURES=(
  -e '(error|status|http|code)["'"'"':=([:space:]]*(code[[:space:]:=]*)?429([^0-9]|$)'
  -e '(^|[^0-9])429[[:space:]]+too many requests'
  -e 'exceeded_current_quota'
  -e '(hit|reached|exceeded)[[:space:]]+(your|the)[[:space:]]+usage[ _-]limit'
  -e 'usage[ _-]limit[ _-](reached|exceeded|hit)'
)
FM_QF_LINES=12
fm_quota_failover_matches() {  # <text>
  printf '%s\n' "$1" | grep -Ei "${FM_QF_SIGNATURES[@]}"
}

# Succeeds when <text> carries a provider-quota signature.
fm_quota_failover_signature() {  # <text>
  fm_quota_failover_matches "$1" >/dev/null
}

# A relaunch reuses the same endpoint, so the replaced agent's error text can
# stay in the captured scrollback. Succeeds when every signature line in
# <matches> (counting repeats) was already recorded in <stale-file> at the
# relaunch, so those lines prove nothing about the new link.
fm_quota_failover_covered() {  # <matches> <stale-file>
  [ -s "$2" ] || return 1
  printf '%s\n' "$1" | awk 'NR == FNR { n[$0]++; next } { if (--n[$0] < 0) bad = 1 } END { exit bad }' "$2" -
}

# Print "<signature lines> <lines after the newest signature line> <its line
# number>" for <text>.
fm_quota_failover_shape() {  # <text>
  local total last count
  total=$(printf '%s\n' "$1" | grep -c '')
  count=$(printf '%s\n' "$1" | grep -Eic "${FM_QF_SIGNATURES[@]}")
  last=$(printf '%s\n' "$1" | grep -Ein "${FM_QF_SIGNATURES[@]}" | tail -n 1 | cut -d: -f1)
  printf '%s %s %s\n' "${count:-0}" "$((total - ${last:-$total}))" "${last:-0}"
}

# Succeeds when <pane> shows a new quota error against the capture recorded in
# <previous-file>: none was recorded, more signature lines are on screen, or
# the lines ending at the newest signature line, bottom-aligned over the
# length both captures share, changed while that line stayed no farther from
# the bottom - a fresh error printed where the last one was, rather than an
# old one scrolled upward by later output or one whose only change is below
# it. Lines a full window exposes at its top only because lines below it
# shrank are not counted.
fm_quota_failover_recurs() {  # <pane> <previous-file>
  local previous count after last previous_count previous_after previous_last common
  [ -f "$2" ] || return 0
  previous=$(cat "$2")
  read -r count after last <<< "$(fm_quota_failover_shape "$1")"
  read -r previous_count previous_after previous_last <<< "$(fm_quota_failover_shape "$previous")"
  if [ "$after" -lt "$previous_after" ] && [ "$(printf '%s\n' "$1" | grep -c '')" -ge "$FM_QF_LINES" ]; then
    count=$(printf '%s\n' "$1" | tail -n +"$((previous_after - after + 1))" | grep -Eic "${FM_QF_SIGNATURES[@]}")
  fi
  [ "$count" -gt "$previous_count" ] && return 0
  [ "$after" -le "$previous_after" ] || return 1
  common=$last
  [ "$previous_last" -ge "$common" ] || common=$previous_last
  [ "$(printf '%s\n' "$1" | head -n "$last" | tail -n "$common")" \
    != "$(printf '%s\n' "$previous" | head -n "$previous_last" | tail -n "$common")" ]
}

# Print the chain for <id>, one "<harness> <model> <effort>" line per link in
# order. Fails on a malformed line of <id> rather than selecting around it.
fm_quota_failover_chain() {  # <id>
  local id=$1 file line
  local -a f
  file="$(fm_quota_failover_config)/secondmate-quota-chain"
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    [ -n "$line" ] || continue
    case "$line" in '#'*) continue ;; esac
    read -r -a f <<< "$line"
    [ "${f[0]}" = "$id" ] || continue
    if [ "${#f[@]}" -ne 4 ]; then
      echo "error: malformed config/secondmate-quota-chain line: $line" >&2
      return 2
    fi
    case "${f[1]}/${f[2]}" in default/*|-/*|*/default|*/-)
      echo "error: secondmate-quota-chain link for $id requires a concrete harness and model" >&2
      return 2 ;;
    esac
    case "${f[3]}" in low|medium|high|xhigh|max|ultra) ;; *)
      echo "error: invalid secondmate-quota-chain effort for $id: ${f[3]}" >&2
      return 2 ;;
    esac
    printf '%s %s %s\n' "${f[1]}" "${f[2]}" "${f[3]}"
  done < "$file"
}

fm_quota_failover_state_file() {  # <id>
  printf '%s/.quota-failover-%s\n' "${STATE:?}" "$1"
}

# Load FM_QF_LINK, FM_QF_FIRST_SEEN, FM_QF_RECURRED, FM_QF_CLEAR_SINCE,
# FM_QF_LEFT0, FM_QF_EPISODE, and FM_QF_STALE_UNTIL for <id>.
fm_quota_failover_load() {  # <id>
  local file key value
  FM_QF_LINK=0 FM_QF_FIRST_SEEN='' FM_QF_RECURRED='' FM_QF_CLEAR_SINCE=''
  FM_QF_LEFT0='' FM_QF_EPISODE='' FM_QF_STALE_UNTIL=''
  file=$(fm_quota_failover_state_file "$1")
  [ -f "$file" ] || return 0
  while IFS='=' read -r key value; do
    if [ "$key" = episode ]; then
      case "$value" in exhausted|refused|malformed) FM_QF_EPISODE=$value ;; esac
      continue
    fi
    case "$value" in *[!0-9]*) value='' ;; esac
    case "$key" in
      link) FM_QF_LINK=${value:-0} ;;
      first_seen) FM_QF_FIRST_SEEN=$value ;;
      recurred) FM_QF_RECURRED=$value ;;
      clear_since) FM_QF_CLEAR_SINCE=$value ;;
      left0) FM_QF_LEFT0=$value ;;
      stale_until) FM_QF_STALE_UNTIL=$value ;;
    esac
  done < "$file"
}

fm_quota_failover_save() {  # <id>
  local file tmp
  file=$(fm_quota_failover_state_file "$1")
  tmp="$file.tmp.$$"
  printf 'link=%s\nfirst_seen=%s\nrecurred=%s\nclear_since=%s\nleft0=%s\nepisode=%s\nstale_until=%s\n' \
    "$FM_QF_LINK" "$FM_QF_FIRST_SEEN" "$FM_QF_RECURRED" "$FM_QF_CLEAR_SINCE" "$FM_QF_LEFT0" \
    "$FM_QF_EPISODE" "$FM_QF_STALE_UNTIL" > "$tmp" \
    && mv -f "$tmp" "$file"
}

# Print the keyed pin line for <id> in config/secondmate-harness exactly as
# written, or nothing when it has none.
fm_quota_failover_pin_line() {  # <id>
  local id=$1 file line
  local -a f
  file="$(fm_quota_failover_config)/secondmate-harness"
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    read -r -a f <<< "$line"
    if [ "${#f[@]}" -eq 4 ] && [ "${f[0]}" = "$id" ]; then
      printf '%s\n' "$line"
      return 0
    fi
  done < "$file"
}

# Replace the keyed pin for <id> in config/secondmate-harness with <line>, or
# remove it when <line> is empty, preserving every other line, their order,
# and the file's mode. A missing keyed pin is appended.
fm_quota_failover_put_pin() {  # <id> <line>
  local id=$1 new=$2 file tmp line written=0
  local -a f
  file="$(fm_quota_failover_config)/secondmate-harness"
  tmp="$(fm_quota_failover_config)/.secondmate-harness.$$"
  if [ -f "$file" ]; then
    cp -p "$file" "$tmp" || return 1
    while IFS= read -r line || [ -n "$line" ]; do
      read -r -a f <<< "$line"
      if [ "${#f[@]}" -eq 4 ] && [ "${f[0]}" = "$id" ]; then
        [ -z "$new" ] || printf '%s\n' "$new"
        written=1
      else
        printf '%s\n' "$line"
      fi
    done < "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
  else
    : > "$tmp" || return 1
  fi
  if [ "$written" = 0 ] && [ -n "$new" ]; then
    printf '%s\n' "$new" >> "$tmp" || { rm -f "$tmp"; return 1; }
  fi
  mv -f "$tmp" "$file"
}

# Pure decision step. Given the current capture verdict - whether a live
# signature is on screen and whether the signature lines changed since the
# last capture - update the loaded state and set FM_QF_ACTION to none,
# advance, wrap, exhausted, or return, with FM_QF_TARGET naming the link to
# move to.
fm_quota_failover_decide() {  # <links> <quota:0|1> <changed:0|1> <now>
  local links=$1 quota=$2 changed=$3 now=$4 window reset last
  window=$(fm_quota_failover_knob "${FM_QUOTA_FAILOVER_WINDOW_SECS:-}" 300)
  reset=$(fm_quota_failover_knob "${FM_QUOTA_FAILOVER_RESET_SECS:-}" 18000)
  last=$((links - 1))
  FM_QF_ACTION=none FM_QF_TARGET=''
  [ "$FM_QF_LINK" -le "$last" ] || FM_QF_LINK=$last
  if [ "$quota" = 1 ]; then
    FM_QF_CLEAR_SINCE=''
    if [ "$changed" = 1 ]; then
      if [ -z "$FM_QF_FIRST_SEEN" ]; then FM_QF_FIRST_SEEN=$now; else FM_QF_RECURRED=1; fi
    fi
    if [ -n "$FM_QF_FIRST_SEEN" ] && [ "$FM_QF_RECURRED" = 1 ] \
      && [ $((now - FM_QF_FIRST_SEEN)) -ge "$window" ]; then
      if [ "$FM_QF_LINK" -lt "$last" ]; then
        FM_QF_ACTION=advance FM_QF_TARGET=$((FM_QF_LINK + 1))
      elif [ -n "$FM_QF_LEFT0" ] && [ $((now - FM_QF_LEFT0)) -ge "$reset" ]; then
        FM_QF_ACTION=wrap FM_QF_TARGET=0
      elif [ "$FM_QF_EPISODE" != exhausted ]; then
        FM_QF_ACTION=exhausted FM_QF_TARGET=$FM_QF_LINK FM_QF_EPISODE=exhausted
      fi
    fi
  else
    FM_QF_FIRST_SEEN='' FM_QF_RECURRED=''
    case "$FM_QF_EPISODE" in exhausted|refused) FM_QF_EPISODE='' ;; esac
    [ -n "$FM_QF_CLEAR_SINCE" ] || FM_QF_CLEAR_SINCE=$now
    if [ "$FM_QF_LINK" -gt 0 ] && [ $((now - FM_QF_CLEAR_SINCE)) -ge "$reset" ]; then
      FM_QF_ACTION=return FM_QF_TARGET=0
    fi
  fi
}

# Print the recorded endpoint's newest non-blank pane lines, local or remote.
fm_quota_failover_capture() {  # <meta> <id>
  local meta=$1 id=$2 lines=$FM_QF_LINES backend target pane
  if [ -n "$(fm_meta_get "$meta" remote_host)" ]; then
    pane=$("$FM_QF_LIB_DIR/fm-on.sh" "$id" fm-remote-secondmate-control.sh capture "$id" "$lines" < /dev/null 2>/dev/null) || return 1
  else
    backend=$(fm_backend_of_meta "$meta")
    target=$(fm_backend_target_of_meta "$meta")
    [ -n "$target" ] || target=$(fm_meta_get "$meta" window)
    [ -n "$target" ] || return 1
    pane=$(fm_backend_capture "$backend" "$target" "$lines" "fm-$id" 2>/dev/null) || return 1
  fi
  printf '%s\n' "$pane" | grep -v '^[[:space:]]*$' | tail -n "$lines"
}

# Move <id> to chain link <target> (of the chain in <chain-text>) and restart it
# persist-first. <mode> failover lets the restart proceed when the wedged mate
# cannot answer the persist request; <mode> ordinary keeps the ordinary gate.
# A restart refused before the agent was touched restores the prior pin line
# and link; an unknown outcome keeps the target and sets FM_QF_UNKNOWN=1.
# Sets FM_QF_OUT.
fm_quota_failover_apply() {  # <id> <chain-text> <target> <failover|ordinary> <now>
  local id=$1 chain=$2 target=$3 mode=$4 now=$5 profile prior wait rc=0
  local from=$FM_QF_LINK left0=$FM_QF_LEFT0 episode=$FM_QF_EPISODE recurred=$FM_QF_RECURRED
  local -a args=(--no-nudge "$id")
  profile=$(printf '%s\n' "$chain" | sed -n "$((target + 1))p")
  prior=$(fm_quota_failover_pin_line "$id")
  wait=$(fm_quota_failover_knob "${FM_QUOTA_FAILOVER_PERSIST_WAIT:-}" 120)
  FM_QF_OUT='' FM_QF_UNKNOWN=0
  FM_QF_LINK=$target FM_QF_FIRST_SEEN='' FM_QF_RECURRED='' FM_QF_EPISODE=''
  if [ "$target" -eq 0 ]; then
    FM_QF_LEFT0=''
  elif [ "$from" -eq 0 ]; then
    FM_QF_LEFT0=$now
  fi
  if ! fm_quota_failover_save "$id"; then
    FM_QF_OUT="the in-progress failover target could not be recorded"
    rc=1
  elif ! fm_quota_failover_put_pin "$id" "$id $profile"; then
    FM_QF_OUT="the secondmate pin could not be rewritten"
    rc=1
  else
    [ "$mode" != failover ] || args=(--failover "$id")
    FM_QF_OUT=$(FM_HOME="${FM_HOME:-}" FM_STATE_OVERRIDE="$STATE" FM_CONFIG_OVERRIDE="$(fm_quota_failover_config)" \
      FM_SECONDMATE_PERSIST_WAIT="$wait" "$FM_QF_LIB_DIR/fm-secondmate-restart.sh" "${args[@]}" 2>&1) || rc=$?
    if [ "$rc" -eq 0 ] || printf '%s\n' "$FM_QF_OUT" | grep -q '^unreached:'; then
      [ "$rc" -eq 0 ] || FM_QF_UNKNOWN=1
      FM_QF_CLEAR_SINCE=$now
      return "$rc"
    fi
  fi
  fm_quota_failover_put_pin "$id" "$prior" || true
  FM_QF_LINK=$from FM_QF_LEFT0=$left0 FM_QF_EPISODE=$episode FM_QF_RECURRED=$recurred
  FM_QF_FIRST_SEEN='' FM_QF_CLEAR_SINCE=''
  [ "$mode" != failover ] || FM_QF_FIRST_SEEN=$now
  [ "$mode" != ordinary ] || FM_QF_CLEAR_SINCE=$now
  return "$rc"
}

fm_quota_failover_persist() {  # <id>
  fm_quota_failover_save "$1" && return 0
  FM_QF_REPORT="${FM_QF_REPORT:+$FM_QF_REPORT; }quota failover state for $1 could not be saved"
  return 1
}

# Record the signature lines on screen right after a relaunch as stale for one
# window, or forget any stale record when none are.
fm_quota_failover_mark_stale() {  # <meta> <id> <stale-file> <now>
  local pane matches window
  window=$(fm_quota_failover_knob "${FM_QUOTA_FAILOVER_WINDOW_SECS:-}" 300)
  pane=$(fm_quota_failover_capture "$1" "$2") || pane=''
  matches=$(fm_quota_failover_matches "$pane") || true
  if [ -n "$matches" ] && printf '%s\n' "$matches" > "$3"; then
    FM_QF_STALE_UNTIL=$(($4 + window))
  else
    rm -f -- "$3"
    FM_QF_STALE_UNTIL=''
  fi
}

# One locked check of <id>; see fm_quota_failover_tick.
fm_quota_failover_check() {  # <meta> <id> <now> <chain-text> <malformed:0|1>
  local meta=$1 id=$2 now=$3 chain=$4 links pane matches stale seen quota=0 changed=0 rc=0 from mode detail
  fm_quota_failover_load "$id"
  if [ "$5" = 1 ]; then
    if [ "$FM_QF_EPISODE" != malformed ]; then
      FM_QF_EPISODE=malformed
      FM_QF_REPORT="check: secondmate $id quota failover chain in config/secondmate-quota-chain is malformed; no failover for it until its lines are fixed"
    fi
    fm_quota_failover_persist "$id"
    return
  fi
  [ "$FM_QF_EPISODE" != malformed ] || FM_QF_EPISODE=''
  links=$(printf '%s' "$chain" | grep -c .)
  pane=$(fm_quota_failover_capture "$meta" "$id") || { fm_quota_failover_persist "$id"; return; }
  stale="$(fm_quota_failover_state_file "$id").stale"
  if [ -n "$FM_QF_STALE_UNTIL" ] && [ "$now" -ge "$FM_QF_STALE_UNTIL" ]; then
    rm -f -- "$stale"
    FM_QF_STALE_UNTIL=''
  fi
  matches=$(fm_quota_failover_matches "$pane") || true
  if [ -z "$matches" ]; then
    rm -f -- "$stale"
    FM_QF_STALE_UNTIL=''
  elif ! fm_quota_failover_covered "$matches" "$stale"; then
    quota=1
  fi
  seen="$(fm_quota_failover_state_file "$id").seen"
  if [ "$quota" = 1 ]; then
    ! fm_quota_failover_recurs "$pane" "$seen" || changed=1
    printf '%s\n' "$pane" > "$seen" \
      || { FM_QF_REPORT="quota failover state for $id could not be saved"; return 1; }
  else
    rm -f -- "$seen"
  fi
  fm_quota_failover_decide "$links" "$quota" "$changed" "$now"
  case "$FM_QF_ACTION" in
    advance|wrap|return)
      from=$FM_QF_LINK mode=failover
      [ "$FM_QF_ACTION" != return ] || mode=ordinary
      fm_quota_failover_apply "$id" "$chain" "$FM_QF_TARGET" "$mode" "$now" || rc=$?
      detail=$(printf '%s\n' "$FM_QF_OUT" | grep -E '^(held|unreached|summary):' | head -1)
      [ -n "$detail" ] || detail=$(printf '%s\n' "$FM_QF_OUT" | sed -n '/./{p;q;}')
      if [ "$rc" -eq 0 ] || [ "$FM_QF_UNKNOWN" = 1 ]; then
        fm_quota_failover_mark_stale "$meta" "$id" "$stale" "$now"
      fi
      if [ "$rc" -eq 0 ]; then
        case "$FM_QF_ACTION" in
          advance) FM_QF_REPORT="check: secondmate $id quota failover from chain link $from to link $FM_QF_TARGET after a provider quota error persisted" ;;
          wrap) FM_QF_REPORT="check: secondmate $id quota failover back to chain link 0 from the exhausted last link $from after link 0's reset period" ;;
          return) FM_QF_REPORT="check: secondmate $id returned to chain link 0 after its quota cleared" ;;
        esac
        ! printf '%s\n' "$FM_QF_OUT" | grep -q '^unpersisted:' \
          || FM_QF_REPORT="$FM_QF_REPORT; restarted without a persist answer, so open work held only in its conversation may be lost"
      elif [ "$FM_QF_UNKNOWN" = 1 ]; then
        FM_QF_REPORT="check: secondmate $id quota $FM_QF_ACTION to chain link $FM_QF_TARGET has an unknown restart outcome; pin kept on link $FM_QF_TARGET: ${detail:-restart exit $rc}"
      else
        [ "$FM_QF_EPISODE" = refused ] \
          || FM_QF_REPORT="check: secondmate $id quota $FM_QF_ACTION to chain link $FM_QF_TARGET did not complete; pin restored to link $from: ${detail:-restart exit $rc}"
        FM_QF_EPISODE=refused
      fi
      ;;
    exhausted)
      FM_QF_REPORT="check: secondmate $id still shows a provider quota error on the last chain link; no further fallback until link 0's reset period passes"
      ;;
  esac
  fm_quota_failover_persist "$id"
}

# fm_quota_failover_tick <meta> <id> [now]
#
# One check of one live mate. Sets FM_QF_REPORT to a one-line outcome worth a
# supervisor wake (empty when nothing happened) and returns nonzero only when
# the check itself could not run. A mate whose check is already in flight in
# another pass is skipped.
fm_quota_failover_tick() {  # <meta> <id> [now]
  local meta=$1 id=$2 now=${3:-} chain malformed=0 lock rc=0
  FM_QF_REPORT=''
  [ -n "$now" ] || now=$(date +%s)
  chain=$(fm_quota_failover_chain "$id" 2>/dev/null) || malformed=1
  [ "$malformed" = 1 ] || [ "$(printf '%s' "$chain" | grep -c .)" -ge 2 ] || return 0
  fm_quota_failover_require_locks || { FM_QF_REPORT="quota failover lock helpers could not be loaded for $id"; return 1; }
  lock="$(fm_quota_failover_state_file "$id").lock"
  fm_lock_try_acquire "$lock" || return 0
  fm_quota_failover_check "$meta" "$id" "$now" "$chain" "$malformed" || rc=$?
  fm_lock_release "$lock" || true
  return "$rc"
}
