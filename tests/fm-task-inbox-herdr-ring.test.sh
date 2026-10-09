#!/usr/bin/env bash
# tests/fm-task-inbox-herdr-ring.test.sh - the steering doorbell on herdr.
#
# fm_task_inbox_ring addresses the session recorded in a task's target, and
# when the recorded pane id no longer resolves in that session it rebinds to
# the task's fm-<id> tab inside the SAME session before typing. Pinned with a
# fake herdr (no real Herdr lifecycle):
#   1. must-fire: a task in the non-default session fm-remote whose recorded
#      pane id went stale rings the pane its fm-<id> tab now holds, through
#      --session fm-remote, and nothing is sent to any other session.
#   2. regression: a task whose recorded pane still resolves rings exactly
#      that pane in its own session, with no label lookup and no rebind.
#   3. quiet: a stale pane with no matching fm-<id> tab in its session is not
#      rung, even when another session holds a tab with that label.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-task-inbox-herdr-ring)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

# Fake herdr. FM_FAKE_HERDR_LIVE lists the "<session>/<pane>/<tab-label>"
# panes that exist; every other pane is pane_not_found. All calls are logged
# as "session|args" using the trailing --session flag.
make_fake_herdr() { # <dir> -> echoes fakebin dir
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat >"$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@"); session=default
for ((i = 0; i < ${#args[@]}; i++)); do
  [ "${args[$i]}" = --session ] && session=${args[$((i + 1))]:-default}
done
printf '%s|%s\n' "$session" "$*" >>"${FM_HERDR_LOG:?}"
live_pane() { # <pane> -> 0 when live in $session
  local e
  for e in ${FM_FAKE_HERDR_LIVE:-}; do
    [ "${e%%/*}" = "$session" ] || continue
    e=${e#*/}
    [ "${e%%/*}" = "$1" ] && return 0
  done
  return 1
}
case "${1:-} ${2:-}" in
  "status --json")
    printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n' ;;
  "pane get")
    if live_pane "${3:-}"; then printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "$3"
    else printf '{"error":{"code":"pane_not_found"}}\n'; fi ;;
  "agent get")
    printf '{"result":{"agent":{"agent_status":"idle"}}}\n' ;;
  "pane process-info")
    printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":%s,"foreground_processes":[{"pid":%s,"name":"claude","argv":["claude"]}]}}}\n' "${4:-}" "$$" "$$" ;;
  "tab list")
    for e in ${FM_FAKE_HERDR_LIVE:-}; do
      [ "${e%%/*}" = "$session" ] || continue
      r=${e#*/}; pane=${r%%/*}; lab=${r#*/}
      printf '%s\t%s\t%s\n' "$pane" "$lab" "w1"
    done | jq -R -s '{result:{tabs:(split("\n")|map(select(length>0)|split("\t")|{tab_id:("t-"+.[0]),label:.[1],workspace_id:.[2]}))}}' ;;
  "pane list")
    for e in ${FM_FAKE_HERDR_LIVE:-}; do
      [ "${e%%/*}" = "$session" ] || continue
      r=${e#*/}; pane=${r%%/*}
      printf '%s\n' "$pane"
    done | jq -R -s '{result:{panes:(split("\n")|map(select(length>0)|{pane_id:.,tab_id:("t-"+.)}))}}' ;;
  *) : ;;
esac
exit 0
SH
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

# ring_case <name> <live> <target> <label> -> echoes the herdr call log
ring_case() {
  local name=$1 live=$2 target=$3 label=$4 dir fb state
  dir="$TMP_ROOT/$name"; mkdir -p "$dir/state"
  : >"$dir/log"
  fb=$(make_fake_herdr "$dir")
  state="$dir/state"
  mkdir -p "$state/t.inbox"
  printf 'steer\n' >"$state/t.inbox/000001.msg"
  PATH="$fb:$PATH" FM_HERDR_LOG="$dir/log" FM_FAKE_HERDR_LIVE="$live" \
    FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 \
    bash -c '. "$0/bin/fm-backend.sh"; . "$0/bin/fm-task-inbox-lib.sh"
      fm_task_inbox_ring herdr "$1" "$2" "$3" claude' \
    "$ROOT" "$target" "$state/t.inbox/000001.msg" "$label" >/dev/null 2>&1
  echo "$?" >"$dir/rc"
  cat "$dir/log"
}

typed() { # <log> -> lines that sent text or keys
  printf '%s\n' "$1" | grep -E '\|pane (send-text|send-keys|run) ' || true
}

# 1. stale pane id in fm-remote: ring the fm-<id> pane, in fm-remote only.
log=$(ring_case stale "fm-remote/p9/fm-t default/p1/fm-t" fm-remote:p1 fm-t)
sent=$(typed "$log")
case "$sent" in *"fm-remote|pane send-text p9 "*) ;; *) fail "stale pane: doorbell did not reach fm-remote:p9; log:"$'\n'"$log" ;; esac
case "$sent" in *"default|"*) fail "stale pane: a ring went to the default session; log:"$'\n'"$log" ;; esac
case "$sent" in *"send-text p1 "*) fail "stale pane: the dead pane id was rung; log:"$'\n'"$log" ;; esac
pass "stale pane id in a non-default session: rung via the fm-<id> tab in that same session"

# 2. recorded pane live: ring exactly it, no label lookup.
log=$(ring_case live "fm-remote/p1/fm-t fm-remote/p9/fm-other" fm-remote:p1 fm-t)
sent=$(typed "$log")
case "$sent" in *"fm-remote|pane send-text p1 "*) ;; *) fail "live pane: doorbell did not reach fm-remote:p1; log:"$'\n'"$log" ;; esac
case "$sent" in *"send-text p9 "*|*"default|"*) fail "live pane: rung a different pane or session; log:"$'\n'"$log" ;; esac
case "$log" in *"tab list"*) fail "live pane: unnecessary label lookup; log:"$'\n'"$log" ;; esac
pass "live recorded pane: rung exactly as before, no rebind"

# 3. stale pane, label only in another session: stay quiet.
log=$(ring_case quiet "default/p5/fm-t" fm-remote:p1 fm-t)
[ -z "$(typed "$log")" ] || fail "no same-session tab: something was typed; log:"$'\n'"$log"
[ "$(cat "$TMP_ROOT/quiet/rc")" = 3 ] || fail "no same-session tab: expected ring status 3, got $(cat "$TMP_ROOT/quiet/rc")"
pass "stale pane with no tab in its own session: nothing rung in another session"
