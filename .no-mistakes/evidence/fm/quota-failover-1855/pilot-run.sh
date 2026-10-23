#!/usr/bin/env bash
# Sandbox fake-429 pilot on the head under test. Drives the REAL
# bin/fm-quota-failover-lib.sh fm_quota_failover_tick (one fresh process per
# tick, as each watcher pass is), which calls the REAL
# bin/fm-secondmate-restart.sh --failover, which uses the REAL fm-send and
# fm-control relaunch against a fake mate on the lab's private tmux server.
set -u
. ~/.no-mistakes/evidence/01M5NA34SBKCZZAPDKCEWC1J2H/pilot-lab-env.sh
cd "$WT"
export FM_QUOTA_FAILOVER_WINDOW_SECS=20 FM_QUOTA_FAILOVER_PERSIST_WAIT=5
T="$SES:fm-$ID"
N=0

say() { printf '\n=== %s [%s]\n' "$*" "$(date -u +%H:%M:%S)"; }
tick() {
  local out rc
  out=$(bash -c '. "$1/bin/fm-quota-failover-lib.sh"; fm_quota_failover_tick "$2" "$3"; rc=$?; printf "%s" "$FM_QF_REPORT"; exit "$rc"' \
    _ "$WT" "$STATE/$ID.meta" "$ID" 2>&1); rc=$?
  printf 'tick %s rc=%s report=%s\n' "$(date -u +%H:%M:%S)" "$rc" "${out:-<none>}"
  LAST_REPORT=$out
}
turn() {  # <text>
  N=$((N + 1))
  lt send-keys -t "$T" -l "$1"; lt send-keys -t "$T" Enter; sleep 0.4
}
pin() { grep "^$ID " "$L/config/secondmate-harness"; }
agent() { lt list-panes -t "$T" -F 'pane_cmd=#{pane_current_command}'; tail -1 "$FAKE_DIR/launches"; }
show() {
  echo "pin: $(pin)"
  echo "state: $(tr '\n' ' ' < "$STATE/.quota-failover-$ID" 2>/dev/null)"
  echo "launches so far: $(grep -c . "$FAKE_DIR/launches")"
  agent
  echo "pane (newest non-blank lines):"
  lt capture-pane -p -t "$T" -S -100 | grep -v '^[[:space:]]*$' | tail -n 6 | sed 's/^/  | /'
}

say "LAB $L  mate=$ID  window=${FM_QUOTA_FAILOVER_WINDOW_SECS}s persist_wait=${FM_QUOTA_FAILOVER_PERSIST_WAIT}s"
echo "chain:"; grep -v '^#' "$L/config/secondmate-quota-chain" | sed 's/^/  /'
show
L0=$(grep -c . "$FAKE_DIR/launches")

say "PHASE A - adversarial: one static relayed 429 line on a HEALTHY mate must never fail it over"
: > "$FAKE_DIR/exhausted"
turn "relay from crew: their build step logged Error: 429 Too Many Requests from an upstream mirror"
start=$(date +%s)
while [ $(( $(date +%s) - start )) -lt 35 ]; do
  tick
  [ $(( $(date +%s) - start )) -lt 15 ] || [ "${scrolled:-0}" = 1 ] || { turn "healthy follow-up turn"; scrolled=1; }
  sleep 4
done
show
A_PIN=$(pin); A_LAUNCHES=$(grep -c . "$FAKE_DIR/launches")
[ "$A_PIN" = "$ID pi kimi-code/kimi-for-coding high" ] && [ "$A_LAUNCHES" = "$L0" ] \
  && echo "RESULT A: PASS - static 429 line held past the ${FM_QUOTA_FAILOVER_WINDOW_SECS}s window: pin unchanged, no restart" \
  || echo "RESULT A: FAIL"
for i in 1 2 3 4 5 6 7; do turn "healthy turn $i"; done
tick; show

say "PHASE B - sustained injected 429 (link 0 pool exhausted) past the window moves the pin to link 1 and restarts persist-first"
echo kimi-code/kimi-for-coding > "$FAKE_DIR/exhausted"
start=$(date +%s); LAST_REPORT=
while [ $(( $(date +%s) - start )) -lt 90 ]; do
  turn "check your steering inbox, doorbell $N"
  tick
  case "$LAST_REPORT" in *"failover from chain link 0 to link 1"*) break ;; esac
  sleep 3
done
sleep 1; show
echo "persist request delivered to the wedged mate (from its own input log):"
grep -c 'Firstmate' "$FAKE_DIR/inputs" | sed 's/^/  firstmate-marked inputs: /'
ls "$STATE/pending-replies" 2>/dev/null | sed 's/^/  pending-reply record: /'
[ "$(pin)" = "$ID claude sonnet high" ] && tail -1 "$FAKE_DIR/launches" | grep -q '\[claude\]' \
  && echo "RESULT B: PASS - pin moved to link 1 and the replacement agent runs claude/sonnet" \
  || echo "RESULT B: FAIL"
B_PID=$(tail -1 "$FAKE_DIR/launches" | sed 's/.*pid=\([0-9]*\).*/\1/')

say "PHASE C - adversarial: a restart the control plane refuses before touching the agent restores the exact prior pin"
echo sonnet >> "$FAKE_DIR/exhausted"
mv "$SM/.fm-secondmate-home" "$SM/.fm-secondmate-home.off"   # real pre-stop refusal cause
start=$(date +%s); LAST_REPORT=
while [ $(( $(date +%s) - start )) -lt 90 ]; do
  turn "check your steering inbox, doorbell $N"
  tick
  case "$LAST_REPORT" in *"did not complete; pin restored"*) break ;; esac
  sleep 3
