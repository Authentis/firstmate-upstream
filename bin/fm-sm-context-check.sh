#!/usr/bin/env bash
# Watcher check: wake when a secondmate's Claude context has grown too long.
#
# Usage: fm-sm-context-check.sh        (run by the home-local state/sm-context.check.sh shim)
#
# Probes every registered secondmate with bin/fm-sm-context.sh and prints one
# line per mate that has crossed FM_SM_CONTEXT_TOKENS (default 150000) or
# FM_SM_CONTEXT_AGE_S (default 21600, six hours) since its session start, naming
# the exact restart command to run. A mate is reported at most once per
# FM_SM_CONTEXT_COOLDOWN_S (default 21600) seconds, recorded in
# state/.sm-context-last-<id>. It never restarts anything; an unknown reading
# prints nothing. Silent when no mate is over a threshold.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
REG="$DATA/secondmates.md"
MAX_TOKENS=${FM_SM_CONTEXT_TOKENS:-150000}
MAX_AGE=${FM_SM_CONTEXT_AGE_S:-21600}
COOLDOWN=${FM_SM_CONTEXT_COOLDOWN_S:-21600}

# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
[ -f "$REG" ] || exit 0
now=$(date +%s)
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in '- '*) ;; *) continue ;; esac
  secondmate_registry_parse_line "$line" || continue
  id=$SECONDMATE_REGISTRY_ID
  stamp="$STATE/.sm-context-last-$id"
  if [ -f "$stamp" ]; then
    last=$(cat "$stamp" 2>/dev/null)
    case "$last" in ''|*[!0-9]*) ;; *) [ $((now - last)) -lt "$COOLDOWN" ] && continue ;; esac
  fi
  out=$("$SCRIPT_DIR/fm-sm-context.sh" "$id" 2>/dev/null) || continue
  tokens=$(printf '%s\n' "$out" | sed -n 's/.* tokens=\([^ ]*\).*/\1/p')
  age=$(printf '%s\n' "$out" | sed -n 's/.* age_s=\([^ ]*\).*/\1/p')
  why=
  case "$tokens" in ''|*[!0-9]*) ;; *) [ "$tokens" -ge "$MAX_TOKENS" ] && why="$tokens tokens" ;; esac
  case "$age" in ''|*[!0-9]*) ;; *) [ "$age" -ge "$MAX_AGE" ] && why="${why:+$why, }session age $((age / 3600))h" ;; esac
  [ -n "$why" ] || continue
  printf '%s\n' "$now" > "$stamp"
  echo "sm-context: $id Claude context is long ($why); when it is idle or between turns run: bin/fm-secondmate-restart.sh $id"
done < "$REG"
exit 0
