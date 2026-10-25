#!/usr/bin/env bash
# tests/review-floor-autoqueue.test.sh - the review-floor auto-queue in the
# netcup lander (tests/fixtures/netcup/bosgame-autoland.sh): a refused lone
# sub-30 s PASS queues the second-family exact-head review itself on the next
# free non-GPT family, at most 2 automatic queues per head, and a head that
# moves while the review is queued cancels it without a re-queue.
# shellcheck disable=SC2016 # The generated shims and the perl flock stand-in are single-quoted on purpose.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LANDER="$ROOT/tests/fixtures/netcup/bosgame-autoland.sh"
TMP_ROOT=$(fm_test_tmproot review-floor-autoqueue)
# The lander takes its queue lock with flock(1), which macOS lacks; a perl shim with the same `flock -w <secs> <fd>` contract stands in there.
if ! command -v flock >/dev/null 2>&1; then
  mkdir -p "$TMP_ROOT/shim"
  printf '%s\n' '#!/usr/bin/env perl' 'use Fcntl qw(:flock); use Time::HiRes qw(sleep time);' \
    'my ($w, $fd) = ($ARGV[1], $ARGV[2]); open(my $fh, ">&=", $fd) or exit 1; my $end = time + $w;' \
    'until (flock($fh, LOCK_EX | LOCK_NB)) { exit 1 if time >= $end; sleep 0.05 } exit 0' > "$TMP_ROOT/shim/flock"
  chmod +x "$TMP_ROOT/shim/flock"
  export PATH="$TMP_ROOT/shim:$PATH"
fi
HEAD1=1111111111111111111111111111111111111111
HEAD2=2222222222222222222222222222222222222222

new_home() {  # <name> -> sets H, with stub queue/cancel commands that log to $H/calls
  H="$TMP_ROOT/$1"
  mkdir -p "$H/state" "$H/data/xreview"
  printf '%s\n' '#!/usr/bin/env bash' 'echo "queue $*" >> "$H/calls"' > "$H/queue.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'echo "cancel $*" >> "$H/calls"' > "$H/cancel.sh"
  chmod +x "$H/queue.sh" "$H/cancel.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'cat "$H/curhead" 2>/dev/null' > "$H/nohead.sh"   # forge lookup: the pass's own head, as written by run_floor
  chmod +x "$H/nohead.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'echo "${AUTHOR-kimi}"' > "$H/author.sh"; chmod +x "$H/author.sh"
  printf 'muse grok\n' > "$H/data/floor-families"
  export H FLOOR_AUTHOR_CMD="$H/author.sh" FLOOR_QUEUE_CMD="$H/queue.sh" FLOOR_CANCEL_CMD="$H/cancel.sh" FLOOR_HEAD_CMD="$H/nohead.sh"
  : > "$H/calls"
}
lone_pass() {  # <pr> <head> <secs>
  printf 'at=1 secs=%s head=%s\nVERDICT: PASS\n' "$3" "$2" > "$H/data/xreview/$1.md"
}
run_floor() {  # <pr> <head> -> floor_ok in a fresh shell that sources only the functions
  printf '%s' "$2" > "$H/curhead"
  BOSGAME_AUTOLAND_SOURCE_ONLY=1 bash -c '. "$1"; floor_ok "$2" "$3"' _ "$LANDER" "$1" "$2" 2>"$H/err"
}
calls() { wc -l < "$H/calls" | tr -d ' '; }

new_home trigger
lone_pass 7 $HEAD1 12
run_floor 7 $HEAD1; rc=$?
if [ "$rc" = 1 ] && [ "$(calls)" = 1 ] && grep -q "^queue muse 7 $HEAD1 " "$H/calls"; then
  pass "refused lone sub-30 s PASS queues one second-family review"
else fail "trigger: rc=$rc calls=$(cat "$H/calls")"; fi

new_home no-trigger-long
lone_pass 7 $HEAD1 45
run_floor 7 $HEAD1; rc=$?
if [ "$rc" = 0 ] && [ "$(calls)" = 0 ]; then pass "a 30 s or longer review passes the floor and queues nothing"
else fail "long review: rc=$rc"; fi

