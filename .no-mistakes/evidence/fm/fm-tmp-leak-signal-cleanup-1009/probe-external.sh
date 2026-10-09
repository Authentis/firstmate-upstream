#!/usr/bin/env bash
# Probe: TERM a fm_run_timed external-timeout run with and without caller job control.
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
for m in +m -m; do
  set $m
  ( . bin/fm-timeout-lib.sh; export TMPDIR="$T"; PATH="$R:$PATH" fm_run_timed 4 sleep 32 ) & pid=$!
  sleep 0.5
  kill -TERM $pid; wait $pid 2>/dev/null; rc=$?
  echo "caller set $m: rc=$rc left=[$(ls "$T" | tr '\n' ' ')] sleep-procs=$(pgrep -f 'sleep 32' | wc -l | tr -d ' ')"
  pkill -f 'sleep 32'; find "$T" -mindepth 1 -delete
done
set +m
rm -rf "$R" "$T"
bash --version | head -1
