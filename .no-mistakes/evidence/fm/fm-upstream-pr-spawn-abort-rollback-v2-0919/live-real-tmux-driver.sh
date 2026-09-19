#!/usr/bin/env bash
# Live driver: runs the REAL bin/fm-spawn.sh against a REAL tmux server on an
# isolated socket. Only treehouse/codex/no-mistakes/sleep are stand-ins; the pane
# is a real interactive bash whose `treehouse` is a shell function performing
# the scenario's action (stay in project, cd into the worktree, rename the
# window, plant a partial record, or run a process named claude).
set -u
ROOT=$1
. "$ROOT/tests/fixtures.sh"
W=$(mktemp -d /tmp/fmlive.XXXX); W=$(cd "$W" && pwd -P)
SOCK="$W/tmux.sock"
FB=$(fm_fakebin "$W/fake"); fm_test_fake_sleep_noop "$FB"; fm_test_fake_no_mistakes "$FB"
fm_fake_exit0 "$FB" treehouse
printf "#!/bin/sh\nexec /bin/sleep 0.05\n" > "$FB/sleep"  # compress the 60s isolation wait but still let the pane run
PB="$W/panebin"; mkdir -p "$PB"
# the agent case runs /bin/sleep with argv0 "claude" in the pane foreground
printf '#!/bin/sh\necho fake-codex-running; exec sleep 3600\n' > "$PB/codex"; chmod +x "$PB/codex"
cp "$PB/codex" "$FB/codex"
ACTION="$W/action"
cat > "$W/rc" <<RC
PS1='\$ '
export PATH="$PB:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
treehouse() { . "$ACTION"; }
RC
tmux -S "$SOCK" -f /dev/null new-session -d -s firstmate -x 200 -y 50 "bash --noprofile --rcfile $W/rc -i"
tmux -S "$SOCK" set-option -g default-command "bash --noprofile --rcfile $W/rc -i"
PID=$(tmux -S "$SOCK" display-message -p '#{pid}')
export TMUX="$SOCK,$PID,0"
unset TMUX_PANE
echo "# real tmux $(tmux -V) server on isolated socket (pid $PID)"

spawn() { # home proj id
  env FM_ROOT_OVERRIDE='' FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" FM_DATA_OVERRIDE="$1/data" \
    FM_PROJECTS_OVERRIDE="$1/projects" FM_CONFIG_OVERRIDE="$1/config" FM_SPAWN_NO_GUARD=1 \
    PATH="$FB:$PATH" "$ROOT/bin/fm-spawn.sh" "$3" "$2" --mode no-mistakes --yolo off 2>&1
}
windows() { tmux list-windows -t firstmate -F '#{window_id}=#{window_name}' | tr '\n' ' '; }

run_case() { # name id action-line
  local name=$1 id=$2 act=$3; local home="$W/$name/home" proj="$W/$name/project" wt="$W/$name/wt" out st
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$proj" "$wt" "wt-$name" >/dev/null 2>&1
  fm_test_spawn_brief "$home" "$id" "live rollback $id"
  printf '%s\n' "$act" | sed "s|@META@|$home/state/$id.meta|g" > "$ACTION"
  echo
  echo "=== CASE $name (task $id) ==="
  echo "--- pane runs on 'treehouse get': $(sed "s|$W|\$W|g" "$ACTION")"
  echo "--- tmux windows BEFORE: $(windows)"
  out=$(spawn "$home" "$proj" "$id"); st=$?
  echo "--- fm-spawn exit=$st; relevant output:"
  printf '%s\n' "$out" | grep -E 'error:|warning: leaving|spawned|already exists' | sed "s|$W|\$W|g"
  echo "--- tmux windows AFTER:  $(windows)"
  echo "--- task record: $( [ -e "$home/state/$id.meta" ] && echo present || echo absent)"
  CASE_HOME=$home CASE_PROJ=$proj CASE_WT=$wt
}

run_case retry fm-live-retry-a1 'sleep 0.2'
echo "### retry the same task id; the pane now enters the worktree"
printf 'cd %q\n' "$CASE_WT" > "$ACTION"
out=$(spawn "$CASE_HOME" "$CASE_PROJ" fm-live-retry-a1); st=$?
echo "--- retry exit=$st"; printf '%s\n' "$out" | grep -E 'error:|spawned|already exists' | sed "s|$W|\$W|g"
echo "--- tmux windows AFTER retry: $(tmux list-windows -t firstmate -F '#{window_id}=#{window_name} cwd=#{pane_current_path}' | sed "s|$W|\$W|g" | tr '\n' ' ')"
echo "--- retry task record:"; grep -E '^(window|worktree)=' "$CASE_HOME/state/fm-live-retry-a1.meta" | sed "s|$W|\$W|g"
tmux kill-window -t firstmate:fm-fm-live-retry-a1 2>/dev/null

run_case replaced fm-live-replaced-b2 'tmux rename-window -t firstmate:fm-fm-live-replaced-b2 fm-someone-else'
run_case partial fm-live-partial-c3 'printf "window=x\n" > @META@'
run_case agent fm-live-agent-d4 '(exec -a claude /bin/sleep 3600)'
echo
echo "--- final pane_current_command per window:"
tmux list-windows -t firstmate -F '#{window_id}=#{window_name} cmd=#{pane_current_command}'
tmux -S "$SOCK" kill-server
echo "# temp world left at $W (under /tmp)"
