#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD; D="$ROOT/.live-validation"; LAB="$D/home"
export FM_HOME="$LAB" HOME="$D/user" CLAUDE_CONFIG_DIR="$D/user/claude" TMPDIR="$D/tmp"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE HERDR_ENV HERDR_PANE_ID HERDR_SESSION HERDR_SOCKET_PATH HERDR_TAB_ID HERDR_WORKSPACE_ID
SOCK=.live-validation/socket/s; OTHER=.live-validation/socket/other
export TMUX="$SOCK,0,0"
P=
cleanup() { [ -z "$P" ] || { kill "$P" 2>/dev/null || true; wait "$P" 2>/dev/null || true; }; tmux -S "$OTHER" kill-server 2>/dev/null || true; tmux -S "$SOCK" kill-server 2>/dev/null || true; }
trap cleanup EXIT
tmux -S "$SOCK" new-session -d -s fm-lab-recover -n primary -x 100 -y 30 -c "$ROOT"
python3 - "$LAB/state/recover.meta" <<'PY'
import sys
p=sys.argv[1]
s=open(p).read().splitlines()
open(p,'w').write('\n'.join('window=vanished:fm-recover' if x.startswith('window=') else x for x in s)+'\n')
PY
refuse() {
 local label=$1 match=$2 out rc
 printf '\n=== %s ===\n' "$label"
 before=$(sha256sum "$LAB/state/recover.meta")
 set +e; out=$(bin/fm-spawn.sh recover --relaunch 2>&1); rc=$?; set -e
 printf '%s\nexit=%s\n' "$out" "$rc"
 test "$rc" != 0; [[ "$out" == *"$match"* ]]
 test "$(sha256sum "$LAB/state/recover.meta")" = "$before"
 test "$(tmux -S "$SOCK" list-windows -a -F '#{window_name}' | wc -l)" = 1
}
tmux -S "$OTHER" new-session -d -s fm-lab-foreign -n survivor -x 100 -y 30 -c "$ROOT"
tmux -S "$OTHER" send-keys -t fm-lab-foreign:survivor "cd '$D/worker'" Enter
for i in $(seq 1 100); do [ "$(tmux -S "$OTHER" display-message -p -t fm-lab-foreign:survivor '#{pane_current_path}')" != "$D/worker" ] || break; sleep .02; done
refuse 'Foreign socket process cwd prevents duplicate recovery' 'working in the recorded worktree'
tmux -S "$OTHER" kill-server
python3 -c 'import time; time.sleep(90)' fm-recover & P=$!
refuse 'Process task-name token prevents duplicate recovery' 'names the task'
kill "$P"; wait "$P" 2>/dev/null || true; P=
python3 -c 'import time; time.sleep(90)' "$D/worker/task-file" & P=$!
refuse 'Process worktree argument prevents duplicate recovery' 'names the recorded worktree'
kill "$P"; wait "$P" 2>/dev/null || true; P=
tmux -S "$SOCK" new-window -d -t fm-lab-recover -n fm-recover -c "$ROOT"
printf '\n=== Same-named window prevents recovery ===\n'
set +e; out=$(bin/fm-spawn.sh recover --relaunch 2>&1); rc=$?; set -e
printf '%s\nexit=%s\n' "$out" "$rc"; test "$rc" != 0; [[ "$out" == *'window named'* ]]
tmux -S "$SOCK" kill-window -t fm-lab-recover:fm-recover
python3 -c 'import ctypes,time; ctypes.CDLL(None).prctl(4,0); time.sleep(90)' & P=$!
# Await prctl readiness by observing the actual unreadable cwd.
for i in $(seq 1 100); do if ! readlink "/proc/$P/cwd" >/dev/null; then break; fi; sleep .02; done
refuse 'Unreadable non-allowlisted live process cwd refuses absence proof' 'could not be read'
kill "$P"; wait "$P" 2>/dev/null || true; P=
printf '\n=== Pre-publication trust failure removes replacement, preserves record ===\n'
printf 'invalid json\n' > "$CLAUDE_CONFIG_DIR/../.claude.json"
# Trust helper uses CLAUDE_CONFIG_DIR/.claude.json when an explicit dir is set.
printf 'invalid json\n' > "$CLAUDE_CONFIG_DIR/.claude.json"
refuse 'Invalid trust store triggers recovery abort cleanup' 'could not pre-register Claude workspace trust'
rm "$CLAUDE_CONFIG_DIR/.claude.json" "$CLAUDE_CONFIG_DIR/../.claude.json"
printf '\n=== Retrying the same recovery after repairing lab trust ===\n'
bin/fm-spawn.sh recover --relaunch
cat "$LAB/state/recover.meta"
sleep 3
tmux -S "$SOCK" capture-pane -p -t fm-lab-recover:fm-recover
printf '\n=== All duplicate guards and abort/retry checks passed ===\n'
