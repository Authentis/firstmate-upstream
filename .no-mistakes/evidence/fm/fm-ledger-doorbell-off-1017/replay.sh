#!/usr/bin/env bash
# Doorbell-off replay: two disposable secondmate lab homes, each with a real
# `fm-order-ledger.sh poll --interval 15` loop. The secondmate-side consumer
# sees only its home's wake queue and the ledger: no tmux, no pane send, no doorbell.
set -u
WT=$1
cd "$WT" || exit 1

run_sm() {
  local sm=$1 LAB=$2 t0 id now el pend i
  FM_HOME="$LAB" bin/fm-order-ledger.sh poll --home "$LAB" --interval 15 2>"$LAB/poll.err" &
  local poll_pid=$!
  t0=$(date +%s)
  id=$(FM_HOME="$LAB" bin/fm-order-ledger.sh append --home "$LAB" --from firstmate "replay: report your head sha")
  echo "[$sm] appended order id=$id at t=0"
  while :; do
    now=$(date +%s); el=$((now - t0))
    [ "$el" -le 90 ] || { echo "[$sm] NOT acked within 90s"; break; }
    if grep -q 'orders:pending' "$LAB/state/.wake-queue" 2>/dev/null; then
      echo "[$sm] t=${el}s wake row in queue: $(grep orders:pending "$LAB/state/.wake-queue" | tail -1 | cut -c1-220)"
      pend=$(FM_HOME="$LAB" bin/fm-order-ledger.sh pending --home "$LAB")
      echo "[$sm] pending: $pend"
      for i in $(printf '%s\n' "$pend" | awk '{print $1}'); do
        FM_HOME="$LAB" bin/fm-order-ledger.sh ack --home "$LAB" "$i" | sed "s/^/[$sm] /"
      done
      echo "[$sm] ACKED at t=$(( $(date +%s) - t0 ))s (bound 60s)"
      break
    fi
    sleep 5
  done
  sleep 16
  echo "[$sm] pending after next poll: '$(FM_HOME="$LAB" bin/fm-order-ledger.sh pending --home "$LAB")' orders.pending bytes: $(wc -c < "$LAB/state/orders.pending" | tr -d ' ')"
  echo "[$sm] re-ack: $(FM_HOME="$LAB" bin/fm-order-ledger.sh ack --home "$LAB" "$id")"
  echo "[$sm] acks file: $(cat "$LAB/state/orders.acks.jsonl")"
  echo "[$sm] poll stderr: '$(cat "$LAB/poll.err")'"
  kill "$poll_pid" 2>/dev/null
  wait "$poll_pid" 2>/dev/null
}

LAB1=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); bin/fm-lab-home.sh create "$LAB1" >/dev/null
LAB2=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); bin/fm-lab-home.sh create "$LAB2" >/dev/null
echo "lab homes: sm-bosgame=$LAB1 sm-netcup=$LAB2"
run_sm sm-bosgame "$LAB1" &
run_sm sm-netcup "$LAB2" &
wait
rm -rf "$LAB1" "$LAB2"
echo "labs removed"
