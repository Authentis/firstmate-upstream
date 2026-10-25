#!/usr/bin/env bash
# Generic installed entrypoint.  It pins one immutable bundle for the full
# invocation and passes its lock FD/root to nested wrappers.
set -eu
H=${FM_HOME:?FM_HOME must be explicit}
case "$H" in /*) ;; *) printf '%s\n' 'router bundle: FM_HOME must be absolute' >&2; exit 75;; esac
[ ! -e "$H/data/router-off" ] || { printf '%s\n' router-off; exit 0; }
N=$(basename -- "$0")
if [ -n "${ROUTER_BUNDLE_ROOT:-}" ]; then
  R=$ROUTER_BUNDLE_ROOT
  LOCKED=1
else
  exec 9>>"$H/state/router-dispatch.lock"
  flock -s 9
  [ ! -e "$H/data/router-off" ] || { printf '%s\n' router-off; exit 0; }
  R=$(readlink -f -- "$H/data/router-current" 2>/dev/null || true)
  LOCKED=0
fi
case "$R" in "$H"/data/router-bundles/*) ;; *) printf '%s\n' 'router bundle: invalid current pointer' >&2; exit 75;; esac
[ -x "$R/data/bin/$N" ] || { printf '%s\n' 'router bundle: entrypoint missing' >&2; exit 75; }
[ ! -e "$H/data/router-off" ] || { printf '%s\n' router-off; exit 0; }
export ROUTER_BUNDLE_ROOT="$R" ROUTER_BIN="$R/data/bin" FLEET_YAML="$R/config/fleet.yaml"
# This wrapper shell remains the lock owner while the direct entrypoint runs.
# The child closes FD 9 before exec, so neither it nor workers it spawns can
# retain the shared lock after this invocation returns.  Nested wrappers
# inherit the pinned root and therefore neither repick the pointer nor re-lock.
if [ "$LOCKED" = 0 ]; then
  ( exec 9>&-; exec "$R/data/bin/$N" "$@" )
  exit $?
fi
exec "$R/data/bin/$N" "$@"
