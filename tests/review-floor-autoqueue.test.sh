#!/usr/bin/env bash
# tests/review-floor-autoqueue.test.sh - the review-floor auto-queue in the
# netcup lander (tests/fixtures/netcup/bosgame-autoland.sh): a refused lone
# sub-30 s PASS queues the second-family exact-head review itself on the next
# free non-GPT family, at most 2 automatic queues per head, and a head that
# moves while the review is queued cancels it without a re-queue.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LANDER="$ROOT/tests/fixtures/netcup/bosgame-autoland.sh"
TMP_ROOT=$(fm_test_tmproot review-floor-autoqueue)
HEAD1=1111111111111111111111111111111111111111
HEAD2=2222222222222222222222222222222222222222

new_home() {  # <name> -> sets H, with stub queue/cancel commands that log to $H/calls
  H="$TMP_ROOT/$1"
  mkdir -p "$H/state" "$H/data/xreview"
  printf '%s\n' '#!/usr/bin/env bash' 'echo "queue $*" >> "$H/calls"' > "$H/queue.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'echo "cancel $*" >> "$H/calls"' > "$H/cancel.sh"
  chmod +x "$H/queue.sh" "$H/cancel.sh"
  export H FLOOR_QUEUE_CMD="$H/queue.sh" FLOOR_CANCEL_CMD="$H/cancel.sh"
  : > "$H/calls"
}
lone_pass() {  # <pr> <head> <secs>
  printf 'at=1 secs=%s head=%s\nVERDICT: PASS\n' "$3" "$2" > "$H/data/xreview/$1.md"
}
run_floor() {  # <pr> <head> -> floor_ok in a fresh shell that sources only the functions
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

new_home cancel-ends-the-pass
lone_pass 7 $HEAD1 12
run_floor 7 $HEAD1
lone_pass 7 $HEAD2 12
BOSGAME_AUTOLAND_SOURCE_ONLY=1 bash -c '. "$1"; floor_sweep 7 "$2"; floor_ok 7 "$2"' _ "$LANDER" $HEAD2 2>"$H/err"
if grep -q "^cancel 7 muse $HEAD1" "$H/calls" && [ "$(calls)" = 2 ]; then
  pass "a cancel earlier in the pass keeps the new head from queuing in the same pass"
else fail "cancel ends pass: $(cat "$H/calls")"; fi
