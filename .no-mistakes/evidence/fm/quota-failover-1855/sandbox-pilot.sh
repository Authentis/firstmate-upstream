#!/usr/bin/env bash
# Bounded sandbox pilot for the quota failover (supervisor ruling, inbox 021).
#
# One throwaway lab under the system temp dir: a bin/fm-lab-home.sh marked
# FM_HOME with FM_STATE_OVERRIDE/FM_CONFIG_OVERRIDE inside it, a private tmux
# server (TMUX_TMPDIR from fm-lab-home.sh tmux-dir, no user tmux config), one
# invented local secondmate id with no remote_host, and a compiled stub agent
# installed under every agent binary name on a lab-only PATH. No real agent,
# no real home, no fm-on, no ssh, no remote host.
#
# Drives the REAL bin/fm-quota-failover-lib.sh (fm_quota_failover_tick on the
# real clock with a shortened window) and, through it, the REAL
# bin/fm-secondmate-restart.sh --failover -> bin/fm-control.sh relaunch ->
# bin/fm-spawn.sh --relaunch against that lab only.
#
# Usage: sandbox-pilot.sh <worktree>
set -u
WT=$(cd "$1" && pwd -P)
STUB_SRC="$(cd "$(dirname "$0")" && pwd -P)/sandbox-pilot-stub-agent.c"
ID=qfpilot7
WINDOW_SECS=20
TICK=4