new_home no-trigger-fam2
lone_pass 7 $HEAD1 12
printf 'at=2 head=%s\nVERDICT: PASS\n' $HEAD1 > "$H/data/xreview/7-fam2.md"
run_floor 7 $HEAD1; rc=$?
if [ "$rc" = 0 ] && [ "$(calls)" = 0 ]; then pass "an exact-head second-family PASS passes the floor and queues nothing"
else fail "fam2 pass: rc=$rc"; fi

new_home kill-switch
lone_pass 7 $HEAD1 12
: > "$H/data/floor-autoqueue.off"
run_floor 7 $HEAD1; rc=$?
if [ "$rc" = 1 ] && [ "$(calls)" = 0 ]; then pass "the kill switch keeps the refusal but queues nothing"
else fail "kill switch: rc=$rc"; fi

new_home family-next-free
lone_pass 7 $HEAD1 12
lone_pass 8 $HEAD1 12
run_floor 7 $HEAD1
run_floor 8 $HEAD1
if grep -q "^queue muse 7 " "$H/calls" && grep -q "^queue grok 8 " "$H/calls"; then
  pass "the second PR takes the next free family while the first holds muse"
else fail "family order: $(cat "$H/calls")"; fi

new_home family-skips-gpt
lone_pass 7 $HEAD1 12
printf 'gpt-6.1-sol\ncodex grok\n' > "$H/data/floor-families"
run_floor 7 $HEAD1
if [ "$(cat "$H/calls")" = "queue grok 7 $HEAD1 $H/data/xreview/7-fam2.md" ]; then pass "GPT-family entries are never queued"
else fail "gpt skip: $(cat "$H/calls")"; fi

new_home family-skips-primary-reviewer
lone_pass 7 $HEAD1 12
printf 'kimi muse\n' > "$H/data/floor-families"
run_floor 7 $HEAD1
if [ "$(cat "$H/calls")" = "queue muse 7 $HEAD1 $H/data/xreview/7-fam2.md" ]; then pass "the primary reviewer's family is never queued, even when configured"
else fail "primary skip: $(cat "$H/calls")"; fi

new_home queue-fails-falls-through
lone_pass 7 $HEAD1 12
printf '%s\n' '#!/usr/bin/env bash' 'echo "queue $*" >> "$H/calls"' '[ "$1" != muse ]' > "$H/queue.sh"
run_floor 7 $HEAD1
if grep -q "^queue grok 7 " "$H/calls" && [ -e "$H/state/.floor-q-7" ] && [ ! -e "$H/state/.floor-n-7-$HEAD1-muse" ]; then
  pass "a family whose queue command fails is skipped and not counted"
else fail "fallthrough: $(cat "$H/calls")"; fi

new_home cap
lone_pass 7 $HEAD1 12
run_floor 7 $HEAD1
rm -f "$H/state/.floor-q-7"   # the first review ended without a usable record for this head
run_floor 7 $HEAD1
rm -f "$H/state/.floor-q-7"
run_floor 7 $HEAD1
run_floor 7 $HEAD1
if [ "$(calls)" = 2 ] && grep -q "^queue muse " "$H/calls" && grep -q "^queue grok " "$H/calls"; then
  pass "at most 2 automatic queues per head, each on a different family"
else fail "cap: $(cat "$H/calls")"; fi

new_home still-queued
lone_pass 7 $HEAD1 12
run_floor 7 $HEAD1
run_floor 7 $HEAD1
if [ "$(calls)" = 1 ]; then pass "a refusal while a review is already queued does not queue another"
else fail "still queued: $(cat "$H/calls")"; fi

new_home head-moves
lone_pass 7 $HEAD1 12
run_floor 7 $HEAD1
lone_pass 7 $HEAD2 12
run_floor 7 $HEAD2
if grep -q "^cancel 7 muse $HEAD1" "$H/calls" && ! grep -q "^queue .* $HEAD2 " "$H/calls" && [ ! -e "$H/state/.floor-q-7" ]; then
  pass "a head that moves while queued cancels the old review and does not re-queue"
else fail "head move: $(cat "$H/calls")"; fi
run_floor 7 $HEAD2
if grep -q "^queue muse 7 $HEAD2 " "$H/calls"; then pass "the new head is judged on a later pass with its own queues"
else fail "new head: $(cat "$H/calls")"; fi

