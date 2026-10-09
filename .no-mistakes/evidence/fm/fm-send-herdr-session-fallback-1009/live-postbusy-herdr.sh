#!/usr/bin/env bash
# Live drive: real Claude lane in an isolated fm-lab Herdr session; the real
# fm-watch.sh inbox_steer_check runs against it while busy, then once idle.
# Usage: live-postbusy-herdr.sh <bin-dir-under-test> <label>
set -u
BIN=$1; LABEL=$2
ROOT=/Users/lundi/.no-mistakes/worktrees/0d3d213d42f1/01M4GMZXZA2W0YM66J6T6XS0A3
LAB_HELPER=$ROOT/bin/fm-herdr-lab.sh
. "$ROOT/tests/herdr-test-safety.sh"; herdr_forget_inherited_pane
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name "pb-$LABEL")
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
FAKEBIN="$LAB/fakebin"; mkdir -p "$FAKEBIN"
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
cleanup() {
  trap - EXIT
  PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION" && log "teardown ok: $SESSION"
  rm -rf "$LAB"
}
trap cleanup EXIT

{
  printf '#!/usr/bin/env bash\n'
  printf 'SESSION=%q; ORIGINAL_PATH=%q; LAB_HELPER=%q\n' "$SESSION" "$ORIGINAL_PATH" "$LAB_HELPER"
  cat <<'W'
args=("$@"); n=${#args[@]}
if [ "$n" -ge 2 ] && [ "${args[$((n-2))]}" = --session ]; then
  [ "${args[$((n-1))]}" = "$SESSION" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("${args[@]:0:$((n-2))}")
else
  echo "wrapper requires trailing --session" >&2; exit 98
fi
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "${args[@]}"
W
} > "$FAKEBIN/herdr"
chmod +x "$FAKEBIN/herdr"

"$LAB_HELPER" provision "$SESSION" >/dev/null || { log "provision failed"; exit 1; }
log "lab session $SESSION provisioned; code under test: $BIN"
lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
WS=$(lab workspace create --cwd "$LAB" --label fm-pb --no-focus)
PANE=$(printf '%s' "$WS" | jq -er '.result.root_pane.pane_id')
TAB=$(printf '%s' "$WS" | jq -r '.result.root_pane.tab_id // .result.tab.tab_id // empty')
WSID=$(printf '%s' "$WS" | jq -r '.result.root_pane.workspace_id // .result.workspace.workspace_id // empty')
lab pane run "$PANE" "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions" >/dev/null
agent_status() { lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty'; }
trusted=0; ok=0
for i in $(seq 1 60); do
  s=$(lab pane read "$PANE" --source visible 2>/dev/null || true)
  case "$s" in
    *'bypass permissions on'*) case "$(agent_status)" in idle|done) ok=1; break ;; esac ;;
    *'trust this folder'*) [ "$trusted" = 1 ] || { trusted=1; lab pane send-keys "$PANE" down enter >/dev/null; } ;;
  esac
  sleep 1
done
[ "$ok" = 1 ] || { log "claude never idle"; lab pane read "$PANE" --source visible; exit 1; }
log "Claude $(claude --version | head -1) idle in herdr pane $PANE (session $SESSION)"

STATE="$LAB/state"
cat > "$STATE/t1.meta" <<M
window=$SESSION:$PANE
kind=ship
harness=claude
backend=herdr
herdr_session=$SESSION
herdr_workspace_id=$WSID
herdr_tab_id=$TAB
herdr_pane_id=$PANE
M
REC=$(FM_HOME="$LAB" bash -c '. "$1/fm-task-inbox-lib.sh" && fm_task_inbox_write "$2" t1 "Gate run is waiting: please run the review fix"' _ "$BIN" "$STATE")
touch -t 202601010000 "$REC"
log "steer record written: ${REC#"$LAB"/}"

doorbells() { lab pane read "$PANE" --source recent --lines 400 2>/dev/null | grep -c 'Firstmate instruction waiting' || true; }
due() { FM_HOME="$LAB" FM_TASK_INBOX_GRACE_SECS=0 FM_TASK_INBOX_BUSY_MAX=2 bash -c '. "$1/fm-task-inbox-lib.sh"; fm_task_inbox_due_action "$2" t1' _ "$BIN" "$STATE"; }
check() {  # one fresh watcher process, like the poll loop after a restart
  PATH="$FAKEBIN:$ORIGINAL_PATH" FM_HOME="$LAB" FM_TASK_INBOX_GRACE_SECS=0 FM_TASK_INBOX_BUSY_MAX=2 \
    bash -c '. "$1/fm-watch.sh" && inbox_steer_check "$2" t1' _ "$BIN" "$SESSION:$PANE" >>"$LAB/check.out" 2>&1
  log "watcher poll done: agent_status=$(agent_status) next-due=[$(due)] wakes=$(wc -l < "$STATE/.wake-queue" 2>/dev/null | tr -d ' ') busy-escalated-mark=$(cat "$STATE/t1.inbox/.busy-escalated" 2>/dev/null || echo none) doorbells-in-pane=$(doorbells)"
}

PROMPT=${PB_PROMPT:-"Use the Bash tool to run exactly: sleep 60 . Then reply with the single word SLEPT."}
lab pane send-text "$PANE" "$PROMPT" >/dev/null
sleep 1; lab pane send-keys "$PANE" enter >/dev/null
for i in $(seq 1 30); do [ "$(agent_status)" = working ] && break; sleep 1; done
log "lane busy (agent_status=$(agent_status)); polling the watcher while busy"
check; sleep 3; check
log "wake-queue after the busy polls:"; cat "$STATE/.wake-queue" 2>/dev/null
sleep 3; check; sleep 3; check
if [ "${PB_MODE:-}" = long ]; then
  for k in 1 2 3 4 5 6; do sleep 4; check; done
fi
if [ "${PB_MODE:-}" = ack ]; then
  mv "$REC" "$STATE/t1.inbox/handled/" && log "ADVERSARIAL: record acknowledged while the lane is still busy (agent_status=$(agent_status))"
fi
log "waiting for the lane to go idle"
for i in $(seq 1 120); do case "$(agent_status)" in idle|done) break ;; esac; sleep 1; done
sleep 2
log "lane idle (agent_status=$(agent_status)); polling the watcher"
check
for i in $(seq 1 20); do case "$(agent_status)" in working) break ;; esac; sleep 1; done
for i in $(seq 1 120); do case "$(agent_status)" in idle|done) break ;; esac; sleep 1; done
sleep 2; check; sleep 3; check
log "triage log (steer-inbox lines):"; grep -i 'steer-inbox' "$STATE/.watch-triage.log" 2>/dev/null
log "watcher stderr/stdout:"; cat "$LAB/check.out"
log "final wake-queue:"; cat "$STATE/.wake-queue" 2>/dev/null
log "pane screen (recent, non-blank):"; lab pane read "$PANE" --source recent --lines 80 2>/dev/null | grep -v '^[[:space:]]*$' | tail -40
log "RESULT label=$LABEL doorbells-in-pane=$(doorbells) wakes=$(wc -l < "$STATE/.wake-queue" | tr -d ' ')"
