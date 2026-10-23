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
# links has no failover and its pane is never read.
#
# Behavior, per mate with a chain:
#   - Detection: the last FM_QUOTA_FAILOVER_LINES (30) captured pane lines are
#     matched against the provider-quota signatures (fm_quota_failover_matches).
#     Signature lines already on screen when the mate was relaunched are
#     recorded in state/.quota-failover-<id>.stale and ignored until a capture
#     shows none, because the replacement shares the old endpoint's scrollback.
#   - Window: the first sighting is recorded durably in
#     state/.quota-failover-<id>, so the sustained window survives watcher
#     restarts. A clear capture resets it.
#   - Advance: a signature sustained for FM_QUOTA_FAILOVER_WINDOW_SECS (300)
#     rewrites the mate's keyed pin in config/secondmate-harness to the next
#     link and restarts the mate through bin/fm-secondmate-restart.sh
#     --failover, the persist-first restart owner. No separate restart path
#     exists here. A failed restart restores the previous pin and re-arms.
#   - Exhausted: on the last link a sustained signature re-arms the window and
#     reports, but changes nothing.
#   - Return: a mate on a later link whose captures stay free of every
#     signature for FM_QUOTA_FAILOVER_RESET_SECS (18000, one common provider
#     window) is moved back to link 0 through the ordinary persist-gated
#     restart, so a mate that cannot confirm its open work keeps running where
#     it is. A pool that has not reset simply fails over again.
#
# State file fields (key=value): link=<n>, first_seen=<epoch|empty>,
# clear_since=<epoch|empty>. Teardown of the mate may remove it; an absent
# file means link 0 with no sighting.
#
# Environment knobs:
#   FM_QUOTA_FAILOVER_WINDOW_SECS    sustained-signature window (300)
#   FM_QUOTA_FAILOVER_RESET_SECS     clear period before returning to link 0 (18000)
#   FM_QUOTA_FAILOVER_PERSIST_WAIT   persist-answer wait passed to the restart (120)
#   FM_QUOTA_FAILOVER_LINES          pane lines read per check (30)
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

# Print the lines of <text> that carry a provider-quota signature: an HTTP 429
# status (as a standalone number), the exceeded_current_quota error code, or a
# "usage limit" message, case-insensitively.
fm_quota_failover_matches() {  # <text>
  printf '%s\n' "$1" | grep -Ei \
    '(^|[^0-9A-Za-z])429([^0-9A-Za-z]|$)|exceeded_current_quota|usage[ _-]limit'
}

# Succeeds when <text> carries a provider-quota signature.
fm_quota_failover_signature() {  # <text>
  fm_quota_failover_matches "$1" >/dev/null
}

# A relaunch reuses the same endpoint, so the replaced agent's error text can
# stay in the captured scrollback. Succeeds when every signature line in
# <matches> (counting repeats) was already recorded in <stale-file> at the
# relaunch, so those lines prove nothing about the new link.
fm_quota_failover_stale() {  # <matches> <stale-file>
  [ -f "$2" ] || return 1
  printf '%s\n' "$1" | awk 'NR == FNR { n[$0]++; next } { if (--n[$0] < 0) bad = 1 } END { exit bad }' "$2" -
}

# Print the chain for <id>, one "<harness> <model> <effort>" line per link in
# order. Fails on a malformed line rather than selecting around it.
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
    if [ "${#f[@]}" -ne 4 ]; then
      echo "error: malformed config/secondmate-quota-chain line: $line" >&2
      return 2
    fi
    case "${f[1]}/${f[2]}" in default/*|-/*|*/default|*/-)
      echo "error: secondmate-quota-chain link for ${f[0]} requires a concrete harness and model" >&2
      return 2 ;;
    esac
    case "${f[3]}" in low|medium|high|xhigh|max|ultra) ;; *)
      echo "error: invalid secondmate-quota-chain effort for ${f[0]}: ${f[3]}" >&2
      return 2 ;;
    esac
    [ "${f[0]}" != "$id" ] || printf '%s %s %s\n' "${f[1]}" "${f[2]}" "${f[3]}"
  done < "$file"
}

fm_quota_failover_state_file() {  # <id>
  printf '%s/.quota-failover-%s\n' "${STATE:?}" "$1"
}