new_home finished-review-clears-record
lone_pass 7 $HEAD1 12
run_floor 7 $HEAD1
sleep 1
printf 'at=2 head=%s\nVERDICT: FAIL\n' $HEAD1 > "$H/data/xreview/7-fam2.md"
BOSGAME_AUTOLAND_SOURCE_ONLY=1 bash -c '. "$1"; floor_sweep 7 "$2"' _ "$LANDER" $HEAD2
if [ ! -e "$H/state/.floor-q-7" ] && ! grep -q '^cancel' "$H/calls"; then
  pass "a finished second-family review clears its queue record without a cancel"
else fail "finished: $(cat "$H/calls")"; fi

new_home stale-record-is-not-completion
lone_pass 7 $HEAD1 12
printf 'at=0 head=%s\nVERDICT: FAIL\n' $HEAD1 > "$H/data/xreview/7-fam2.md"   # left over from an earlier automatic review of this head
sleep 1
run_floor 7 $HEAD1
BOSGAME_AUTOLAND_SOURCE_ONLY=1 bash -c '. "$1"; floor_sweep 7 "$2"' _ "$LANDER" $HEAD2
if grep -q "^cancel 7 muse $HEAD1" "$H/calls" && [ ! -e "$H/state/.floor-q-7" ]; then
  pass "an older second-family record does not count as completion of a newer queue"
else fail "stale record: $(cat "$H/calls")"; fi

new_home completion-before-queue-returns
lone_pass 7 $HEAD1 12
printf '%s\n' '#!/usr/bin/env bash' 'echo "queue $*" >> "$H/calls"' 'sleep 1' 'printf "at=2 head=%s\nVERDICT: FAIL\n" "$3" > "$4"' > "$H/queue.sh"
run_floor 7 $HEAD1
BOSGAME_AUTOLAND_SOURCE_ONLY=1 bash -c '. "$1"; floor_sweep 7 "$2"' _ "$LANDER" $HEAD1
if [ ! -e "$H/state/.floor-q-7" ]; then pass "a review that finishes before the queue command returns still clears its record"
else fail "early completion: record left behind"; fi

new_home concurrent-refusals-respect-the-cap
lone_pass 7 $HEAD1 12
printf '%s\n' '#!/usr/bin/env bash' 'echo "queue $*" >> "$H/calls"' 'sleep 0.3' > "$H/queue.sh"
run_floor 7 $HEAD1 &
run_floor 7 $HEAD1 &
wait
if [ "$(calls)" = 1 ]; then pass "two overlapping refusals of one PR launch a single review"
else fail "concurrent: $(cat "$H/calls")"; fi

new_home launcher-cannot-eat-the-family-list
lone_pass 7 $HEAD1 12
printf '%s\n' '#!/usr/bin/env bash' 'echo "queue $*" >> "$H/calls"' 'cat > /dev/null' '[ "$1" != muse ]' > "$H/queue.sh"
run_floor 7 $HEAD1
if grep -q "^queue grok 7 " "$H/calls"; then pass "a launcher that reads stdin does not swallow the remaining families"
else fail "stdin: $(cat "$H/calls")"; fi

new_home sweep-respects-the-queue-lock
lone_pass 7 $HEAD1 12
run_floor 7 $HEAD1
( exec 8>"$H/state/.floor-lock"; flock -w 5 8; sleep 4 ) &   # another pass holds the lock
holder=$!
sleep 0.5
FLOOR_LOCK_WAIT=1 BOSGAME_AUTOLAND_SOURCE_ONLY=1 bash -c '. "$1"; floor_sweep 7 "$2"' _ "$LANDER" $HEAD2 2>/dev/null
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
if [ -e "$H/state/.floor-q-7" ] && ! grep -q '^cancel' "$H/calls"; then
  pass "a sweep never mutates the queue records while another pass holds the lock"
else fail "sweep lock: $(cat "$H/calls")"; fi