done
show
C_PID=$(tail -1 "$FAKE_DIR/launches" | sed 's/.*pid=\([0-9]*\).*/\1/')
[ "$(pin)" = "$ID claude sonnet high" ] && [ "$C_PID" = "$B_PID" ] && grep -q '^link=1$' "$STATE/.quota-failover-$ID" \
  && grep -q '^episode=refused$' "$STATE/.quota-failover-$ID" \
  && echo "RESULT C: PASS - refusal restored the exact prior pin, link stays 1, agent pid $C_PID untouched" \
  || echo "RESULT C: FAIL"
echo "control-plane journal after the refusal:"; sed 's/^/  /' "$STATE/$ID.control-relaunch" 2>/dev/null || echo "  (none)"

say "PHASE C2 - the refused episode retries next window and reports only once"
start=$(date +%s); reports=0
while [ $(( $(date +%s) - start )) -lt 30 ]; do
  turn "check your steering inbox, doorbell $N"
  tick; [ -z "$LAST_REPORT" ] || reports=$((reports + 1))
  sleep 3
done
# Each restart-owner attempt opens one persist-request record before its relaunch is refused.
attempts=$(cat "$STATE"/pending-replies/* 2>/dev/null | sed -n 's/^created_epoch=//p' | awk -v s="$start" '$1 >= s' | sort -n | tr '\n' ' ')
echo "reports during the repeat window: $reports; restart-owner attempts (persist-request created_epoch) in it: ${attempts:-none}"; show
[ "$reports" = 0 ] && [ -n "$attempts" ] && [ "$(pin)" = "$ID claude sonnet high" ] && grep -q '^episode=refused$' "$STATE/.quota-failover-$ID" \
  && echo "RESULT C2: PASS - the refused failover retried each window without a second report; pin still the restored link-1 line" \
  || echo "RESULT C2: FAIL"

say "PHASE D - cause fixed: the next window walks the chain on to link 2 (codex pool via pi)"
mv "$SM/.fm-secondmate-home.off" "$SM/.fm-secondmate-home"
start=$(date +%s); LAST_REPORT=
while [ $(( $(date +%s) - start )) -lt 90 ]; do
  turn "check your steering inbox, doorbell $N"
  tick
  case "$LAST_REPORT" in *"failover from chain link 1 to link 2"*) break ;; esac
  sleep 3
done
sleep 1; show
[ "$(pin)" = "$ID pi openai-codex/gpt-6.1-sol low" ] && tail -1 "$FAKE_DIR/launches" | grep -q 'gpt-6.1-sol' \
  && echo "RESULT D: PASS - chain walked kimi -> claude -> codex" || echo "RESULT D: FAIL"

say "PHASE E - return held in its persist phase (no relaunch ran) restores the exact pin and link, then retries after the next clear period"
export FM_QUOTA_FAILOVER_RESET_SECS=15
E_PIN=$(pin); E_PID=$(tail -1 "$FAKE_DIR/launches" | sed 's/.*pid=\([0-9]*\).*/\1/'); E_LAUNCHES=$(grep -c . "$FAKE_DIR/launches")
echo "before: pin=[$E_PIN] pid=$E_PID launches=$E_LAUNCHES; link 2 pool is healthy, reset period shortened to ${FM_QUOTA_FAILOVER_RESET_SECS}s; the fake never answers the persist request"
for i in $(seq 1 14); do turn "healthy turn on link 2 #$i"; done
start=$(date +%s); LAST_REPORT=
while [ $(( $(date +%s) - start )) -lt 75 ]; do
  turn "healthy turn $N"
  tick
  case "$LAST_REPORT" in *"return to chain link 0"*|*"returned to chain link 0"*) break ;; esac
  sleep 3
done
show
E_PID2=$(tail -1 "$FAKE_DIR/launches" | sed 's/.*pid=\([0-9]*\).*/\1/')
case "$LAST_REPORT" in *"did not complete; pin restored to link 2"*held:*) e_rep=1 ;; *) e_rep=0 ;; esac
[ "$e_rep" = 1 ] && [ "$(pin)" = "$E_PIN" ] && grep -q '^link=2$' "$STATE/.quota-failover-$ID" \
  && [ "$E_PID2" = "$E_PID" ] && [ "$(grep -c . "$FAKE_DIR/launches")" = "$E_LAUNCHES" ] \
  && echo "RESULT E: PASS - held return restored the exact link-2 pin and link=2; agent pid $E_PID untouched, no relaunch" \
  || echo "RESULT E: FAIL"

say "PHASE E2 - the held return is retried after the next clear period, still without relaunching"
start=$(date +%s); reports=0
while [ $(( $(date +%s) - start )) -lt 45 ]; do
  turn "healthy turn $N"
  tick; case "$LAST_REPORT" in *"return to chain link 0"*) reports=$((reports + 1)) ;; esac
  sleep 3
done
attempts=$(cat "$STATE"/pending-replies/* 2>/dev/null | sed -n 's/^created_epoch=//p' | awk -v s="$start" '$1 >= s' | sort -n | tr '\n' ' ')
echo "return reports in the retry window: $reports; persist-request records created in it: ${attempts:-none}"; show
[ -n "$attempts" ] && [ "$(pin)" = "$E_PIN" ] && grep -q '^link=2$' "$STATE/.quota-failover-$ID" \
  && [ "$(grep -c . "$FAKE_DIR/launches")" = "$E_LAUNCHES" ] \
  && echo "RESULT E2: PASS - the return was retried after a further clear period; pin and link stay on link 2 while unconfirmed" \
  || echo "RESULT E2: FAIL"

say "launch log (every fake agent incarnation, with its argv)"
sed 's/^/  /' "$FAKE_DIR/launches" | cut -c1-260
