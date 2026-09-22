#!/usr/bin/env bash
# Live driver: runs a real fm-spawn.sh against a real, isolated tmux server
# (private socket, never the operator's tmux) with a stand-in `kimi` program
# that paints Kimi's real ready banner + bordered composer in the pane.
#   MODE=swallow  stand-in accepts the pointer but never confirms it (silent drop)
#   MODE=deliver  stand-in echoes ✨ + brief pointer + context 1% (happy path)
#   MODE=prelaunch same as deliver, but the launch dir is pre-created 0777 so
#                  spawn refuses before the agent is launched (rollback path)
# usage: live-kimi-driver.sh <spawn-script> <case-name> <task-id> <mode> <outdir>
set -u
SPAWN=$1; CASE=$2; ID=$3; MODE=$4; OUT=$5
ROOTDIR=/Users/lundi/.no-mistakes/worktrees/7e4b90506ed5/01M34FXRNP84KE4AJWJ01A24KG
. "$ROOTDIR/tests/lib.sh"
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS TMUX
mkdir -p "$OUT"
TMP=$(mktemp -d "/tmp/fm-live-kimi-$CASE.XXXXXX")
home="$TMP/home"; proj="$TMP/project"; wt="$TMP/wt"; fakebin="$TMP/fakebin"; SOCK="$TMP/tmux.sock"
PYDIR=$(dirname "$(command -v python3)")
BASE_PATH="$PYDIR:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
mkdir -p "$home/data/$ID" "$home/projects" "$home/state" "$home/config" "$home/.kimi-code" "$fakebin"
printf '# Kimi test config\ndefault_model = "test"\n' > "$home/.kimi-code/config.toml"
cat > "$home/data/$ID/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise Kimi dispatch live.

## Firstmate spec
Verify launch and delivery behavior.
EOF
printf 'kimi\n' > "$home/config/crew-harness"
fm_git_worktree "$proj" "$wt" "wt-$CASE"
touch "$home/state/.last-watcher-beat"
fm_fake_exit0 "$fakebin" gh-axi gh
ln -s "$(command -v jq)" "$fakebin/jq"
# treehouse get: a real subshell inside the isolated worktree, like the real tool.
cat > "$fakebin/treehouse" <<EOF
#!/usr/bin/env bash
[ "\${1:-}" = get ] || exit 0
cd '$wt' && exec /bin/bash --norc --noprofile
EOF
chmod +x "$fakebin/treehouse"
# stand-in kimi: real TUI-ish repaint of Kimi's ready banner + bordered composer.
cat > "$fakebin/kimi" <<'EOF'
#!/usr/bin/env bash
mode=${KIMI_STANDIN_MODE:-swallow}
brief=
paint() {
  printf '\033[2J\033[H'
  printf 'Welcome to Kimi Code!\n'
  if [ -n "$brief" ] && [ "$mode" = deliver ]; then
    printf '✨ %s\ncontext: 1%% (2k/256k)\n' "$brief"
  else
    printf 'context: 0%% (0/256k)\n'
  fi
  printf '╭────────────────────────────────╮\n│ >                              │\n╰────────────────────────────────╯\n'
  # park the cursor inside the composer row, as Kimi's TUI does
  printf '\033[2A\033[4C'
}
paint
while IFS= read -r line; do
  brief=$line
  paint
done
sleep 3600
EOF
chmod +x "$fakebin/kimi"
LAUNCH_TOKEN=$(printf '%s' "$(cd "$home" && pwd -P)" | shasum -a 256 | awk '{print $1}')
LAUNCH_DIR="/tmp/fm-$ID+$LAUNCH_TOKEN"
rm -rf "$LAUNCH_DIR" "/tmp/fm-$ID"
STANDIN_MODE=$MODE
if [ "$MODE" = prelaunch ]; then
  STANDIN_MODE=deliver
  mkdir -p "$LAUNCH_DIR" && chmod 777 "$LAUNCH_DIR"
fi
# Real isolated tmux server: private socket, default config, sized window.
tmux -S "$SOCK" -f /dev/null new-session -d -s firstmate -x 120 -y 40 -c "$home"
tmux -S "$SOCK" set-option -g default-command "env PATH='$fakebin:$BASE_PATH' KIMI_STANDIN_MODE=$STANDIN_MODE HOME='$home' /bin/bash --norc --noprofile"
SPID=$(tmux -S "$SOCK" display-message -p '#{pid}')
echo "tmux server pid=$SPID socket=$SOCK" | tee "$OUT/run.log"
rc=0
HOME="$home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
  FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
  FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
  FM_SPAWN_NO_GUARD=1 TMUX="$SOCK,$SPID,0" \
  FM_KIMI_READY_POLLS=20 FM_KIMI_DELIVERY_POLLS=6 FM_KIMI_POLL_INTERVAL=0.5 FM_KIMI_SUBMIT_RETRIES=2 \
  PATH="$fakebin:$BASE_PATH" \
  "$SPAWN" "$ID" "$proj" --harness kimi --mode no-mistakes --yolo off >"$OUT/spawn.out" 2>&1 || rc=$?
echo "spawn exit code: $rc" | tee -a "$OUT/run.log"
{
  echo "== spawn output =="; cat "$OUT/spawn.out"
  echo; echo "== state/ after spawn =="; ls -la "$home/state"
  echo; echo "== state/$ID.meta =="; cat "$home/state/$ID.meta" 2>&1
  echo; echo "== state/$ID.status =="; cat "$home/state/$ID.status" 2>&1
  echo; echo "== home-summary endpoint for $ID =="; jq -c --arg id "$ID" '[.endpoints[]? | select(.id == $id)]' "$home/state/home-summary.json" 2>&1
  echo; echo "== tmux windows (isolated server) =="; tmux -S "$SOCK" list-windows -a -F '#{session_name}:#{window_name} pane_pid=#{pane_pid} cwd=#{pane_current_path}'
  echo; echo "== pane processes in fm-$ID =="; tmux -S "$SOCK" list-panes -t "firstmate:fm-$ID" -F '#{pane_pid} #{pane_current_command}' 2>&1
  echo; echo "== live pane capture fm-$ID =="; tmux -S "$SOCK" capture-pane -p -t "firstmate:fm-$ID" -S -40 2>&1
  echo; echo "== launch dir $LAUNCH_DIR =="; ls -la "$LAUNCH_DIR" 2>&1
} > "$OUT/evidence.txt" 2>&1
tmux -S "$SOCK" capture-pane -p -t "firstmate:fm-$ID" -S -40 > "$OUT/pane-fm-$ID.txt" 2>&1 || true
# teardown: only our private server and our own temp dirs
tmux -S "$SOCK" kill-server 2>/dev/null || true
rm -rf "$TMP" "$LAUNCH_DIR" "/tmp/fm-$ID"
echo "teardown done" | tee -a "$OUT/run.log"
exit "$rc"
