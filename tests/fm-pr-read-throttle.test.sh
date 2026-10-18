#!/usr/bin/env bash
# Behavior tests for the shared GitHub PR read throttle (bin/fm-pr-lib.sh,
# bin/fm-pr-read.sh): one provider read per PR per window, concurrent callers
# serialized into that single read, and exponential backoff after a
# secondary-rate-limit refusal with no gh-axi fallback load.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pr-read-throttle)
READ="$ROOT/bin/fm-pr-read.sh"

# Fake gh logs every graphql call; FM_FAKE_LIMIT=1 refuses like the secondary
# limit does. Fake gh-axi logs too so a fallback would be visible.
new_case() {  # <name>
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/fakebin"
  cat > "$d/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf 'gh\n' >> "$FM_FAKE_LOG"
sleep 0.3
if [ "${FM_FAKE_LIMIT:-0}" = 1 ]; then
  echo 'gh: You have exceeded a secondary rate limit. (HTTP 403)' >&2
  exit 1
fi
printf 'state=OPEN\nmerged=false\n'
SH
  cat > "$d/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf 'gh-axi\n' >> "$FM_FAKE_LOG"
exit 1
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

test_secondary_limit_backs_off_without_fallback() {
  local d out; d=$(new_case limit)
  export FM_FAKE_LIMIT=1
  run_read "$d" 3000 5 >/dev/null 2>&1 && fail "limited read with nothing cached must fail"
  assert_equals 1 "$(count "$d" gh)" "the refusal is one provider read"
  assert_equals 0 "$(count "$d" gh-axi)" "a limited read never falls back to gh-axi"
  run_read "$d" 3059 5 >/dev/null 2>&1 && fail "inside the 60s backoff"
  assert_equals 1 "$(count "$d" gh)" "no provider read during the backoff"
  run_read "$d" 3060 5 >/dev/null 2>&1 && fail "second refusal"
  assert_equals 2 "$(count "$d" gh)" "backoff expiry allows one retry"
  run_read "$d" 3179 5 >/dev/null 2>&1 && fail "inside the doubled backoff"
  assert_equals 2 "$(count "$d" gh)" "the backoff doubled to 120s"
  export FM_FAKE_LIMIT=0
  out=$(run_read "$d" 3180 5)
  assert_contains "$out" "state=OPEN" "recovery after the backoff reads again"
  assert_equals 3 "$(count "$d" gh)" "one read after the doubled backoff"
  pass "secondary limit backs off exponentially"
}

test_limit_serves_last_good_record() {
  local d out; d=$(new_case stale)
  export FM_FAKE_LIMIT=0
  run_read "$d" 4000 3 >/dev/null
  export FM_FAKE_LIMIT=1
  out=$(run_read "$d" 4400 3)
  assert_contains "$out" "state=OPEN" "a limited refresh serves the last good record"
  assert_equals 2 "$(count "$d" gh)" "the refresh was attempted once"
  pass "limit serves last good record"
}

test_repeat_calls_in_window_issue_one_read
test_concurrent_callers_are_serialized_into_one_read
test_secondary_limit_backs_off_without_fallback
test_limit_serves_last_good_record
