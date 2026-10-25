#!/usr/bin/env bash
# chief 4726: lane-refill.service ExecStart target; the router v3 flow is lane-refill-v2.sh. Pass-through wrapper (exec keeps the flock and the args).
# chief 4727: data/refill-hold makes a non-dry-run start a no-op (a manual service start must not run live).
H=${FM_HOME:-/home/holu/fm-secondmate-upstream-20260907}
export FM_HOME=$H
B=${ROUTER_BIN:-$H/data/bin}
export ROUTER_BIN=$B
[ -e "$H/data/router-off" ] && { echo "router-off"; exit 0; }
if [ -e "$H/data/refill-hold" ]; then
  case " $* " in
    *" --dry-run "*) ;;
    *) [ "${DRY:-0}" = 1 ] || { echo "lane-refill: data/refill-hold present, not running live"; exit 0; } ;;
  esac
fi
exec /bin/bash "$B/lane-refill-v2.sh" "$@"
