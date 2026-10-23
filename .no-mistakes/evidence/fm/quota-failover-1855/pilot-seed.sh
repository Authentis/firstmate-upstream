#!/usr/bin/env bash
# Seed the sandbox lab: a fake secondmate home, its registration meta, the
# netcup-shaped quota chain, and the first incarnation (fake pi on link 0)
# running on the lab's private tmux server.
set -eu
. ~/.no-mistakes/evidence/01M5NA34SBKCZZAPDKCEWC1J2H/pilot-lab-env.sh
mkdir -p "$L/src" "$L/fakebin" "$L/fake" "$L/tmux" "$HOME" "$L/projects/proj" "$L/data/$ID"
cc -O1 -o "$L/src/fakeagent" ~/.no-mistakes/evidence/01M5NA34SBKCZZAPDKCEWC1J2H/fakeagent.c
for h in pi claude codex kimi opencode grok; do cp "$L/src/fakeagent" "$L/fakebin/$h"; done
git -C "$L/projects/proj" init -q -b main
git -C "$L/projects/proj" -c user.name=lab -c user.email=lab@invalid commit -q --allow-empty -m init
git -C "$L/projects/proj" worktree add -q -b sm-branch "$SM"
mkdir -p "$SM/state" "$SM/data" "$SM/bin"
printf '%s\n' "$ID" > "$SM/.fm-secondmate-home"
printf '# agents (lab)\n' > "$SM/AGENTS.md"
printf '# secondmate brief (lab fixture)\n' > "$L/data/$ID/brief.md"
cat > "$L/state/$ID.meta" <<EOF
window=$SES:fm-$ID
endpoint_task_id=$ID
worktree=$SM
project=$SM
harness=pi
kind=secondmate
mode=secondmate
yolo=off
model=kimi-code/kimi-for-coding
effort=high
home=$SM
backend=tmux
EOF
printf '%s pi kimi-code/kimi-for-coding high\n' "$ID" > "$L/config/secondmate-harness"
cat > "$L/config/secondmate-quota-chain" <<EOF
# netcup-shaped chain for an invented lab mate
$ID pi kimi-code/kimi-for-coding high
$ID claude sonnet high
$ID pi openai-codex/gpt-6.1-sol low
EOF
: > "$FAKE_DIR/exhausted"
lt new-session -d -s "$SES" -n "fm-$ID" -x 160 -y 50 -c "$SM" \
  -e PATH="$PATH" -e FAKE_DIR="$FAKE_DIR" -e HOME="$HOME" -e TMUX_TMPDIR="$TMUX_TMPDIR" /bin/bash --noprofile --norc
lt set-option -g history-limit 5000
sleep 0.5
lt send-keys -t "$SES:fm-$ID" -l "pi --model kimi-code/kimi-for-coding --thinking high"
lt send-keys -t "$SES:fm-$ID" Enter
sleep 0.5
lt list-windows -a -F '#{session_name}:#{window_name} cmd=#{pane_current_command} pid=#{pane_pid}'
lt capture-pane -p -t "$SES:fm-$ID" | grep -v '^$'
