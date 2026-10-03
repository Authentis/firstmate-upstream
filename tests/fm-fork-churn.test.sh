#!/usr/bin/env bash
# Regression bounds on the processes the remote transport and supervision loops
# create while they wait. Each loop polls on a short cadence, so one avoidable
# external command per tick is hundreds of short-lived processes a minute per
# waiting caller; on a busy host those dominate kernel CPU although each child
# costs almost nothing. Every helper the loops name goes through a counting
# shim (tests/fork-count-lib.sh), the loop runs steady-state, and the calls per
# second are compared with a bound.
#
# FC_REPORT=1 prints the measured table instead of asserting it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fork-count-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fork-count-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-fork-churn)
REMOTE_ROOT="$TMP_ROOT/remote-root"
ACCOUNT_HOME="$TMP_ROOT/account"
STATE_ROOT="$TMP_ROOT/jobs"
LANE_HOME="$TMP_ROOT/lane-home"
FC_LOG="$TMP_ROOT/exec.log"
export FC_LOG
SHIMS="$TMP_ROOT/shims"
BG_PIDS=()
WORKER_PID=
# shellcheck source=bin/fm-remote-job-lib.sh
. "$ROOT/bin/fm-remote-job-lib.sh"
cleanup_fork_churn() {
  local pid
  for pid in "${BG_PIDS[@]:-}"; do
    [ -z "$pid" ] || kill "$pid" 2>/dev/null || true
  done
  if [ -f "$STATE_ROOT/worker.pid" ]; then
    fm_remote_job_stop_worker_tree "$(cat "$STATE_ROOT/worker.pid")" || true
  fi
  rm -rf -- "$TMP_ROOT"
}
trap cleanup_fork_churn EXIT
mkdir -p "$REMOTE_ROOT/bin" "$ACCOUNT_HOME" "$LANE_HOME"
fc_make_shims "$SHIMS"
: > "$FC_LOG"
REPORT=${FC_REPORT:-0}
ROWS=()

# Wait out startup, then count a steady-state window. Sets WIN_TOTAL (every
# shimmed call), WIN_TICKS (the loop's poll ticks at its configured cadence)
# and WIN_SECS. A tick is counted from the cadence, not from the sleeps the
# shim saw, so a slow shim cannot shrink the tick count and hide a regression.
window() { # <warmup-seconds> <window-seconds> <ticks-per-second>
  sleep "$1"
  fc_reset
  sleep "$2"
  WIN_TOTAL=$(fc_total)
  WIN_TICKS=$(( $2 * $3 ))
  WIN_SECS=$2
}

# <label> <bound-calls-per-tick>; judges the last window. A tick is one pass of
# the loop, so the bound does not move with host load or shim overhead.
record() {
  local label=$1 bound=$2 per_tick per_sec
    per_tick=$(fc_per_tick "$WIN_TOTAL" 0 "$WIN_TICKS")
  per_sec=$(fc_per_tick "$WIN_TOTAL" 0 "$WIN_SECS")
  ROWS+=("$label|$per_tick calls/tick|$per_sec calls/s|$WIN_TICKS ticks|limit $bound|$(fc_breakdown)")
  [ "$REPORT" = 1 ] && return 0
  awk -v r="$per_tick" -v b="$bound" 'BEGIN { exit !(r <= b) }' \
    || fail "$label ran $per_tick commands a tick (limit $bound): $(fc_breakdown)"
}

REAL_GIT=$(command -v git)
cp "$ROOT/bin/fm-remote-job-lib.sh" "$ROOT/bin/fm-remote-job-worker.sh" \
  "$ROOT/bin/fm-remote-entrypoint.sh" "$ROOT/bin/fm-remote-delta-read.sh" "$REMOTE_ROOT/bin/"
