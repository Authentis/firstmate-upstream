#!/usr/bin/env bash
# fm-unified-exec-contain.sh - contain 64-slot saturation in the Pi unified-exec runtime.
#
# Usage: fm-unified-exec-contain.sh status [PKG_DIR]
#        fm-unified-exec-contain.sh check  [PKG_DIR]
#        fm-unified-exec-contain.sh apply  [PKG_DIR]
#
# The slot store is the in-memory SessionStore of the pi-unified-exec package
# (default PKG_DIR: ~/.pi/agent/npm/node_modules/pi-unified-exec), held inside
# each running Pi process; nothing outside that process can list or reap it.
# apply installs, idempotently and only after every anchor matches, two changes:
#   - exited records are reaped on a timer (default every 60s), keeping the
#     newest PI_UNIFIED_EXEC_REAP_KEEP (default 8) exited records;
#     only a record with a known exit code or signal and no armed on_exit wake
#     is reaped, a live session never is, and each reap is appended to
#     PI_UNIFIED_EXEC_REAP_LOG (default ~/.pi/agent/unified-exec-reap.log);
#   - the LRU never evicts the firstmate watch timer (fm-watch*.sh) or any live
#     session with an armed on_exit wake; if every candidate is pinned the
#     store exceeds its cap instead of evicting.
# Originals are kept once as <file>.fm-orig. A running Pi must be restarted to
# load the change; a package update replaces the files, so rerun apply after it.
# status is read-only: it reports the package, patch state, the reap log tally,
# and the live watch-timer processes visible to ps.
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
D="$HERE/fm-unified-exec-contain.d"
cmd=${1:-status}
pkg=${2:-$HOME/.pi/agent/npm/node_modules/pi-unified-exec}

case "$cmd" in
  apply | check | status) ;;
  *)
    echo "usage: ${0##*/} status|check|apply [PKG_DIR]" >&2
    exit 64
    ;;
esac
[ -f "$pkg/src/session-store.ts" ] && [ -f "$pkg/src/index.ts" ] || {
  echo "not a pi-unified-exec package: $pkg" >&2
  exit 2
}
command -v node >/dev/null 2>&1 || {
  echo "node is required" >&2
  exit 2
}

if [ "$cmd" = status ]; then
  version=$(sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([^"]*\)".*/\1/p' "$pkg/package.json" 2>/dev/null | head -n 1)
  state=$(node "$D/patch.mjs" check "$pkg" "$D/reap.ts" 2>&1)
  log=${PI_UNIFIED_EXEC_REAP_LOG:-$HOME/.pi/agent/unified-exec-reap.log}
  echo "package: $pkg (version ${version:-unknown})"
  echo "containment: $state"
  echo "slot cap: $(sed -n 's/^const MAX_SESSIONS = \([0-9]*\);.*/\1/p' "$pkg/src/index.ts" | head -n 1)"
  if [ -f "$log" ]; then echo "reaps logged: $(wc -l <"$log" | tr -d ' ') ($log)"; else echo "reaps logged: 0 (no log yet)"; fi
  echo "watch-timer processes:"
  pgrep -fl 'fm-watch(-arm)?\.sh' | cut -c1-160 || true
  exit 0
fi

node "$D/patch.mjs" "$cmd" "$pkg" "$D/reap.ts"