# Load FM_QF_LINK, FM_QF_FIRST_SEEN, FM_QF_CLEAR_SINCE for <id>.
fm_quota_failover_load() {  # <id>
  local file key value
  FM_QF_LINK=0 FM_QF_FIRST_SEEN='' FM_QF_CLEAR_SINCE=''
  file=$(fm_quota_failover_state_file "$1")
  [ -f "$file" ] || return 0
  while IFS='=' read -r key value; do
    case "$value" in *[!0-9]*) value='' ;; esac
    case "$key" in
      link) FM_QF_LINK=${value:-0} ;;
      first_seen) FM_QF_FIRST_SEEN=$value ;;
      clear_since) FM_QF_CLEAR_SINCE=$value ;;
    esac
  done < "$file"
}

fm_quota_failover_save() {  # <id>
  local file tmp
  file=$(fm_quota_failover_state_file "$1")
  tmp="$file.tmp.$$"
  printf 'link=%s\nfirst_seen=%s\nclear_since=%s\n' \
    "$FM_QF_LINK" "$FM_QF_FIRST_SEEN" "$FM_QF_CLEAR_SINCE" > "$tmp" \
    && mv -f "$tmp" "$file"
}

# Replace (or add) the keyed pin for <id> in config/secondmate-harness with
# "<harness> <model> <effort>", preserving every other line and its order.
fm_quota_failover_write_pin() {  # <id> <profile>
  local id=$1 profile=$2 config file tmp line written=0
  local -a f
  config=$(fm_quota_failover_config)
  file="$config/secondmate-harness"
  tmp=$(mktemp "$config/.secondmate-harness.XXXXXX") || return 1
  if [ -f "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      read -r -a f <<< "$line"
      if [ "${#f[@]}" -eq 4 ] && [ "${f[0]}" = "$id" ]; then
        printf '%s %s\n' "$id" "$profile" >> "$tmp"
        written=1
      else
        printf '%s\n' "$line" >> "$tmp"
      fi
    done < "$file"
  fi
  [ "$written" = 1 ] || printf '%s %s\n' "$id" "$profile" >> "$tmp"
  mv -f "$tmp" "$file"
}

# Pure decision step. Given the current capture verdict, update the loaded
# state for <id> and set FM_QF_ACTION to none, advance, exhausted, or return,
# with FM_QF_TARGET naming the link to move to.
fm_quota_failover_decide() {  # <id> <links> <quota:0|1> <now>
  local id=$1 links=$2 quota=$3 now=$4 window reset last
  window=$(fm_quota_failover_knob "${FM_QUOTA_FAILOVER_WINDOW_SECS:-}" 300)
  reset=$(fm_quota_failover_knob "${FM_QUOTA_FAILOVER_RESET_SECS:-}" 18000)
  last=$((links - 1))
  FM_QF_ACTION=none FM_QF_TARGET=''
  fm_quota_failover_load "$id"
  [ "$FM_QF_LINK" -le "$last" ] || FM_QF_LINK=$last
  if [ "$quota" = 1 ]; then
    FM_QF_CLEAR_SINCE=''
    if [ -z "$FM_QF_FIRST_SEEN" ]; then
      FM_QF_FIRST_SEEN=$now
    elif [ $((now - FM_QF_FIRST_SEEN)) -ge "$window" ]; then
      if [ "$FM_QF_LINK" -lt "$last" ]; then
        FM_QF_ACTION=advance FM_QF_TARGET=$((FM_QF_LINK + 1))
      else
        FM_QF_ACTION=exhausted FM_QF_TARGET=$FM_QF_LINK
        FM_QF_FIRST_SEEN=$now
      fi
    fi
  else
    FM_QF_FIRST_SEEN=''
    [ -n "$FM_QF_CLEAR_SINCE" ] || FM_QF_CLEAR_SINCE=$now
    if [ "$FM_QF_LINK" -gt 0 ] && [ $((now - FM_QF_CLEAR_SINCE)) -ge "$reset" ]; then
      FM_QF_ACTION=return FM_QF_TARGET=0
    fi
  fi
}

# Capture the recorded endpoint's last pane lines, local or remote.
fm_quota_failover_capture() {  # <meta> <id>
  local meta=$1 id=$2 lines backend target
  lines=$(fm_quota_failover_knob "${FM_QUOTA_FAILOVER_LINES:-}" 30)
  if [ -n "$(fm_meta_get "$meta" remote_host)" ]; then
    "$FM_QF_LIB_DIR/fm-on.sh" "$id" fm-remote-secondmate-control.sh capture "$id" "$lines" < /dev/null 2>/dev/null
    return
  fi
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || target=$(fm_meta_get "$meta" window)
  [ -n "$target" ] || return 1
  fm_backend_capture "$backend" "$target" "$lines" "fm-$id" 2>/dev/null
}

# Move <id> to chain link <target> (of the chain in <chain-text>) and restart it
# persist-first. <mode> failover lets the restart proceed when the wedged mate
# cannot answer the persist request; <mode> ordinary keeps the ordinary gate.
# On a failed restart the previous pin and link are restored. Sets FM_QF_OUT.
fm_quota_failover_apply() {  # <id> <chain-text> <target> <failover|ordinary> <now>
  local id=$1 chain=$2 target=$3 mode=$4 now=$5 profile previous wait rc=0
  local -a args
  profile=$(printf '%s\n' "$chain" | sed -n "$((target + 1))p")
  previous=$(printf '%s\n' "$chain" | sed -n "$((FM_QF_LINK + 1))p")
  wait=$(fm_quota_failover_knob "${FM_QUOTA_FAILOVER_PERSIST_WAIT:-}" 120)
  FM_QF_OUT=''
  fm_quota_failover_write_pin "$id" "$profile" || { FM_QF_OUT="the secondmate pin could not be rewritten"; return 1; }
  args=("$id")
  [ "$mode" != failover ] || args=(--failover "$id")
  FM_QF_OUT=$(FM_STATE_OVERRIDE="$STATE" FM_CONFIG_OVERRIDE="$(fm_quota_failover_config)" \
    FM_SECONDMATE_PERSIST_WAIT=$wait "$FM_QF_LIB_DIR/fm-secondmate-restart.sh" "${args[@]}" 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then
    FM_QF_LINK=$target FM_QF_FIRST_SEEN='' FM_QF_CLEAR_SINCE=$now
    return 0
  fi
  fm_quota_failover_write_pin "$id" "$previous" || true
  FM_QF_FIRST_SEEN='' FM_QF_CLEAR_SINCE=''
  [ "$mode" != failover ] || FM_QF_FIRST_SEEN=$now
  [ "$mode" != ordinary ] || FM_QF_CLEAR_SINCE=$now
  return "$rc"
}

# fm_quota_failover_tick <meta> <id> [now]
#
# One check of one live mate. Sets FM_QF_REPORT to a one-line outcome worth a
# supervisor wake (empty when nothing happened) and returns nonzero only when
# the check itself could not run.
fm_quota_failover_tick() {  # <meta> <id> [now]
  local meta=$1 id=$2 now=${3:-} chain links pane matches stale quota=0 rc=0 detail
  FM_QF_REPORT=''
  [ -n "$now" ] || now=$(date +%s)
  chain=$(fm_quota_failover_chain "$id") || { FM_QF_REPORT="quota failover chain config is malformed; no failover for $id"; return 1; }
  links=$(printf '%s' "$chain" | grep -c .)
  [ "$links" -ge 2 ] || return 0
  pane=$(fm_quota_failover_capture "$meta" "$id") || return 0
  stale="$(fm_quota_failover_state_file "$id").stale"
  matches=$(fm_quota_failover_matches "$pane") || true
  if [ -z "$matches" ]; then
    [ ! -f "$stale" ] || rm -f -- "$stale"
  elif ! fm_quota_failover_stale "$matches" "$stale"; then
    quota=1
  fi
  fm_quota_failover_decide "$id" "$links" "$quota" "$now"
  case "$FM_QF_ACTION" in
    advance|return)
      local from=$FM_QF_LINK mode=failover
      [ "$FM_QF_ACTION" = advance ] || mode=ordinary
      fm_quota_failover_apply "$id" "$chain" "$FM_QF_TARGET" "$mode" "$now" || rc=$?
      detail=$(printf '%s\n' "$FM_QF_OUT" | grep -E '^(restarted|nudged|unreached|summary):' | head -1)
      if [ "$rc" -eq 0 ]; then
        [ -z "$matches" ] || printf '%s\n' "$matches" > "$stale" || true
        if [ "$mode" = failover ]; then
          FM_QF_REPORT="check: secondmate $id quota failover from chain link $from to link $FM_QF_TARGET after a provider quota error persisted"
        else
          FM_QF_REPORT="check: secondmate $id returned to chain link 0 after its quota cleared"
        fi
      else
        FM_QF_REPORT="check: secondmate $id quota $FM_QF_ACTION to chain link $FM_QF_TARGET did not complete; pin restored to link $from: ${detail:-restart exit $rc}"
      fi
      ;;
    exhausted)
      FM_QF_REPORT="check: secondmate $id still shows a provider quota error on the last chain link; no further fallback"
      ;;
  esac
  fm_quota_failover_save "$id" || { FM_QF_REPORT="${FM_QF_REPORT:+$FM_QF_REPORT; }quota failover state for $id could not be saved"; return 1; }
  return 0
}