printf 'fixture\n' > "$REMOTE_ROOT/AGENTS.md"
# The worker is #!/bin/bash, Bash 3.2 on stock macOS, where printf %(%s)T is
# missing and the clock read forks date; the fixture runs it under the Bash that
# runs this test, as a Linux host's /bin/bash would, so the builtin clock read
# is what gets measured.
{ printf '#!/usr/bin/env bash\n'; tail -n +2 "$ROOT/bin/fm-remote-job-worker.sh"; } > "$REMOTE_ROOT/bin/fm-remote-job-worker.sh"
cat > "$REMOTE_ROOT/bin/fm-hold-job.sh" <<'SH'
#!/bin/bash
sleep "$1"
SH
chmod +x "$REMOTE_ROOT/bin"/*.sh
"$REAL_GIT" -C "$REMOTE_ROOT" init -q -b main
"$REAL_GIT" -C "$REMOTE_ROOT" config user.email test@example.com
"$REAL_GIT" -C "$REMOTE_ROOT" config user.name Test
"$REAL_GIT" -C "$REMOTE_ROOT" add AGENTS.md bin
"$REAL_GIT" -C "$REMOTE_ROOT" commit -qm 'fork churn fixture'

# --- fm-remote-delta-read.sh: a long-poll on an unchanged log ---------------
DELTA_HOME="$TMP_ROOT/delta-home"
mkdir -p "$DELTA_HOME/logs"
printf 'hello\n' > "$DELTA_HOME/logs/x.log"
PREFIX=$(printf 'hello\n' | shasum -a 256 | cut -d' ' -f1)
PATH="$SHIMS:$PATH" FM_HOME="$DELTA_HOME" \
  "$REMOTE_ROOT/bin/fm-remote-delta-read.sh" logs/x.log 6 "$PREFIX" 14 > /dev/null 2>&1 &
BG_PIDS+=("$!")
window 2 6 2
kill "${BG_PIDS[0]}" 2>/dev/null || true
record "fm-remote-delta-read.sh long-poll" "${FC_BOUND_DELTA:-2.5}"

# --- worker: idle serve loop, then a running job's lane --------------------
start_worker() { # <path-prefix>
  HOME="$ACCOUNT_HOME" PATH="$1:${BASH%/*}:/usr/bin:/bin:/usr/sbin:/sbin" FC_LOG="$FC_LOG" \
    FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT" \
    FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
    "$BASH" "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" --serve > "$TMP_ROOT/worker.out" 2> "$TMP_ROOT/worker.err" &
  WORKER_PID=$!
  BG_PIDS+=("$WORKER_PID")
  for _ in $(seq 1 100); do
    [ -f "$STATE_ROOT/worker.ready" ] && break
    sleep 0.05
  done
  [ -f "$STATE_ROOT/worker.ready" ] || fail "the worker did not become ready"
}
stop_worker() {
  fm_remote_job_stop_worker_tree "$(cat "$STATE_ROOT/worker.pid")" || true
  kill "$WORKER_PID" 2>/dev/null || true
  wait "$WORKER_PID" 2>/dev/null || true
  rm -rf -- "$STATE_ROOT"
}
export FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux

stage_hold() { # <seconds>; sets JOB
  fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$LANE_HOME" fm-hold-job.sh "$1" < /dev/null > /dev/null
  JOB=$FM_REMOTE_JOB_ID
}

# Worker shimmed: idle first, then with a running job (its lane polls).
start_worker "$SHIMS"
window 3 6 1
record "fm-remote-job-worker.sh idle serve loop" "${FC_BOUND_WORKER_IDLE:-2}"
stage_hold 14
for _ in $(seq 1 100); do
  [ "$(fm_remote_job_read_state "$STATE_ROOT/jobs/$JOB" 2>/dev/null || true)" = running ] && break
  sleep 0.1
done
window 2 6 4
record "fm-remote-job-worker.sh --lane running a job" "${FC_BOUND_LANE:-2}"
stop_worker

# Worker unshimmed, entrypoint shimmed: the caller's wait loop on a running job.
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
ARGV_B64=$(printf 'fm-hold-job.sh\0%s\0' 20 | base64 | tr -d '\n')
# The entrypoint starts the worker itself, and a worker inherits the starting
# caller's PATH, so start it from an unshimmed call first.
HOME="$ACCOUNT_HOME" PATH="${BASH%/*}:/usr/bin:/bin:/usr/sbin:/sbin" \
  "$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" 1 "$(b64 "$REMOTE_ROOT")" "$(b64 "$LANE_HOME")" \
  "$(printf 'fm-hold-job.sh\0%s\0' 0 | base64 | tr -d '\n')" > /dev/null 2>&1 || fail "the unshimmed entrypoint call failed"
HOME="$ACCOUNT_HOME" PATH="$SHIMS:${BASH%/*}:/usr/bin:/bin:/usr/sbin:/sbin" FC_LOG="$FC_LOG" \
  "$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" 1 "$(b64 "$REMOTE_ROOT")" "$(b64 "$LANE_HOME")" "$ARGV_B64" \
  > "$TMP_ROOT/entry.out" 2> "$TMP_ROOT/entry.err" &
BG_PIDS+=("$!")
for _ in $(seq 1 200); do
  for JOB_DIR in "$STATE_ROOT"/jobs/job-*; do
    [ "$(fm_remote_job_read_state "$JOB_DIR" 2>/dev/null || true)" = running ] && break 2
  done
  sleep 0.1
done
window 1 6 4
record "fm-remote-entrypoint.sh waiting on a job" "${FC_BOUND_ENTRY:-1.5}"
stop_worker

# --- fm-supervision-host.sh: parked on a healthy watcher cycle -------------
# The real host and libraries run in a copy of bin/ whose watcher arm is a stub
# that reports itself started and then stays up, so the host only waits.
HOST_HOME="$TMP_ROOT/host-home"
HOST_BIN="$TMP_ROOT/host-bin"
mkdir -p "$HOST_HOME/state" "$HOST_HOME/config" "$HOST_BIN"
cp "$ROOT"/bin/*.sh "$ROOT"/bin/*.mjs "$HOST_BIN/" 2>/dev/null || true
cp -R "$ROOT/bin/backends" "$HOST_BIN/" 2>/dev/null || true
printf 'fixture\n' > "$HOST_HOME/AGENTS.md"
cat > "$HOST_BIN/fm-watch-arm.sh" <<'SH'
#!/bin/bash
printf 'watcher: started pid=%s\n' "$$"
exec /bin/sleep 40
SH
chmod +x "$HOST_BIN/fm-watch-arm.sh"
ln -s /bin/bash "$TMP_ROOT/claude"
FM_HOME="$HOST_HOME" FM_ROOT_OVERRIDE="$HOST_HOME" PATH="$SHIMS:$PATH" FC_LOG="$FC_LOG" \
  FM_SUPERVISION_HOST_PRIMARY=claude HOST_SCRIPT="$HOST_BIN/fm-supervision-host.sh" \
  "$TMP_ROOT/claude" -c '
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    "$HOST_SCRIPT" park
  ' > "$TMP_ROOT/host.out" 2> "$TMP_ROOT/host.err" &
BG_PIDS+=("$!")
window 3 6 2
record "fm-supervision-host.sh parked on a watcher" "${FC_BOUND_HOST:-1.5}"
kill "${BG_PIDS[${#BG_PIDS[@]}-1]}" 2>/dev/null || true

if [ "$REPORT" = 1 ]; then
  cat "$TMP_ROOT/entry.err" "$TMP_ROOT/host.err" "$TMP_ROOT/host.out" >&2
  printf '%s\n' "${ROWS[@]}"
fi
pass "waiting loops stay within their per-second process bounds"
