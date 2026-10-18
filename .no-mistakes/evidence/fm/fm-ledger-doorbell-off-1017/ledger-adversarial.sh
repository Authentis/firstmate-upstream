#!/usr/bin/env bash
# Adversarial ledger checks against a disposable lab home.
set -u
cd "$1" || exit 1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); bin/fm-lab-home.sh create "$LAB" >/dev/null
L() { FM_HOME="$LAB" bin/fm-order-ledger.sh "$@" --home "$LAB"; }
step() { printf '\n$ %s\n' "$*"; }
wakes() { grep -c 'orders:pending' "$LAB/state/.wake-queue" 2>/dev/null || echo 0; }

step "append three orders"; L append "order A"; L append "order B"; L append "order C"
step "poll --once twice -> exactly one wake row (never stacks)"; L poll --once; L poll --once; echo "orders:pending wake rows: $(wakes)"
step "ack 2 only (out of order)"; L ack 2; echo "rc=$?"
step "pending (1 and 3 remain; acking 2 did not ack 1)"; L pending
step "ack 2 again -> idempotent"; L ack 2; echo "rc=$?"
step "ack 99 (no such line) -> refused"; L ack 99; echo "rc=$?"
step "ack abc -> refused"; L ack abc; echo "rc=$?"
step "real wake drain consumes the queue (fm-wake-drain.sh --ack)"
FM_HOME="$LAB" bin/fm-wake-drain.sh 2>&1 | grep -i 'order' | cut -c1-200
ACK=$(FM_HOME="$LAB" bin/fm-wake-drain.sh 2>&1 | sed -n 's/.*\(bin\/fm-wake-drain.sh --ack[^`]*\).*/\1/p' | head -1)
echo "drain ack command: ${ACK:-<none printed>}"
[ -n "$ACK" ] && FM_HOME="$LAB" bash -c "$ACK" >/dev/null 2>&1
echo "orders:pending wake rows after drain ack: $(wakes)"
step "poll again while 1,3 still pending -> wake re-queued (delivery repeats)"; L poll --once; echo "orders:pending wake rows: $(wakes)"
step "ack 1 3; poll -> nothing pending, view empty"; L ack 1 3; L poll --once; echo "pending='$(L pending)' view bytes=$(wc -c < "$LAB/state/orders.pending" | tr -d ' ')"
step "corrupt acks file -> poll and pending fail loudly, view kept"
cp "$LAB/state/orders.pending" /dev/null
printf 'not json\n' >> "$LAB/state/orders.acks.jsonl"
L poll --once; echo "poll rc=$?"
L pending; echo "pending rc=$?"
step "acks path is a directory -> fails loudly instead of reading as no acks"
rm -f "$LAB/state/orders.acks.jsonl"; mkdir "$LAB/state/orders.acks.jsonl"
L pending; echo "pending rc=$?"
rm -rf "$LAB"; echo; echo "lab removed"
