#!/usr/bin/env bash
# Behavior tests for bin/fm-sm-context.sh and bin/fm-sm-context-check.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-sm-context)
FM="$TMP_ROOT/fm"
CLAUDE="$TMP_ROOT/claude"
LOCAL_HOME="$TMP_ROOT/mate-local"
REMOTE_HOME="$TMP_ROOT/mate-remote"
mkdir -p "$FM/data" "$FM/state" "$CLAUDE/projects" "$LOCAL_HOME" "$REMOTE_HOME"

cat > "$FM/data/secondmates.md" <<EOF
- loc - Local mate. (home: $LOCAL_HOME; scope: local things; projects: ; added 2026-10-01)
- rem - Remote mate. (host: fakehost; root: /srv/fm; home: $REMOTE_HOME; scope: remote things; projects: ; added 2026-10-01)
- cdx - Codex mate. (home: $TMP_ROOT/mate-codex; scope: codex things; projects: ; added 2026-10-01)
EOF
printf 'harness=claude\nkind=secondmate\n' > "$FM/state/loc.meta"
printf 'harness=claude\nkind=secondmate\n' > "$FM/state/rem.meta"
printf 'harness=codex\nkind=secondmate\n' > "$FM/state/cdx.meta"

# write_transcript <home> <first-ts> <input> <cache-read> <cache-create>
write_transcript() {
  local home=$1 dir
  dir="$CLAUDE/projects/$(printf '%s' "$home" | sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "$dir"
  {
    printf '{"type":"last-prompt","sessionId":"s1"}\n'
    printf '{"type":"user","timestamp":"%s","message":{"content":"hi"}}\n' "$2"
    printf '{"type":"assistant","timestamp":"%s","message":{"usage":{"input_tokens":999,"cache_creation_input_tokens":1,"cache_read_input_tokens":1,"output_tokens":5}}}\n' "$2"
    printf '{"type":"assistant","timestamp":"2026-10-03T08:00:00.000Z","message":{"usage":{"input_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s,"output_tokens":7,"iterations":[{"input_tokens":1,"cache_read_input_tokens":2}]}}}\n' "$3" "$5" "$4"
    printf '{"type":"user","timestamp":"2026-10-03T08:01:00.000Z","message":{"content":"later"}}\n'
  } > "$dir/aaaa-bbbb.jsonl"
}

# Fake fm-on: runs the --probe half locally in the route's remote home.
cat > "$TMP_ROOT/fake-on" <<SH
#!/usr/bin/env bash
[ "\$1" = rem ] && [ "\$2" = fm-sm-context.sh ] && [ "\$3" = --probe ] || exit 9
FM_HOME="$REMOTE_HOME" exec "$ROOT/bin/fm-sm-context.sh" --probe
SH
chmod +x "$TMP_ROOT/fake-on"

now=$(date -u +%s)
ago() { date -u -r $((now - $1)) +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -d "@$((now - $1))" +%Y-%m-%dT%H:%M:%S.000Z; }

run() {
  FM_HOME="$FM" FM_CLAUDE_CONFIG_DIR="$CLAUDE" FM_SM_CONTEXT_ON="$TMP_ROOT/fake-on" "$ROOT/bin/$1" "${@:2}"
}

write_transcript "$LOCAL_HOME" "$(ago 7200)" 3 100000 50000
out=$(run fm-sm-context.sh loc)
case "$out" in *"tokens=150003 "*) ;; *) fail "local tokens should be input+cache read+cache creation of the last assistant message: $out" ;; esac
age=$(printf '%s' "$out" | sed -n 's/.*age_s=\([0-9]*\).*/\1/p')
[ "$age" -ge 7200 ] && [ "$age" -lt 7300 ] || fail "local session age should come from the first timestamp: $out"
case "$out" in *"session=aaaa-bbbb"*) ;; *) fail "session id missing: $out" ;; esac
pass "local probe reads the last assistant usage and first-record age"

write_transcript "$REMOTE_HOME" "$(ago 30000)" 10 200000 1
out=$(run fm-sm-context.sh rem)
case "$out" in *"tokens=200011 "*) ;; *) fail "remote probe should route through the fm-on seam: $out" ;; esac
pass "remote probe goes over the transport"

out=$(run fm-sm-context.sh cdx)
case "$out" in *"tokens=unknown"*"harness=codex"*) ;; *) fail "non-claude harness should print unknown: $out" ;; esac
mkdir -p "$TMP_ROOT/empty"
out=$(FM_HOME="$FM" FM_CLAUDE_CONFIG_DIR="$TMP_ROOT/empty" "$ROOT/bin/fm-sm-context.sh" loc)
case "$out" in *"tokens=unknown"*) ;; *) fail "missing transcripts should print unknown: $out" ;; esac
pass "non-claude and missing transcripts print unknown"

# Check: loc is at 150003 tokens (over), rem is at 200011 tokens (over), cdx unknown.
out=$(run fm-sm-context-check.sh)
case "$out" in *"bin/fm-secondmate-restart.sh loc"*) ;; *) fail "check should name the restart command for loc: $out" ;; esac
case "$out" in *"bin/fm-secondmate-restart.sh rem"*) ;; *) fail "check should name the restart command for rem: $out" ;; esac
case "$out" in *cdx*) fail "unknown reading must stay silent: $out" ;; esac
out=$(run fm-sm-context-check.sh)
[ -z "$out" ] || fail "check should be rate limited per mate for the cooldown: $out"
pass "check wakes once per mate over the token threshold and rate-limits"

rm -f "$FM"/state/.sm-context-last-*
write_transcript "$LOCAL_HOME" "$(ago 7200)" 3 1000 500
write_transcript "$REMOTE_HOME" "$(ago 30000)" 3 1000 500
out=$(run fm-sm-context-check.sh)
case "$out" in *"bin/fm-secondmate-restart.sh rem"*"") ;; *) fail "age over six hours should wake: $out" ;; esac
case "$out" in *"restart.sh loc"*) fail "small and young session must stay silent: $out" ;; esac
pass "check wakes on session age alone and stays silent under both thresholds"

echo "ALL TESTS PASSED"
