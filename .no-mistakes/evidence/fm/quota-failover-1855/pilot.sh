#!/usr/bin/env bash
# usage: pilot.sh <worktree> <scenario: advance|refused|badlink|exactid>
set -u
WT=$1 SC=$2
LAB=$(cd "$(mktemp -d /tmp/fm-lab.XXXXXX)" && pwd -P)
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 9
TD=$("$WT/bin/fm-lab-home.sh" tmux-dir "$LAB")
export TMUX_TMPDIR=$TD FM_HOME=$LAB
unset TMUX FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
cleanup() { tmux kill-server 2>/dev/null; "$WT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1; rm -rf "$LAB"; }
trap cleanup EXIT
STATE=$LAB/state CFG=$LAB/config
ID=mate-one
add_mate() {  # <id>
  local id=$1 sm=$LAB/sm-$1
  mkdir -p "$sm/state" "$sm/data" "$LAB/data/$id"
  git -C "$sm" init -q 2>/dev/null
  printf '%s\n' "$id" > "$sm/.fm-secondmate-home"; printf '# agents\n' > "$sm/AGENTS.md"; printf '# charter\n' > "$LAB/data/$id/brief.md"
  printf '%s\n' "window=fmlab:fm-$id" "endpoint_task_id=$id" "worktree=$sm" "project=$sm" "harness=claude" \
    "kind=secondmate" "mode=secondmate" "yolo=off" "model=default" "effort=default" "home=$sm" "backend=tmux" > "$STATE/$id.meta"
  if tmux has-session -t fmlab 2>/dev/null; then tmux new-window -d -t fmlab -n "fm-$id" /tmp/fmqf-driver/fake-agent.pl
  else tmux new-session -d -s fmlab -n "fm-$id" -x 200 -y 50 /tmp/fmqf-driver/fake-agent.pl; fi
}
inject() { tmux send-keys -t "fmlab:fm-$1" "$2" Enter; sleep 0.5; }
tick() {  # runs the watcher's entry point the way fm-watch.sh calls it
  ( export STATE; . "$WT/bin/fm-quota-failover-lib.sh"
    fm_quota_failover_tick "$STATE/$1.meta" "$1"; rc=$?
    echo "tick($1) rc=$rc report=${FM_QF_REPORT:-<none>}" )
}
show() { echo "--- pin: $(grep "^$ID " "$CFG/secondmate-harness" || echo '<none>')"; echo "--- state:"; sed 's/^/    /' "$STATE/.quota-failover-$ID" 2>/dev/null || echo "    <none>"; }
export FM_QUOTA_FAILOVER_WINDOW_SECS=${PILOT_WINDOW:-4} FM_QUOTA_FAILOVER_PERSIST_WAIT=3 FM_SECONDMATE_PERSIST_POLL=1
add_mate $ID
printf '%s\n' "$ID claude claude-sonnet-5-5 high" > "$CFG/secondmate-harness"
case "$SC" in
  badlink) printf '%s\n' "$ID claude claude-sonnet-5-5 high" "$ID muse muse-model low" > "$CFG/secondmate-quota-chain" ;;
  *) printf '%s\n' "$ID claude claude-sonnet-5-5 high" "$ID codex gpt-6.1-sol low" "$ID claude claude-opus-5-5 high" > "$CFG/secondmate-quota-chain" ;;
esac
if [ "$SC" = exactid ]; then
  add_mate fm-alpha; add_mate alpha
  printf '%s\n' "fm-alpha claude claude-sonnet-5-5 high" "fm-alpha codex gpt-6.1-sol low" >> "$CFG/secondmate-quota-chain"
  printf '%s\n' "fm-alpha claude claude-sonnet-5-5 high" "alpha claude claude-sonnet-5-5 high" >> "$CFG/secondmate-harness"
  ID=fm-alpha
fi
sleep 1
echo "=== scenario $SC, mate $ID"
echo "--- chain:"; sed 's/^/    /' "$CFG/secondmate-quota-chain"
if [ "$SC" = refused ]; then
  printf 'phase=prepared\nharness=claude\n' > "$STATE/$ID.control-relaunch"
  echo "--- pre-existing relaunch journal planted (control plane must refuse pre-stop)"
fi
if [ "$SC" = locked ]; then
  ( . "$WT/bin/fm-wake-lib.sh"; fm_lock_try_acquire "$STATE/.control-$ID.lock" && exec sleep 60 ) &
  HOLD=$!; sleep 1
  echo "--- state/.control-$ID.lock held by pid $(cat "$STATE/.control-$ID.lock/pid" 2>/dev/null) (a concurrent relaunch / updatefirstmate)"
fi
show
echo "### inject fake 429 (turn 1)"; inject "$ID" "check inbox 1"
tmux capture-pane -p -t "fmlab:fm-$ID" | grep -v '^$' | tail -4 | sed 's/^/  pane| /'
tick "$ID"; show
echo "### wait past the window, inject turn 2"; sleep $((FM_QUOTA_FAILOVER_WINDOW_SECS + 1)); inject "$ID" "check inbox 2"
T0=$(date +%s); tick "$ID"; echo "(tick took $(( $(date +%s) - T0 ))s)"; show
echo "--- pane after:"; tmux capture-pane -p -t "fmlab:fm-$ID" -S -40 | grep -v '^$' | tail -12 | sed 's/^/  pane| /'
echo "--- relaunch journal:"; sed 's/^/    /' "$STATE/$ID.control-relaunch" 2>/dev/null || echo "    <none>"
if [ "$SC" = return ]; then
  echo "### quota clears (no new error); reset period shortened to 3s"
  export FM_QUOTA_FAILOVER_RESET_SECS=3
  tick "$ID"; show; sleep 4
  tick "$ID"; show
  echo "--- relaunch journal phase/to_*:"; grep '^to_\|^phase' "$STATE/$ID.control-relaunch" | sed 's/^/    /'
fi
if [ "$SC" = exactid ]; then
  echo "--- alpha inbox msgs: $(ls "$STATE/alpha.inbox" 2>/dev/null | wc -l | tr -d ' '); fm-alpha inbox msgs: $(ls "$STATE/fm-alpha.inbox" 2>/dev/null | wc -l | tr -d ' ')"
  echo "--- alpha pane:"; tmux capture-pane -p -t "fmlab:fm-alpha" | grep -v '^$' | tail -3 | sed 's/^/  alpha-pane| /'
  tmux list-windows -t fmlab -F '    window #{window_name} pid=#{pane_pid} dead=#{pane_dead}'
  echo "--- alpha pin: $(grep '^alpha ' "$CFG/secondmate-harness")"
  echo "--- alpha relaunch journal present: $([ -e "$STATE/alpha.control-relaunch" ] && echo yes || echo no)"
fi
