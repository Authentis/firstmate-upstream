#!/usr/bin/env bash
# Throwaway-home replay of the intent's netcup chain through the real
# bin/fm-quota-failover-lib.sh, default knobs (300s window, 18000s reset).
# Fake tmux prints a fixture pane; the restart owner is a recording stub.
# No agent, no real home, no ssh.
set -u
WT=$1
T=$(mktemp -d /tmp/fm-qf-test-runner/home.XXXXXX)
trap 'rm -rf "$T"' EXIT
ID=netcup
BIN=$T/bin
mkdir -p "$BIN" "$T/fakebin" "$T/home/state" "$T/home/config"
for f in "$WT"/bin/*; do ln -s "$f" "$BIN/$(basename "$f")"; done
rm -f "$BIN/fm-secondmate-restart.sh"
cat > "$BIN/fm-secondmate-restart.sh" <<'SH'
#!/usr/bin/env bash
[ -n "${FM_HOME:-}" ] || { echo "error: FM_HOME is not set" >&2; exit 1; }
id=${!#}
printf 'RESTART-OWNER CALLED: %s   (pin at call: %s)\n' "$*" "$(grep "^$id " "$FM_CONFIG_OVERRIDE/secondmate-harness")" >> "$FM_HOME/calls"
case "${QF_MODE:-ok}" in
  refused)
    printf "held: %s: the restart was refused before its agent was touched: another lifecycle action is already running for task %s\n" "$id" "$id"
    printf 'summary: 0 of 1 restarted, 0 nudged, 0 unreached, 1 held\n'; exit 3 ;;
  *) printf 'restarted: %s (stub)\nsummary: 1 of 1 restarted, 0 nudged, 0 unreached, 0 held\n' "$id" ;;
esac
SH
chmod +x "$BIN/fm-secondmate-restart.sh"
cat > "$T/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in capture-pane) cat "$QF_PANE" ;; esac
SH
chmod +x "$T/fakebin/tmux"
H=$T/home
cat > "$H/state/$ID.meta" <<EOF
window=fmlab:fm-$ID
endpoint_task_id=$ID
worktree=$H
project=$H
harness=pi
kind=secondmate
mode=secondmate
yolo=off
home=$H
projects=alpha
EOF
printf '%s pi kimi-code/kimi-for-coding high\nother claude default high\n' "$ID" > "$H/config/secondmate-harness"
cat > "$H/config/secondmate-quota-chain" <<EOF
# netcup secondmate chain (link 0 first)
$ID pi kimi-code/kimi-for-coding high
$ID claude claude-opus-5-5 high
$ID pi openai-codex/gpt-6.1-sol low
EOF
: > "$H/calls"; : > "$H/pane"
n=0
turn() { n=$((n+1)); printf '> check inbox (%s)\n%s\n' "$n" "$1" >> "$H/pane"; }
tick() {
  local before rc out
  before=$(grep -c . "$H/calls")
  out=$(env -u FM_HOME -u FM_QUOTA_FAILOVER_WINDOW_SECS -u FM_QUOTA_FAILOVER_RESET_SECS \
    PATH="$T/fakebin:$PATH" STATE="$H/state" FM_CONFIG_OVERRIDE="$H/config" QF_PANE="$H/pane" \
    bash -c 'FM_HOME=$5; . "$1/fm-quota-failover-lib.sh"; fm_quota_failover_tick "$2" "$3" "$4"; rc=$?; printf "%s" "$FM_QF_REPORT"; exit $rc' \
    _ "$BIN" "$H/state/$ID.meta" "$ID" "$1" "$H")
  rc=$?
  printf '[t=%6ss] rc=%s  pin="%s"  state: %s\n' "$1" "$rc" "$(grep "^$ID " "$H/config/secondmate-harness")" \
    "$(tr '\n' ' ' < "$H/state/.quota-failover-$ID" 2>/dev/null)"
  [ -z "$out" ] || printf '           report: %s\n' "$out"
  tail -n +"$((before+1))" "$H/calls" | sed 's/^/           /'
}
echo "== chain file =="; cat "$H/config/secondmate-quota-chain"
echo; echo "== S1: kimi 5-hour limit: every turn answers with a 429 (varying input), default 300s window =="
for t in 0 60 120 180 240 299; do turn 'API Error: 429 {"type":"error","error":{"type":"rate_limit_error","message":"usage limit reached"}}'; tick $t; done
turn 'API Error: 429 {"type":"error","error":{"type":"rate_limit_error","message":"usage limit reached"}}'; tick 300
echo; echo "== S2: Claude link also exhausted -> next link =="
printf 'Claude replacement booting\n' > "$H/pane"; tick 310
for t in 400 500 600 700; do turn 'Claude usage limit reached. Your limit will reset at 7pm'; tick $t; done
echo; echo "== S3: last link healthy; quota stays clear for the 18000s reset period -> back to link 0 =="
printf 'all quiet, working\n' > "$H/pane"
for t in 800 10000 18799 18800; do tick $t; done
echo; echo "== S4 (adversarial): one static relayed crew error line, unchanged for 20 minutes =="
printf 'relay from crew-7: API Error: 429 Too Many Requests\nworking on task\n' > "$H/pane"
for t in 19000 19300 19600 19900 20200; do tick $t; done
echo; echo "== S5 (adversarial): restart refused before agent touched -> exact prior pin restored =="
: > "$H/pane"
for t in 21000 21100 21200 21301; do turn "Error: exceeded_current_quota (call $t)"; QF_MODE=refused tick $t; done
echo; echo "== S6 (adversarial, newest commit): target pin cannot be written (config dir read-only) -> no restart, state stays on link 0 =="
printf 'all quiet\n' > "$H/pane"; tick 21400
: > "$H/pane"
chmod 555 "$H/config"
for t in 21500 21600 21800; do turn "Error: exceeded_current_quota (call $t)"; tick $t; done
chmod 755 "$H/config"
echo "   (config dir writable again)"
for t in 21900 22100; do turn "Error: exceeded_current_quota (call $t)"; tick $t; done
echo; echo "== final config/secondmate-harness =="; cat "$H/config/secondmate-harness"
