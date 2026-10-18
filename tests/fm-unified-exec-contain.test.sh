#!/usr/bin/env bash
# Behavior tests for bin/fm-unified-exec-contain.sh: the installer's anchored,
# idempotent patching of a pi-unified-exec package copy, and the patched
# runtime behavior - exited records are reaped with a log line each, while a
# live session or one with an armed on_exit wake is never reaped or evicted.
# The behavior checks run the patched SessionStore and reap module in node
# against duck-typed sessions; nothing asserts source bytes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-unified-exec-contain-tests)
FIX="$ROOT/tests/fixtures/unified-exec-contain"
SCRIPT="$ROOT/bin/fm-unified-exec-contain.sh"

if ! node --experimental-strip-types --no-warnings -e 'process.exit(0)' >/dev/null 2>&1; then
  echo "SKIP: node without --experimental-strip-types"
  exit 0
fi

new_pkg() {  # <name>
  mkdir -p "$TMP_ROOT/$1"
  cp -R "$FIX/." "$TMP_ROOT/$1/"
  echo "$TMP_ROOT/$1"
}

PKG=$(new_pkg ok)
assert_equals "unpatched" "$("$SCRIPT" check "$PKG")" "fresh package reports unpatched"
assert_equals "applied" "$("$SCRIPT" apply "$PKG")" "first apply patches"
assert_equals "already applied" "$("$SCRIPT" apply "$PKG")" "second apply is a no-op"
assert_equals "patched" "$("$SCRIPT" check "$PKG")" "check reports patched"
assert_present "$PKG/src/session-store.ts.fm-orig" "original kept once"

DRIFT=$(new_pkg drift)
sed -i.bak 's/lruProtectedCount: number;/lruProtectedCount: bigint;/' "$DRIFT/src/session-store.ts"
before=$(cksum <"$DRIFT/src/index.ts")
"$SCRIPT" apply "$DRIFT" >/dev/null 2>&1
expect_code 2 "$?" "anchor drift refuses apply"
assert_equals "$before" "$(cksum <"$DRIFT/src/index.ts")" "anchor drift writes nothing"
assert_absent "$DRIFT/src/reap.ts" "anchor drift installs no module"

cat >"$TMP_ROOT/behavior.mjs" <<JS
import assert from "node:assert/strict";
import { SessionStore } from "$PKG/src/session-store.ts";
import { createReaper, isPinnedSession } from "$PKG/src/reap.ts";

let t = 1000;
const mk = (id, o = {}) => ({
  id, hasExited: false, exitCode: null, signal: null, lastUsed: t++,
  displayCommand: "sleep 1", terminate() { this.terminated = true; }, ...o,
});
const exited = (id, o = {}) => mk(id, { hasExited: true, exitCode: 0, ...o });

// Retained exited records are reaped; live sessions never are.
{
  const sessions = new Map();
  for (let i = 1; i <= 12; i++) sessions.set(i, exited(i));
  sessions.set(13, mk(13));
  sessions.set(14, mk(14, { displayCommand: "bash bin/fm-watch-arm.sh --restart" }));
  const lines = [];
  const reaper = createReaper({
    list: () => [...sessions.values()],
    armed: () => false,
    remove: (id) => sessions.delete(id),
    log: (l) => lines.push(l),
    env: { PI_UNIFIED_EXEC_REAP_KEEP: "3" },
  });
  const reaped = reaper.reapOnce();
  assert.equal(reaped.length, 9, "keeps the newest 3 exited records");
  assert.deepEqual([...sessions.keys()].filter((id) => id <= 12), [10, 11, 12], "newest exited kept");
  assert.ok(sessions.has(13) && sessions.has(14), "live sessions untouched");
  assert.equal(lines.length, 9, "every reap is logged");
  assert.match(lines[0], /reaped session=1 exit_code=0/);
}

// Exit not yet known, or wake still armed: never reaped.
{
  const sessions = new Map([
    [1, exited(1, { exitCode: null, signal: null })],
    [2, exited(2)],
    [3, exited(3)],
    [4, exited(4)],
  ]);
  const reaper = createReaper({
    list: () => [...sessions.values()],
    armed: (id) => id === 2,
    remove: (id) => sessions.delete(id),
    log: () => {},
    env: { PI_UNIFIED_EXEC_REAP_KEEP: "0" },
  });
  assert.deepEqual(reaper.reapOnce().sort(), [3, 4], "unknown exit and armed wake are skipped");
  assert.ok(sessions.has(1) && sessions.has(2));
}

// A live session with an armed on_exit wake survives every pass.
{
  const live = mk(1);
  const sessions = new Map([[1, live]]);
  const reaper = createReaper({
    list: () => [...sessions.values()],
    armed: () => true,
    remove: (id) => sessions.delete(id),
    log: () => {},
    env: { PI_UNIFIED_EXEC_REAP_KEEP: "0" },
  });
  for (let i = 0; i < 3; i++) assert.deepEqual(reaper.reapOnce(), []);
  assert.ok(sessions.has(1) && !live.terminated, "armed on_exit session survives");
}

// The LRU never evicts the watch timer or a wake-armed live session.
{
  const armedIds = new Set([2]);
  const pinned = (s) => isPinnedSession(s, (id) => armedIds.has(id));
  const store = new SessionStore({ maxSessions: 4, lruProtectedCount: 1, isPinned: pinned });
  const watch = mk(1, { displayCommand: "bash /x/bin/fm-watch-arm.sh --restart" });
  const armedLive = mk(2);
  const plain = mk(3);
  const newest = mk(4);
  for (const s of [watch, armedLive, plain, newest]) store.insert(s);
  const { pruned } = store.insert(mk(5));
  assert.equal(pruned?.id, 3, "the unpinned older session is the victim");
  assert.ok(!watch.terminated && !armedLive.terminated);
  // Only pinned sessions are eligible: nothing is evicted and the cap is exceeded.
  const store2 = new SessionStore({ maxSessions: 2, lruProtectedCount: 1, isPinned: pinned });
  const w2 = mk(1, { displayCommand: "fm-watch.sh" });
  store2.insert(w2);
  store2.insert(mk(9));
  armedIds.add(9);
  const res = store2.insert(mk(10));
  assert.equal(res.pruned, undefined, "nothing evicted when only pinned sessions are eligible");
  assert.equal(store2.size, 3);
  assert.ok(!w2.terminated);
}
console.log("behavior ok");
JS
out=$(node --experimental-strip-types --no-warnings "$TMP_ROOT/behavior.mjs" 2>&1)
assert_equals "behavior ok" "$out" "patched runtime behavior"

pass "unified-exec containment installs idempotently and reaps without touching live sessions"
