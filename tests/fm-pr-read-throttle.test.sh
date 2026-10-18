#!/usr/bin/env bash
# Behavior tests for the shared GitHub PR read throttle (bin/fm-pr-lib.sh,
# bin/fm-pr-read.sh): one provider request per PR per window, concurrent
# callers serialized into that single request, a request spent even when its
# caller is killed, exponential global backoff after a secondary-rate-limit
# refusal composed with the per-PR window, and exactly one request per attempt.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pr-read-throttle)
READ="$ROOT/bin/fm-pr-read.sh"

# Fake gh logs every graphql call. FM_FAKE_MODE: ok (default), limit (secondary
# limit 403), forbidden (SAML 403), fail (HTTP 500), slow (sleeps FM_FAKE_SLOW,
# default 3, past any caller bound after logging).
# Fake gh-axi logs too so a second request would be visible.
new_case() {  # <name>
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/fakebin"
  cat > "$d/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf 'gh\n' >> "$FM_FAKE_LOG"
case "${FM_FAKE_MODE:-ok}" in
  limit) echo 'gh: You have exceeded a secondary rate limit. (HTTP 403)' >&2; exit 1 ;;
  forbidden) echo 'gh: Resource protected by organization SAML enforcement. (HTTP 403)' >&2; exit 1 ;;
  fail) echo 'gh: Server Error (HTTP 500)' >&2; exit 1 ;;
  slow) sleep "${FM_FAKE_SLOW:-3}"; exit 1 ;;
esac
sleep 0.3
printf 'state=OPEN\nmerged=false\n'
SH
  cat > "$d/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf 'gh-axi\n' >> "$FM_FAKE_LOG"
printf 'pull_request:\n  state: open\n'
SH
  chmod +x "$d/fakebin/gh" "$d/fakebin/gh-axi"
  : > "$d/log"
  printf '%s\n' "$d"
}

run_read() {  # <case-dir> <now> <number>
  PATH="$1/fakebin:$PATH" FM_FAKE_LOG="$1/log" FM_PR_READ_CACHE_DIR="$1/cache" \
    FM_PR_READ_NOW="$2" "$READ" o r "$3"
}

count() { grep -c "^$2\$" "$1/log" || true; }

test_repeat_calls_in_window_issue_one_read() {
  local d out; d=$(new_case window)
  out=$(run_read "$d" 1000 7)
  assert_contains "$out" "state=OPEN" "first call reads the provider"
  run_read "$d" 1100 7 >/dev/null
  run_read "$d" 1299 7 >/dev/null
  assert_equals 1 "$(count "$d" gh)" "calls inside the window share one provider read"
  run_read "$d" 1300 7 >/dev/null
  assert_equals 2 "$(count "$d" gh)" "the window expiring allows the next read"
  run_read "$d" 1300 8 >/dev/null
  assert_equals 3 "$(count "$d" gh)" "another PR has its own window"
  pass "one provider read per PR per window"
}

test_concurrent_callers_are_serialized_into_one_read() {
  local d n; d=$(new_case concurrent)
  for n in 1 2 3 4 5; do run_read "$d" 2000 9 >"$d/out.$n" & done
  wait
  assert_equals 1 "$(count "$d" gh)" "five concurrent callers issue one provider read"
  pass "concurrent callers serialize"
}

test_secondary_limit_backs_off_globally_and_keeps_the_pr_window() {
  local d out; d=$(new_case limit)
  export FM_FAKE_MODE=limit
  run_read "$d" 3000 5 >/dev/null 2>&1 && fail "limited read with nothing cached must fail"
  assert_equals 1 "$(count "$d" gh)" "the refusal is one provider read"
  assert_equals 0 "$(count "$d" gh-axi)" "a limited read never falls back to gh-axi"
  run_read "$d" 3059 6 >/dev/null 2>&1 && fail "another PR inside the 60s global backoff"
  assert_equals 1 "$(count "$d" gh)" "no provider read for any PR during the backoff"
  run_read "$d" 3060 6 >/dev/null 2>&1 && fail "second refusal"
  assert_equals 2 "$(count "$d" gh)" "backoff expiry allows one retry of a different PR"
  run_read "$d" 3179 7 >/dev/null 2>&1 && fail "inside the doubled backoff"
  assert_equals 2 "$(count "$d" gh)" "the global backoff doubled to 120s"
  run_read "$d" 3180 5 >/dev/null 2>&1 && fail "the first PR is still inside its own 300s window"
  assert_equals 2 "$(count "$d" gh)" "the per-PR window holds after the global backoff expires"
  export FM_FAKE_MODE=ok
  out=$(run_read "$d" 3300 5)
  assert_contains "$out" "state=OPEN" "recovery after the PR window reads again"
  assert_equals 3 "$(count "$d" gh)" "one read once both limits allow it"
  pass "secondary limit backs off globally and keeps the per-PR window"
}

test_limit_serves_last_good_record() {
  local d out; d=$(new_case stale)
  export FM_FAKE_MODE=ok
  run_read "$d" 4000 3 >/dev/null
  export FM_FAKE_MODE=limit
  out=$(run_read "$d" 4400 3)
  assert_contains "$out" "state=OPEN" "a limited refresh serves the last good record"
  assert_equals 2 "$(count "$d" gh)" "the refresh was attempted once"
  out=$(run_read "$d" 4410 3)
  assert_contains "$out" "state=OPEN" "still served inside the window"
  assert_equals 2 "$(count "$d" gh)" "no second request inside the window"
  export FM_FAKE_MODE=ok
  pass "limit serves last good record"
}