# Nothing inherited from a real home or multiplexer reaches the lab.
for v in $(env | sed -n 's/^\(FM_[A-Za-z0-9_]*\)=.*/\1/p; s/^\(HERDR_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$v"; done
unset TMUX TMUX_PANE

LAB=$(mktemp -d /tmp/fmqf-pilot.XXXXXX) || exit 1
LAB=$(cd "$LAB" && pwd -P)
H=$LAB/home
SOCK=''
cleanup() {
  echo
  echo "== cleanup =="
  if [ -n "$SOCK" ]; then
    TMUX_TMPDIR=$SOCK tmux kill-server 2>/dev/null && echo "killed the lab's private tmux server ($SOCK)"
    "$WT/bin/fm-lab-home.sh" teardown "$H" && echo "removed the lab tmux socket dir"
  fi
  # The spawn leaves its per-task git hooks read-only.
  chmod -R u+w "$LAB" 2>/dev/null
  rm -rf "$LAB" && echo "removed lab $LAB"
  for d in "/tmp/fm-$ID" "/tmp/fm-$ID+"*; do
    [ -e "$d" ] || continue
    chmod -R u+w "$d" 2>/dev/null
    rm -rf "$d" && echo "removed the lab task temp dir $d"
  done
}
trap cleanup EXIT

"$WT/bin/fm-lab-home.sh" create "$H" >/dev/null || exit 1
SOCK=$("$WT/bin/fm-lab-home.sh" tmux-dir "$H") || exit 1
FAKEBIN=$LAB/fakebin
mkdir -p "$FAKEBIN" "$LAB/user-home" "$LAB/build"
MODE=$LAB/mode
printf 'ok\n' > "$MODE"
cc -O0 -DMODE_FILE="\"$MODE\"" -o "$LAB/build/stub" "$STUB_SRC" || exit 1
for n in claude pi codex kimi opencode grok gemini muse omp agy devin cursor-agent rovo; do
  cp "$LAB/build/stub" "$FAKEBIN/$n"
done
LABPATH="$FAKEBIN:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# Every lab command runs from this environment and nothing else.
labenv() {
  env -i HOME="$LAB/user-home" PATH="$LABPATH" TERM=xterm-256color LANG=en_US.UTF-8 \
    USER="$(id -un)" LOGNAME="$(id -un)" SHELL=/bin/bash TMPDIR="${TMPDIR:-/tmp}" \
    TMUX_TMPDIR="$SOCK" NO_MISTAKES_GATE=1 CLAUDE_CONFIG_DIR='' \
    TREEHOUSE_ROOT="$LAB/treehouse" DISABLE_AUTOUPDATER=1 \
    FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" FM_CONFIG_OVERRIDE="$H/config" \
    FM_SECONDMATE_PERSIST_POLL=1 FM_QUOTA_FAILOVER_PERSIST_WAIT=5 \
    FM_QUOTA_FAILOVER_WINDOW_SECS="$WINDOW_SECS" "$@"
}
labtmux() { labenv tmux "$@"; }

# The invented mate's own seeded home: a git checkout with the secondmate marker.
SM=$LAB/smhome
git init -q "$SM"
git -C "$SM" -c user.name=lab -c user.email=lab@invalid commit -q --allow-empty -m seed
mkdir -p "$SM/state" "$SM/data" "$SM/bin"
printf '%s\n' "$ID" > "$SM/.fm-secondmate-home"
printf '# lab secondmate charter\n' > "$SM/AGENTS.md"
printf '.fm-secondmate-home\nstate/\ndata/\nbin/\nAGENTS.md\n' > "$SM/.git/info/exclude"
mkdir -p "$H/data/$ID"
printf "# lab secondmate brief\n" > "$H/data/$ID/brief.md"

# Netcup-shaped chain on the invented id; the pin starts on link 0.
cat > "$H/config/secondmate-quota-chain" <<EOF
# lab chain (link 0 first)
$ID pi kimi-code/kimi-for-coding high
$ID claude claude-opus-5-5 high
$ID pi openai-codex/gpt-6.1-sol low
EOF
printf '%s pi kimi-code/kimi-for-coding high\n' "$ID" > "$H/config/secondmate-harness"
printf 'tmux\n' > "$H/config/backend"

# Private tmux server, no user config; the pane shell runs the link-0 stub.
labtmux -f /dev/null new-session -d -x 2000 -y 50 -s fmlab -n "fm-$ID" -c "$SM" "bash --noprofile --norc" || exit 1
labtmux set-option -g default-command "bash --noprofile --norc" >/dev/null
labtmux set-option -g history-limit 5000 >/dev/null
labtmux send-keys -t "fmlab:fm-$ID" "cd '$SM' && pi --model kimi-code/kimi-for-coding --thinking high" Enter
cat > "$H/state/$ID.meta" <<EOF
window=fmlab:fm-$ID
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
EOF
sleep 1

pin() { grep "^$ID " "$H/config/secondmate-harness"; }
qfstate() { tr '\n' ' ' < "$H/state/.quota-failover-$ID" 2>/dev/null; }
pane_tail() { labtmux capture-pane -p -t "fmlab:fm-$ID" -S -200 | grep -v '^[[:space:]]*$' | tail -n "${1:-6}" | sed 's/^/      | /'; }
agent_cmd() { labtmux display-message -p -t "fmlab:fm-$ID" '#{pane_current_command}'; }
turn_n=0
turn() { turn_n=$((turn_n + 1)); labtmux send-keys -t "fmlab:fm-$ID" -l "doorbell: check inbox ($turn_n)"; labtmux send-keys -t "fmlab:fm-$ID" Enter; }

# One real watcher-style pass of the real library over the lab.
tick() {
  local out rc start=$SECONDS
  out=$(labenv bash -c '
    STATE=$FM_STATE_OVERRIDE
    . "$1/bin/fm-quota-failover-lib.sh"
    fm_quota_failover_tick "$FM_STATE_OVERRIDE/$2.meta" "$2"; rc=$?
    printf "%s" "$FM_QF_REPORT"; exit $rc' _ "$WT" "$ID" 2>&1)
  rc=$?
  printf '[%s] tick rc=%s (%ss) pin="%s" agent=%s\n      state: %s\n' "$(date -u +%H:%M:%S)" "$rc" \
    "$((SECONDS - start))" "$(pin)" "$(agent_cmd)" "$(qfstate)"
  [ -z "$out" ] || printf '%s\n' "$out" | sed 's/^/      report: /'
}

echo "== lab =="
echo "lab root: $LAB (FM_HOME=$H, FM_STATE_OVERRIDE=$H/state, FM_CONFIG_OVERRIDE=$H/config)"
echo "tmux: private server via TMUX_TMPDIR=$SOCK, session fmlab, no user config"
echo "mate: $ID (local, no remote_host), home $SM"
echo "lab PATH: $LABPATH  (every agent name in $FAKEBIN is the compiled stub)"
for n in pi claude codex kimi; do printf '  %s -> %s\n' "$n" "$(labenv bash -c "command -v $n")"; done
echo "head under test: $(git -C "$WT" rev-parse HEAD)"
echo "window=${WINDOW_SECS}s persist wait=5s"
echo "--- config/secondmate-quota-chain"; cat "$H/config/secondmate-quota-chain"
echo "--- config/secondmate-harness"; cat "$H/config/secondmate-harness"
echo "--- link-0 agent in the lab pane: $(agent_cmd)"; pane_tail 3

if [ "${QF_DEBUG:-}" = 1 ]; then
  printf '%s claude claude-opus-5-5 high\n' "$ID" > "$H/config/secondmate-harness"
  sleep 2; echo "--- debug: composer read"
  labenv bash -c '. "$1/bin/fm-backend.sh"; fm_backend_source tmux; t="fmlab:fm-$2"
    cy=$(fm_tmux_composer_cursor_row "$t"); echo "cy=$cy"; pane=$(fm_tmux_composer_capture "$t")
    printf "%s\n" "$pane" | grep -n . | tail -6 | LC_ALL=C cut -c1-120 | LC_ALL=C cat -v
    echo "caps=$(fm_tmux_composer_caps | tr "\n" " ")"
    echo "verdict=$(fm_tmux_composer_state "$t")"' _ "$WT" "$ID"
  echo "--- debug: direct fm-control relaunch in the lab"
  labenv "$WT/bin/fm-control.sh" "$ID" relaunch; echo "rc=$?"
  sleep 2; pane_tail 12; echo "agent=$(agent_cmd)"
  exit 0
fi
echo
echo "== A1 (adversarial): one static relayed 429 line, unchanged past the window -> no failover =="
turn; sleep 1
labtmux send-keys -t "fmlab:fm-$ID" -l "relay from crew-3: API Error: 429 Too Many Requests"; labtmux send-keys -t "fmlab:fm-$ID" Enter
sleep 1; pane_tail 4
end=$((SECONDS + WINDOW_SECS + 2 * TICK))
while [ "$SECONDS" -lt "$end" ]; do tick; sleep "$TICK"; done
tick
pane_tail 3
[ "$(pin)" = "$ID pi kimi-code/kimi-for-coding high" ] && echo "A1 RESULT: PASS - pin unchanged on link 0, no restart" || echo "A1 RESULT: FAIL - pin moved: $(pin)"

echo
echo "== A2 (pilot): the link-0 pool is exhausted; every turn answers 429, sustained past the window =="
printf '429\n' > "$MODE"
labtmux send-keys -t "fmlab:fm-$ID" -l "clear"; labtmux send-keys -t "fmlab:fm-$ID" Enter
advanced=0
a2out=''
end=$((SECONDS + WINDOW_SECS + 8 * TICK))
while [ "$SECONDS" -lt "$end" ]; do
  turn; sleep 1
  a2out=$(tick); printf '%s\n' "$a2out"
  if [ "$(pin)" != "$ID pi kimi-code/kimi-for-coding high" ]; then advanced=1; break; fi
  sleep "$TICK"
done
sleep 2
echo "--- pane after the failover:"; pane_tail 9
echo "--- relaunch journal (state/$ID.control-relaunch):"; sed 's/^/      /' "$H/state/$ID.control-relaunch" 2>/dev/null
echo "--- persist request recorded for the mate (state/pending-replies):"
find "$H/state/pending-replies" -type f 2>/dev/null | sed "s|$H/||; s/^/      /"
grep -rh -m1 -o 'persist the open work[^.]*' "$H/state/pending-replies" 2>/dev/null | head -1 | sed 's/^/      text: /'
echo "--- meta harness/model/effort now: $(grep -E '^(harness|model|effort)=' "$H/state/$ID.meta" | tr '\n' ' ')"
phase=$(sed -n 's/^phase=//p' "$H/state/$ID.control-relaunch" 2>/dev/null | tail -1)
case "$a2out" in *"quota failover from chain link 0 to link 1"*restarted*) restarted=1 ;; *) restarted=0 ;; esac
if [ "$advanced" = 1 ] && [ "$(pin)" = "$ID claude claude-opus-5-5 high" ] && [ "$restarted" = 1 ] \
   && [ "$phase" = complete ] && [ "$(agent_cmd)" = claude ]; then
  echo "A2 RESULT: PASS - pin moved to link 1 ($(pin)), the real restart owner restarted the mate (journal phase=$phase), agent now $(agent_cmd)"