new_home superseded-head-is-never-queued
lone_pass 7 $HEAD1 12
printf '%s\n' '#!/usr/bin/env bash' "echo $HEAD2" > "$H/head.sh"
chmod +x "$H/head.sh"
FLOOR_HEAD_CMD="$H/head.sh" run_floor 7 $HEAD1
if [ "$(calls)" = 0 ] && [ ! -e "$H/state/.floor-q-7" ]; then pass "a head that moved while the pass waited for the lock is not queued"
else fail "superseded: $(cat "$H/calls")"; fi

new_home stale-pass-cannot-cancel-the-newer-review
lone_pass 7 $HEAD2 12
run_floor 7 $HEAD2
lone_pass 7 $HEAD1 12
printf '%s\n' '#!/usr/bin/env bash' "echo $HEAD2" > "$H/nohead.sh"   # the forge still says HEAD2 for the pass that captured HEAD1
BOSGAME_AUTOLAND_SOURCE_ONLY=1 bash -c '. "$1"; floor_ok 7 "$2"' _ "$LANDER" $HEAD1 2>/dev/null
if ! grep -q '^cancel' "$H/calls" && [ "$(cut -d' ' -f1 "$H/state/.floor-q-7")" = "$HEAD2" ] && [ "$(calls)" = 1 ]; then
  pass "a pass holding a superseded head neither cancels nor replaces the newer head's review"
else fail "stale pass: $(cat "$H/calls")"; fi

new_home failed-head-lookup-queues-nothing
lone_pass 7 $HEAD1 12
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$H/nohead.sh"
run_floor 7 $HEAD1
if [ "$(calls)" = 0 ] && [ ! -e "$H/state/.floor-q-7" ]; then pass "a failed or empty forge head lookup queues nothing"
else fail "lookup failure: $(cat "$H/calls")"; fi

new_home dead-holder-lock-is-recovered
lone_pass 7 $HEAD1 12
( exec 8>"$H/state/.floor-lock"; flock -w 5 8; sleep 30 ) &   # a pass takes the lock, then is killed
holder=$!
sleep 0.5
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
run_floor 7 $HEAD1
if [ "$(calls)" = 1 ]; then pass "a lock whose holder was killed is released by the kernel and the queue proceeds"
else fail "stale lock: $(cat "$H/calls")"; fi

new_home cancel-ends-the-pass
lone_pass 7 $HEAD1 12
run_floor 7 $HEAD1
lone_pass 7 $HEAD2 12
BOSGAME_AUTOLAND_SOURCE_ONLY=1 bash -c '. "$1"; floor_sweep 7 "$2"; floor_ok 7 "$2"' _ "$LANDER" $HEAD2 2>"$H/err"
if grep -q "^cancel 7 muse $HEAD1" "$H/calls" && [ "$(calls)" = 2 ]; then
  pass "a cancel earlier in the pass keeps the new head from queuing in the same pass"
else fail "cancel ends pass: $(cat "$H/calls")"; fi

# Sol-high fallback: when no non-GPT family is free
only_busy() {  # only muse is configured and its queue fails; the stub accepts sol-high
  printf 'muse\n' > "$H/data/floor-families"
  printf '%s\n' '#!/usr/bin/env bash' 'echo "queue $*" >> "$H/calls"' '[ "$1" = sol-high ]' > "$H/queue.sh"
}

new_home fallback-fires-only-when-none-free
lone_pass 7 $HEAD1 12
run_floor 7 $HEAD1
if [ "$(calls)" = 1 ] && grep -q "^queue muse 7 " "$H/calls" && ! grep -q sol-high "$H/calls"; then
  pass "the Sol-high fallback is not used while a non-GPT family is free"
else fail "fallback unused: $(cat "$H/calls")"; fi

new_home fallback-runs-30s
lone_pass 7 $HEAD1 12
only_busy
run_floor 7 $HEAD1
if grep -q "^queue sol-high 7 $HEAD1 $H/data/xreview/7-fam2.md --min-secs 30\$" "$H/calls" && [ "$(cut -d' ' -f2 "$H/state/.floor-q-7")" = sol-high ]; then
  pass "with no free non-GPT family one Sol-high exact-head review is queued with a 30 s minimum"
else fail "fallback: $(cat "$H/calls")"; fi

