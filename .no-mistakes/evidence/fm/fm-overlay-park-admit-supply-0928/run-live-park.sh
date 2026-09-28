#!/usr/bin/env bash
set -u
ROOT=/home/holu/.no-mistakes/worktrees/74707b8d4eb3/01M3KX5JJV97HQAM41SFEK6TMT
E=/home/holu/.no-mistakes/evidence/01M3KX5JJV97HQAM41SFEK6TMT/live-park-and-admission.log
: > "$E"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX") || exit 1
cleanup() {
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server >/dev/null 2>&1 || true
  rm -rf "$LAB" || true
}
trap cleanup EXIT
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >>"$E" 2>&1 || exit 1
mkdir -p "$LAB/tmux" "$LAB/project"
touch "$LAB/config/supervision-host"
git -C "$LAB/project" init -q -b main
git -C "$LAB/project" config user.name "Live Lab"
git -C "$LAB/project" config user.email "live-lab@example.invalid"
printf '# live lab\n' > "$LAB/project/README.md"
git -C "$LAB/project" add README.md && git -C "$LAB/project" commit -qm initial
ID="live-park-${RANDOM}-${RANDOM}"
mkdir -p "$LAB/data/$ID"
cat > "$LAB/data/$ID/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise automatic parking of a completed lab lane.

## Firstmate spec
Do not modify the lab project.

Delivery contract: mode=no-mistakes
EOF
printf 'LAB=%s ID=%s\n' "$LAB" "$ID" >>"$E"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s primary -c "$ROOT" -e FM_HOME="$LAB" claude
sleep 8
printf '%s\n' '--- primary capture ---' >>"$E"
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab capture-pane -p -t primary >>"$E" 2>&1 || true
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-window -d -t primary -n operator -c "$ROOT" env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" /bin/bash
sleep 1
SPAWN_CMD="cd $(printf %q "$ROOT"); FM_HOME=$(printf %q "$LAB") bin/fm-spawn.sh $(printf %q "$ID") $(printf %q "$LAB/project") --mode no-mistakes --yolo off --harness claude > $(printf %q "$LAB/spawn.out") 2>&1; printf 'SPAWN_RC=%s\\n' \"\$?\" >> $(printf %q "$LAB/spawn.out")"
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab send-keys -t primary:operator -l "$SPAWN_CMD"
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab send-keys -t primary:operator Enter
sleep 20
printf '%s\n' '--- spawn output ---' >>"$E"
cat "$LAB/spawn.out" >>"$E" 2>&1 || true
printf '%s\n' '--- windows after spawn ---' >>"$E"
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab list-windows -t primary -F '#{window_name}:#{pane_current_command}:#{pane_dead}' >>"$E" 2>&1 || true
if grep -Fq "spawned $ID harness=claude" "$LAB/spawn.out" && [ -f "$LAB/state/$ID.meta" ]; then
  printf 'done [at=%s]: live completed lane without gate go\n' "$(date +%s)" > "$LAB/state/$ID.status"
  PARK_CMD="cd $(printf %q "$ROOT"); FM_HOME=$(printf %q "$LAB") bin/fm-park-on-queue.sh $(printf %q "$ID") > $(printf %q "$LAB/park.out") 2>&1; printf 'PARK_RC=%s\\n' \"\$?\" >> $(printf %q "$LAB/park.out")"
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab send-keys -t primary:operator -l "$PARK_CMD"
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab send-keys -t primary:operator Enter
  sleep 15
  printf '%s\n' '--- park output ---' >>"$E"
  cat "$LAB/park.out" >>"$E" 2>&1 || true
  printf '%s\n' '--- task status after park ---' >>"$E"
  cat "$LAB/state/$ID.status" >>"$E" 2>&1 || true
  printf '%s\n' '--- windows after park ---' >>"$E"
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab list-windows -t primary -F '#{window_name}:#{pane_current_command}:#{pane_dead}' >>"$E" 2>&1 || true
else
  printf '%s\n' 'SKIP_PARK: real worker did not spawn' >>"$E"
fi
printf '999999\n' > "$LAB/config/admission-min-ram-gb"
RAM_ID="live-ram-${RANDOM}-${RANDOM}"
RAM_CMD="cd $(printf %q "$ROOT"); FM_HOME=$(printf %q "$LAB") bin/fm-spawn.sh $(printf %q "$RAM_ID") $(printf %q "$LAB/project") --mode no-mistakes --yolo off --harness claude > $(printf %q "$LAB/ram.out") 2>&1; printf 'RAM_RC=%s\\n' \"\$?\" >> $(printf %q "$LAB/ram.out")"
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab send-keys -t primary:operator -l "$RAM_CMD"
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab send-keys -t primary:operator Enter
sleep 4
printf '%s\n' '--- RAM refusal ---' >>"$E"
cat "$LAB/ram.out" >>"$E" 2>&1 || true
printf '%s\n' '--- primary final capture ---' >>"$E"
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab capture-pane -p -t primary >>"$E" 2>&1 || true
cat "$E"
