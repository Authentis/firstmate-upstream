#!/usr/bin/env bash
# Print the context size and session age of a secondmate's primary Claude session.
#
# Usage: fm-sm-context.sh <secondmate-id> [--help]
#        fm-sm-context.sh --probe            (host-local half, reads FM_HOME)
#
# Read-only. The size is the last assistant message's usage in the newest
# session transcript under the secondmate home's Claude projects directory:
# input_tokens + cache_read_input_tokens + cache_creation_input_tokens, which is
# what each wake replays. The age is the time since that transcript's first
# timestamped record.
#
# Output (one line, key=value, stable for the sm-context check):
#   id=<id> tokens=<N|unknown> age_s=<S|unknown> harness=<name> session=<uuid|->
#
# A remote route is probed by running this same script's --probe half in the
# secondmate's home through bin/fm-on.sh, never a raw ssh string; an unreachable
# host or one whose code root predates this script reports unknown. A secondmate
# whose recorded harness is not claude reports tokens=unknown. FM_CLAUDE_CONFIG_DIR
# overrides CLAUDE_CONFIG_DIR / ~/.claude as the transcript root, and
# FM_SM_CONTEXT_ON overrides bin/fm-on.sh; both are test seams.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
REG="$DATA/secondmates.md"

# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

usage() { sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

iso_to_epoch() {
  local ts=${1%%.*}
  ts=${ts%Z}
  date -u -d "${ts}Z" +%s 2>/dev/null \
    || date -u -j -f '%Y-%m-%dT%H:%M:%S' "$ts" +%s 2>/dev/null
}

# Probe the Claude transcripts of the home in $1; print "tokens age_s session".
probe_home() {
  local home=$1 cfg dir newest line ts first usage in cr cc
  cfg=${FM_CLAUDE_CONFIG_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}
  dir="$cfg/projects/$(printf '%s' "$home" | sed 's/[^A-Za-z0-9]/-/g')"
  # shellcheck disable=SC2012 # transcript names are uuids
  newest=$(ls -t "$dir"/*.jsonl 2>/dev/null | head -1)
  [ -n "$newest" ] || { echo "unknown unknown -"; return 0; }
  line=$(grep '"type":"assistant"' "$newest" | grep '"usage":{' | tail -1)
  [ -n "$line" ] || { echo "unknown unknown -"; return 0; }
  usage=$(printf '%s' "$line" | grep -o '"usage":{.*' | head -c 600)
  field() { printf '%s' "$usage" | grep -o "\"$1\":[0-9]*" | head -1 | cut -d: -f2; }
  in=$(field input_tokens); cr=$(field cache_read_input_tokens); cc=$(field cache_creation_input_tokens)
  first=$(grep -m1 -o '"timestamp":"[^"]*"' "$newest" | cut -d'"' -f4)
  ts=$(iso_to_epoch "$first")
  if [ -n "$ts" ]; then ts=$(( $(date +%s) - ts )); else ts=unknown; fi
  echo "$(( ${in:-0} + ${cr:-0} + ${cc:-0} )) $ts $(basename "$newest" .jsonl)"
}

case "${1:-}" in
  --help|-h|'') usage ;;
  --probe)
    printf '%s\n' "$(probe_home "$FM_HOME")"
    exit 0 ;;
esac

ID=$1
case "$ID" in *[!A-Za-z0-9._-]*|-*) echo "error: invalid secondmate id" >&2; exit 2 ;; esac
[ -f "$REG" ] || { echo "error: no secondmate registry at $REG" >&2; exit 1; }
home= remote=0
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in '- '*) ;; *) continue ;; esac
  secondmate_registry_parse_line "$line" || continue
  [ "$SECONDMATE_REGISTRY_ID" = "$ID" ] || continue
  home=$SECONDMATE_REGISTRY_HOME remote=$SECONDMATE_REGISTRY_REMOTE
done < "$REG"
[ -n "$home" ] || { echo "error: no secondmate '$ID' in the registry" >&2; exit 1; }

harness=$(sed -n 's/^harness=//p' "$STATE/$ID.meta" 2>/dev/null | head -1)
harness=${harness:-claude}
result="unknown unknown -"
if [ "$harness" = claude ]; then
  if [ "$remote" -eq 1 ]; then
    out=$("${FM_SM_CONTEXT_ON:-$SCRIPT_DIR/fm-on.sh}" "$ID" fm-sm-context.sh --probe 2>/dev/null | tail -1)
  else
    out=$(FM_HOME=$home "$0" --probe 2>/dev/null | tail -1)
  fi
  case "$out" in
    [0-9]*' '*' '*) result=$out ;;
    unknown\ *' '*) result=$out ;;
  esac
fi
read -r tokens age session <<<"$result"
printf 'id=%s tokens=%s age_s=%s harness=%s session=%s\n' "$ID" "$tokens" "$age" "$harness" "$session"