new_home fallback-counts-toward-cap
lone_pass 7 $HEAD1 12
only_busy
run_floor 7 $HEAD1
rm -f "$H/state/.floor-q-7"
printf '%s\n' '#!/usr/bin/env bash' 'echo "queue $*" >> "$H/calls"' > "$H/queue.sh"
run_floor 7 $HEAD1   # second try takes muse
rm -f "$H/state/.floor-q-7"
run_floor 7 $HEAD1   # third refused
if [ "$(calls)" = 3 ] && [ "$(grep -c '^queue muse' "$H/calls")" = 2 ] && [ -e "$H/state/.floor-n-7-$HEAD1-sol-high" ]; then
  pass "the fallback stamp counts toward the 2 per head and a third attempt is refused"
else fail "fallback cap: $(cat "$H/calls")"; fi

new_home fallback-not-repeated
lone_pass 7 $HEAD1 12
only_busy
run_floor 7 $HEAD1
rm -f "$H/state/.floor-q-7"
run_floor 7 $HEAD1
if [ "$(grep -c sol-high "$H/calls")" = 1 ]; then pass "the fallback is not retried for the same head"
else fail "fallback repeat: $(cat "$H/calls")"; fi

new_home fallback-head-move-cancels
lone_pass 7 $HEAD1 12
only_busy
run_floor 7 $HEAD1
lone_pass 7 $HEAD2 12
run_floor 7 $HEAD2
if grep -q "^cancel 7 sol-high $HEAD1" "$H/calls" && [ ! -e "$H/state/.floor-q-7" ]; then
  pass "a head move cancels a queued fallback review"
else fail "fallback cancel: $(cat "$H/calls")"; fi

new_home fallback-kill-switch
lone_pass 7 $HEAD1 12
only_busy
: > "$H/data/floor-autoqueue.off"
run_floor 7 $HEAD1
if [ "$(calls)" = 0 ]; then pass "the kill switch suppresses the fallback"
else fail "fallback kill: $(cat "$H/calls")"; fi

new_home fallback-dry
lone_pass 7 $HEAD1 12
only_busy
DRY=1 run_floor 7 $HEAD1
if [ "$(calls)" = 0 ]; then pass "a dry run suppresses the fallback"
else fail "fallback dry: $(cat "$H/calls")"; fi

cascade_home() {  # <name> <author>: default cascade families, author fixed
  new_home "$1"; rm -f "$H/data/floor-families"; lone_pass 7 $HEAD1 12; export AUTHOR=$2
}
cascade_home cascade-kimi-author kimi
run_floor 7 $HEAD1
if grep -q "^queue muse-bosgame 7 " "$H/calls"; then pass "cascade: a non-Muse, non-Claude author gets the bosgame Muse review first"
else fail "cascade muse: $(cat "$H/calls")"; fi
cascade_home cascade-muse-author muse
run_floor 7 $HEAD1
if [ "$(calls)" = 1 ] && grep -q "^queue sol-high 7 " "$H/calls"; then pass "cascade: a Muse-authored head skips Muse and Sonnet and lands on Sol-high"
else fail "cascade muse author: $(cat "$H/calls")"; fi
cascade_home cascade-claude-author claude
run_floor 7 $HEAD1
if grep -q "^queue muse-bosgame 7 " "$H/calls" && ! grep -q sonnet "$H/calls"; then pass "cascade: a Claude-authored head still gets Muse, never Sonnet"
else fail "cascade claude: $(cat "$H/calls")"; fi
cascade_home cascade-muse-busy kimi
printf '%s\n' '#!/usr/bin/env bash' 'echo "queue $*" >> "$H/calls"' '[ "$1" != muse-bosgame ]' > "$H/queue.sh"
run_floor 7 $HEAD1
if grep -q "^queue sonnet-gate 7 " "$H/calls"; then pass "cascade: Sonnet is next when the Muse route is unavailable for a non-Claude author"
else fail "cascade sonnet: $(cat "$H/calls")"; fi
cascade_home cascade-unknown-author ""
run_floor 7 $HEAD1
if [ "$(calls)" = 1 ] && grep -q "^queue sol-high 7 " "$H/calls"; then pass "cascade: an unknown author goes straight to Sol-high"
else fail "cascade unknown: $(cat "$H/calls")"; fi
unset AUTHOR
