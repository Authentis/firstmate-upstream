#!/usr/bin/env bash
# A real tmux server can retain descriptors received from its client after the
# client times out. The user-visible absence deadline must still return a safe
# refusal without waiting for that server to resume. Oracle: the documented
# FM_CONTROL_ABSENCE_DEADLINE, not the implementation's timeout exit status.
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "${1:-}" != --isolated ]; then
  if [ "$(uname -s)" != Linux ] || ! command -v unshare >/dev/null 2>&1 \
    || ! command -v tmux >/dev/null 2>&1 || ! command -v timeout >/dev/null 2>&1; then
    echo 'skip - real tmux deadline regression needs Linux, unshare, tmux and timeout'
    exit 0
  fi
  if ! unshare --user --map-root-user --pid --fork --mount-proc true 2>/dev/null; then
    echo 'skip - real tmux deadline regression needs permission to create private user/PID/mount namespaces'
    exit 0
  fi
  exec unshare --user --map-root-user --pid --fork --mount-proc bash "$0" --isolated
fi

# The real kernel /proc contains only this fixture's processes. No operator
# servers or process-table stubs participate in the proof.
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-deadline.XXXXXX")
SERVER='' WATCHDOG=''
cleanup() {
  [ -z "$SERVER" ] || kill -CONT "$SERVER" 2>/dev/null || true
  if [ -n "$WATCHDOG" ]; then
    kill "$WATCHDOG" 2>/dev/null || true
    wait "$WATCHDOG" 2>/dev/null || true
  fi
  tmux -S "$LAB/controller" kill-server 2>/dev/null || true
  tmux -S "$LAB/foreign" kill-server 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT
mkdir -p "$LAB/home/state" "$LAB/task" "$LAB/user"
export FM_HOME="$LAB/home" HOME="$LAB/user" SHELL=/bin/bash
git init -q "$LAB/task"
unset FM_CONTROL_PROC_ROOT FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
# Each server has a private explicit socket, never the user's default server.
env -u TMUX tmux -S "$LAB/controller" -f /dev/null new-session -d -s controller -c "$LAB"
TMUX="$(tmux -S "$LAB/controller" display-message -p '#{socket_path},#{pid},0')"
export TMUX
tmux -S "$LAB/foreign" -f /dev/null new-session -d -s foreign -c "$LAB"
SERVER=$(tmux -S "$LAB/foreign" display-message -p '#{pid}')
printf 'window=gone:fm-deadlineproof\nworktree=%s\nproject=%s\nharness=claude\nkind=ship\n' "$LAB/task" "$LAB/task" > "$FM_HOME/state/deadlineproof.meta"
kill -STOP "$SERVER"
# A rescue timer bounds the PRE-FIX regression as well. It is deliberately
# longer than the contract and is always reaped before this test exits.
(sleep 8; kill -CONT "$SERVER" 2>/dev/null || true) &
WATCHDOG=$!
start=$SECONDS
rc=0
out=$(FM_CONTROL_ABSENCE_DEADLINE=2 "$ROOT/bin/fm-control.sh" deadlineproof exit 2>&1) || rc=$?
elapsed=$((SECONDS - start))
printf '%s\nexit=%s elapsed=%ss (absence deadline=2s, rescue=8s)\n' "$out" "$rc" "$elapsed"
[ "$rc" -ne 0 ] || fail 'an unresponsive server must refuse, not claim endpoint-gone'
assert_contains "$out" 'did not answer within the 2s deadline' 'the refusal must identify the unresponsive real server'
[ "$elapsed" -le 5 ] || fail 'the refusal waited for the stopped server instead of honoring the absence deadline'
pass 'tmux: an unresponsive real server refuses within its absence deadline'