else
  echo "A2 RESULT: FAIL - advanced=$advanced restarted=$restarted phase=$phase pin='$(pin)' agent=$(agent_cmd)"
fi

echo
echo "== A3 (adversarial): link 1 exhausts too, but the restart is refused before the agent is touched -> exact prior pin restored =="
prior_line=$(pin)
# A child record the checkpoint cannot read makes bin/fm-control.sh refuse the
# relaunch in safe_checkpoint, before it journals or stops anything.
mkdir -p "$SM/state/blocker.meta"
labtmux send-keys -t "fmlab:fm-$ID" -l "clear"; labtmux send-keys -t "fmlab:fm-$ID" Enter
sleep 1
refused=0
end=$((SECONDS + WINDOW_SECS + 8 * TICK))
while [ "$SECONDS" -lt "$end" ]; do
  turn; sleep 1
  out=$(tick); printf '%s\n' "$out"
  case "$out" in *refused*|*held*) refused=1; break ;; esac
  sleep "$TICK"
done
echo "--- pane after the refusal:"; pane_tail 4
if [ "$refused" = 1 ] && [ "$(pin)" = "$prior_line" ]; then
  echo "A3 RESULT: PASS - refusal reported, pin restored byte-exact to '$prior_line', agent still $(agent_cmd)"
else
  echo "A3 RESULT: FAIL - refused=$refused pin='$(pin)' prior='$prior_line'"
fi
echo "--- the control plane's own refusal text for that relaunch (direct re-run in the lab; refused before stop again):"
labenv "$WT/bin/fm-control.sh" "$ID" relaunch 2>&1 | grep -v '^fm-gate-refuse:' | sed 's/^/      /'
echo "--- pin after that re-run: $(pin); agent $(agent_cmd)"
echo "--- final config/secondmate-harness"; cat "$H/config/secondmate-harness"
echo "--- final quota state: $(qfstate)"
