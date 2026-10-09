#!/usr/bin/env bash
# Probe: under a job-control caller, which process groups exist when TERM lands mid fm_run_timed.
set -u
cd "$1" || exit 1
R=$(mktemp -d /tmp/fmrun.XXXX); T=$(mktemp -d /tmp/fmT.XXXX)
cat > "$R/timeout" <<'STUB'
#!/bin/sh
while [ "${1#-}" != "$1" ]; do case $1 in -k|-s) shift 2;; *) shift;; esac; done
secs=$1; shift
exec perl -e 'setpgrp(0,0); alarm shift; exec @ARGV' "$secs" "$@"
STUB
chmod +x "$R/timeout"
set -m
( . bin/fm-timeout-lib.sh; export TMPDIR="$T"
  _fm_timeout_signal_cleanup() { echo "handler: sig=$1 me=$BASHPID pgid=$(ps -o pgid= -p $BASHPID) groups=[${_FM_TMO_GROUP:-}] depth=${#FUNCNAME[@]}" >&2; [ "${#FUNCNAME[@]}" -lt 6 ] || exit 99; local g; for g in ${_FM_TMO_GROUP:-}; do kill -TERM -- "-$g"; done; rm -f -- $_FM_TMO_FILES; exit $((128+$1)); }
  PATH="$R:$PATH" fm_run_timed 4 sleep 33 ) & pid=$!
sleep 0.5
ps -o pid,pgid,command -g "$pid" 2>/dev/null; ps -axo pid,pgid,ppid,command | grep -E 'sleep 33|fm_run|bash -c' | grep -v grep
kill -TERM $pid; wait $pid; echo "rc=$?"
pkill -f 'sleep 33'; rm -rf "$R" "$T"
