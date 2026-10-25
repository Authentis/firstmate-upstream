#!/usr/bin/env bash
# tests/fm-remote-send-dedup-code.test.sh - the remote secondmate send leg
# (bin/fm-remote-secondmate-control.sh cmd_send) must distinguish a dedup hit
# on an already-acknowledged record from a fresh delivery: a re-sent identical
# steer that lands on handled/ exits 4 (already-delivered, nothing re-rung),
# not 0, so launch-counting senders stop spending budget on ghosts while
# fm-send.sh still treats 4 as delivered.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONTROL="$ROOT/bin/fm-remote-secondmate-control.sh"
TMP_ROOT=$(fm_test_tmproot fm-remote-send-dedup)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
HOME_DIR="$TMP_ROOT/home"
STATE="$HOME_DIR/state/parent-route"

mkdir -p "$HOME_DIR/bin" "$STATE"
printf 'testmate' > "$HOME_DIR/.fm-secondmate-home"
printf '# test\n' > "$HOME_DIR/AGENTS.md"
cat > "$STATE/testmate.meta" <<'META'
endpoint_task_id=testmate
window=fm-remote:w9:p2
worktree=/tmp/fake-wt
project=/tmp/fake-proj
backend=herdr
herdr_session=fm-remote
herdr_workspace_id=w9
herdr_tab_id=w9:t2
herdr_pane_id=w9:p2
META

BODY='refill leaf 10.724 identical payload'

FM_HOME="$HOME_DIR" "$CONTROL" send testmate "$BODY" </dev/null >/dev/null 2>&1 \
  || fail "first send of a fresh steer should exit 0"
REC=$(ls "$STATE"/testmate.inbox/*.msg 2>/dev/null | head -n 1)
[ -n "$REC" ] || fail "first send should leave a record in the inbox"
mv "$REC" "$STATE/testmate.inbox/handled/" || fail "could not acknowledge the record"

rc=0
err=$TMP_ROOT/stderr.txt
FM_HOME="$HOME_DIR" "$CONTROL" send testmate "$BODY" </dev/null >/dev/null 2>"$err" || rc=$?
[ "$rc" -eq 4 ] || fail "re-send landing on a handled record should exit 4 (already-delivered), got $rc"
grep -q 'already delivered' "$err" || fail "re-send should keep the already-delivered notice on stderr"
count=$(ls "$STATE"/testmate.inbox/*.msg 2>/dev/null | wc -l | tr -d ' ')
[ "$count" -eq 0 ] || fail "dedup re-send must not create a second record, found $count"

pass "dedup re-send exits 4 with notice and no duplicate record"