test_non_rate_limit_403_spends_only_its_own_window() {
  local d out; d=$(new_case forbidden)
  export FM_FAKE_MODE=forbidden
  run_read "$d" 3500 16 >/dev/null 2>&1 && fail "a forbidden read with nothing cached must fail"
  export FM_FAKE_MODE=ok
  out=$(run_read "$d" 3501 17)
  assert_contains "$out" "state=OPEN" "another PR reads right after a non-rate-limit 403"
  assert_equals 2 "$(count "$d" gh)" "the 403 started no global backoff"
  run_read "$d" 3501 16 >/dev/null 2>&1 && fail "the forbidden PR is inside its own window"
  assert_equals 2 "$(count "$d" gh)" "the forbidden PR spent its own window"
  pass "a non-rate-limit 403 spends only its own PR's window"
}

test_lock_timeout_serves_last_good_record() {
  local d out; d=$(new_case locktimeout)
  export FM_FAKE_MODE=ok
  run_read "$d" 8000 21 >/dev/null
  FM_FAKE_MODE=slow FM_FAKE_SLOW=8 run_read "$d" 8400 22 >/dev/null 2>&1 &
  for _ in $(seq 1 50); do [ "$(count "$d" gh)" = 2 ] && break; sleep 0.1; done
  assert_equals 2 "$(count "$d" gh)" "the slow read holds the lock with its request in flight"
  out=$(run_read "$d" 8400 21) || true
  pkill -f "$d/fakebin" 2>/dev/null
  wait 2>/dev/null
  assert_contains "$out" "state=OPEN" "a reader not granted the lock serves the last good record"
  assert_equals 2 "$(count "$d" gh)" "the reader not granted the lock sent no request"
  pass "lock timeout serves last good record"
}

test_killed_read_still_spends_the_window() {
  local d rc=0; d=$(new_case killed)
  export FM_FAKE_MODE=slow
  PATH="$d/fakebin:$PATH" FM_FAKE_LOG="$d/log" FM_PR_READ_CACHE_DIR="$d/cache" FM_PR_READ_NOW=5000 \
    perl -e 'alarm 2; exec @ARGV' "$READ" o r 11 >/dev/null 2>&1 && rc=0 || rc=$?
  [ "$rc" != 0 ] || fail "the slow read should have been killed"
  assert_equals 1 "$(count "$d" gh)" "the killed caller had sent its request"
  export FM_FAKE_MODE=ok
  run_read "$d" 5010 11 >/dev/null 2>&1 && fail "no cached record exists to serve"
  run_read "$d" 5299 11 >/dev/null 2>&1
  assert_equals 1 "$(count "$d" gh)" "recovery inside the window issues no second request"
  run_read "$d" 5300 11 >/dev/null
  assert_equals 2 "$(count "$d" gh)" "the next window allows a read again"
  pass "a killed read still spends the window"
}

test_dead_lock_holder_never_blocks_the_next_reader() {
  local d out; d=$(new_case deadlock)
  export FM_FAKE_MODE=slow
  PATH="$d/fakebin:$PATH" FM_FAKE_LOG="$d/log" FM_PR_READ_CACHE_DIR="$d/cache" FM_PR_READ_NOW=6000 \
    "$READ" o r 12 >/dev/null 2>&1 &
  sleep 0.5
  kill -9 "$!" 2>/dev/null
  pkill -f "$d/fakebin" 2>/dev/null
  wait 2>/dev/null
  export FM_FAKE_MODE=ok
  out=$(run_read "$d" 6400 13)
  assert_contains "$out" "state=OPEN" "a reader after a killed lock holder proceeds at once"
  pass "dead lock holder never blocks the next reader"
}

test_one_request_per_attempt() {
  local d; d=$(new_case single)
  export FM_FAKE_MODE=fail
  run_read "$d" 7000 14 >/dev/null 2>&1 && fail "a failed read with nothing cached must fail"
  assert_equals 1 "$(count "$d" gh)" "the failure was one request"
  assert_equals 0 "$(count "$d" gh-axi)" "a failed gh request is not repeated through gh-axi"
  export FM_FAKE_MODE=ok
  # gh absent: gh-axi is the provider.
  rm "$d/fakebin/gh"
  mkdir -p "$d/bin"
  for t in bash env perl sed grep awk tr head dirname date id mkdir cat rm mv sleep; do
    ln -sf "$(command -v "$t")" "$d/bin/$t" 2>/dev/null
  done
  ln -sf "$d/fakebin/gh-axi" "$d/bin/gh-axi"
  PATH="$d/bin" FM_FAKE_LOG="$d/log" FM_PR_READ_CACHE_DIR="$d/cache" FM_PR_READ_NOW=7000 \
    "$(command -v bash)" "$READ" o r 15 >/dev/null 2>&1
  assert_equals 1 "$(count "$d" gh-axi)" "gh-axi serves when gh is not installed"
  pass "one request per attempt, gh-axi only when gh is absent"
}

test_repeat_calls_in_window_issue_one_read
test_concurrent_callers_are_serialized_into_one_read
test_secondary_limit_backs_off_globally_and_keeps_the_pr_window
test_limit_serves_last_good_record
test_non_rate_limit_403_spends_only_its_own_window
test_lock_timeout_serves_last_good_record
test_killed_read_still_spends_the_window
test_dead_lock_holder_never_blocks_the_next_reader
test_one_request_per_attempt
