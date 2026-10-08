#!/usr/bin/env bash
# Positive terminal evidence, windowless remote PR-polls (6d), revalidation,
# manifest-first moves, sidecars, no-overwrite restore, unknown/live retention.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-meta-archive)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$TMP_ROOT/fakebin"
export FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state"
export PATH="$TMP_ROOT/fakebin:$PATH"
export ARCHIVE_TEST_HOME="$HOME_DIR" ARCHIVE_CALLS="$TMP_ROOT/calls"
cat > "$TMP_ROOT/fakebin/gh-axi" <<'FAKE'
#!/usr/bin/env bash
set -eu
number=${2##*/}
printf '%s\n' "$number" >> "$ARCHIVE_CALLS"
case "$number" in
  1|3|4|5|6|7|8|9|10|11|12|13|14|15) state=closed; merged=true ;;
  2) state=open; merged=false ;;
  18|19) state=closed; merged=false ;;
  16) exit 1 ;;
  17) printf 'bad json\n'; exit 0 ;;
  *) state=open; merged=false ;;
esac
# When final evidence is read the manifest must already exist, and nothing
# from this record may have moved yet.
if [ "$number" = 3 ] && [ "$(grep -c '^3$' "$ARCHIVE_CALLS")" = 2 ]; then
  find "$ARCHIVE_TEST_HOME/state/meta-archive" -name manifest.json | grep -q .
  [ -f "$ARCHIVE_TEST_HOME/state/changing.meta" ]
  state=open; merged=false
fi
if [ "$number" = 4 ] && [ "$(grep -c '^4$' "$ARCHIVE_CALLS")" = 2 ]; then
  printf 'new content\n' >> "$ARCHIVE_TEST_HOME/state/mutation.status"
fi
if [ "$number" = 5 ] && [ "$(grep -c '^5$' "$ARCHIVE_CALLS")" = 2 ]; then
  find "$ARCHIVE_TEST_HOME/state/meta-archive" -name manifest.json | grep -q .
  [ -f "$ARCHIVE_TEST_HOME/state/manifest.meta" ]
  [ -f "$ARCHIVE_TEST_HOME/state/manifest.status" ]
fi
if [ "$number" = 19 ] && [ "$(grep -c '^19$' "$ARCHIVE_CALLS")" = 2 ]; then
  manifest=$(find "$ARCHIVE_TEST_HOME/state/meta-archive" -path '*collision-*/manifest.json' | head -1)
  printf 'occupied\n' > "${manifest%/*}/files/collision.meta"
fi
closed=null
[ "$state" != closed ] || closed='"2026-09-01T00:00:00Z"'
printf 'url: "https://github.com/example/repo/pull/%s"\nstate: %s\nmerged: %s\nclosed_at: %s\n' "$number" "$state" "$merged" "$closed"
FAKE
cat > "$TMP_ROOT/fakebin/tmux" <<'FAKE'
#!/usr/bin/env bash
[ "${ARCHIVE_TMUX_UNKNOWN:-0}" = 0 ] || exit 1
printf 'fm:1|fm:live|%%1\n'
FAKE
chmod +x "$TMP_ROOT/fakebin/gh-axi" "$TMP_ROOT/fakebin/tmux"
archive() { bash "$ROOT/bin/fm-meta-archive.sh" "$@"; }
record() {
  local id=$1 number=$2
  printf 'kind=ship\nremote_host=bosgame\npr=https://github.com/example/repo/pull/%s\nworktree=/tmp/shared-pr-check\n' "$number" > "$HOME_DIR/state/$id.meta"
  touch -t 202001010000 "$HOME_DIR/state/$id.meta"
}
record merged 1
record open 2
record secondmate 6
printf 'kind=secondmate\n' >> "$HOME_DIR/state/secondmate.meta"
touch -t 202001010000 "$HOME_DIR/state/secondmate.meta"
printf 'done: delivered\n' > "$HOME_DIR/state/merged.status"
printf 'receipt\n' > "$HOME_DIR/state/merged.pr-poll-merge-notified"
mkdir "$HOME_DIR/state/merged.inbox"
printf 'steer\n' > "$HOME_DIR/state/merged.inbox/message"
archive > "$TMP_ROOT/dry"
[ -f "$HOME_DIR/state/merged.meta" ] || fail 'dry-run moved metadata'
[ ! -e "$HOME_DIR/state/meta-archive" ] || fail 'dry-run wrote archive'
assert_grep 'would archive merged' "$TMP_ROOT/dry" 'dry-run missed terminal remote PR'
archive --apply merged open secondmate > "$TMP_ROOT/apply"
[ ! -e "$HOME_DIR/state/merged.meta" ] || fail '6d: merged remote poll remains live'
[ ! -e "$HOME_DIR/state/merged.status" ] || fail 'status remains live'
[ ! -e "$HOME_DIR/state/merged.pr-poll-merge-notified" ] || fail 'sidecar remains live'
[ ! -e "$HOME_DIR/state/merged.inbox" ] || fail 'directory sidecar remains live'
[ -f "$HOME_DIR/state/open.meta" ] || fail '6d: open remote poll moved'
[ -f "$HOME_DIR/state/secondmate.meta" ] || fail '6d: secondmate moved'
pass '6d archives merged remote PR-poll and all sidecars; keeps open PR and secondmate'
batch=$(find "$HOME_DIR/state/meta-archive" -name manifest.json | head -1)
batch=${batch%/*}
python3 - "$batch/manifest.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
assert m['reason'] == 'terminal-github-pr'
assert m['evidence']['pr']['merged'] is True
assert len(m['entries']) == 4
assert m['restore_command'][-2] == '--restore'
assert all(e['original'] and e['fingerprint'] for e in m['entries'])
PY
printf 'conflict\n' > "$HOME_DIR/state/merged.status"
if archive --apply --restore "$batch" > "$TMP_ROOT/restore-conflict" 2>&1; then fail 'restore overwrote conflict'; fi
assert_grep 'conflict' "$HOME_DIR/state/merged.status" 'restore changed conflicting original'
[ -f "$batch/files/merged.meta" ] || fail 'restore partially moved despite known conflict'
rm "$HOME_DIR/state/merged.status"
archive --restore "$batch" > "$TMP_ROOT/restore-dry"
[ ! -e "$HOME_DIR/state/merged.meta" ] || fail 'restore without --apply changed state'
archive --apply --restore "$batch" > "$TMP_ROOT/restored"
[ -f "$HOME_DIR/state/merged.meta" ] && [ -f "$HOME_DIR/state/merged.inbox/message" ] || fail 'restore lost files'
archive --apply --restore "$batch" > /dev/null
pass 'manifest contains evidence and restore command; restore refuses overwrite and is repeatable'
record changing 3
: > "$ARCHIVE_CALLS"
archive --apply changing > "$TMP_ROOT/changing"
[ -f "$HOME_DIR/state/changing.meta" ] || fail 'reopened PR was archived'
assert_grep 'evidence changed' "$TMP_ROOT/changing" 'missing revalidation refusal'
pass 'manifest exists before final evidence read and reopened PR stays'
record mutation 4
printf 'old content\n' > "$HOME_DIR/state/mutation.status"
: > "$ARCHIVE_CALLS"
if archive --apply mutation > "$TMP_ROOT/mutation" 2>&1; then fail 'changed sidecar passed revalidation'; fi
[ -f "$HOME_DIR/state/mutation.meta" ] || fail 'changed record moved'
pass 'sidecar mutation during final evidence read prevents movement'
record manifest 5
printf 'proof\n' > "$HOME_DIR/state/manifest.status"
: > "$ARCHIVE_CALLS"
archive --apply manifest > "$TMP_ROOT/manifest"
[ ! -e "$HOME_DIR/state/manifest.meta" ] || fail 'manifest-first apply did not move'
pass 'successful apply writes manifest before moving any source'
record young 7
touch "$HOME_DIR/state/young.meta"
record unknown 16
record malformed 17
record symlink 8
ln -s "$HOME_DIR/state/open.meta" "$HOME_DIR/state/symlink.status"
record hardlink 9
ln "$HOME_DIR/state/hardlink.meta" "$TMP_ROOT/linked-meta"
record live 10
printf 'window=fm:live\n' >> "$HOME_DIR/state/live.meta"
touch -t 202001010000 "$HOME_DIR/state/live.meta"
record remote-endpoint 11
printf 'window=fm:gone\n' >> "$HOME_DIR/state/remote-endpoint.meta"
touch -t 202001010000 "$HOME_DIR/state/remote-endpoint.meta"
record opaque 12
printf 'terminal=agent-opaque\nbackend=orca\n' >> "$HOME_DIR/state/opaque.meta"
touch -t 202001010000 "$HOME_DIR/state/opaque.meta"
archive --apply young unknown malformed symlink hardlink live remote-endpoint opaque > "$TMP_ROOT/kept" 2>&1
for id in young unknown malformed symlink hardlink live remote-endpoint opaque; do
  [ -f "$HOME_DIR/state/$id.meta" ] || fail "unsafe/unknown $id moved"
done
pass 'young, unreachable, malformed, symlink, hardlink, live, unroutable and opaque records stay'
# Local tmux endpoint absence requires a successful inventory.
record gone 13
sed '/^remote_host=/d' "$HOME_DIR/state/gone.meta" > "$TMP_ROOT/local-meta"
cat "$TMP_ROOT/local-meta" > "$HOME_DIR/state/gone.meta"
printf 'window=fm:gone\n' >> "$HOME_DIR/state/gone.meta"
touch -t 202001010000 "$HOME_DIR/state/gone.meta"
ARCHIVE_TMUX_UNKNOWN=1 archive --apply gone > /dev/null
[ -f "$HOME_DIR/state/gone.meta" ] || fail 'failed inventory proved endpoint gone'
archive --apply gone > /dev/null
[ ! -e "$HOME_DIR/state/gone.meta" ] || fail 'confirmed gone local endpoint retained'
pass 'endpoint absence requires successful owner inventory'
archive --probe-gone nonexistent tmux fm:gone > "$TMP_ROOT/probe"
assert_grep 'lane-gone:nonexistent' "$TMP_ROOT/probe" 'owning-host probe failed'
if archive --probe-gone open tmux fm:gone > /dev/null; then fail 'host probe ignored live metadata'; fi
if archive --probe-gone nonexistent tmux fm:live > /dev/null; then fail 'host probe ignored live endpoint'; fi
if ARCHIVE_TMUX_UNKNOWN=1 archive --probe-gone nonexistent tmux fm:gone > /dev/null; then fail 'host probe accepted unknown'; fi
pass 'owning host probe keeps metadata, live endpoints and unknown inventories'
record nomore 14
archive --apply nomore > /dev/null
archive --apply nomore > /dev/null
[ "$(find "$HOME_DIR/state/meta-archive" -name nomore.meta | wc -l | tr -d ' ')" = 1 ] || fail 'repeat archive duplicated record'
pass 'repeat apply retains one archived copy'

record closed 18
archive --apply closed > /dev/null
[ ! -e "$HOME_DIR/state/closed.meta" ] || fail 'unmerged closed PR was retained'
pass 'closed unmerged PR provides terminal evidence'
record collision 19
: > "$ARCHIVE_CALLS"
if archive --apply collision > "$TMP_ROOT/collision" 2>&1; then fail 'archive collision was overwritten'; fi
[ -f "$HOME_DIR/state/collision.meta" ] || fail 'collision lost original'
collision=$(find "$HOME_DIR/state/meta-archive" -path '*collision-*/files/collision.meta' | head -1)
assert_grep 'occupied' "$collision" 'archive overwritten'
pass 'existing archive destination is never overwritten'
record partial 15
printf 'status\n' > "$HOME_DIR/state/partial.status"
archive --apply partial > /dev/null
partial=$(find "$HOME_DIR/state/meta-archive" -path '*partial-*/manifest.json' | head -1)
partial=${partial%/*}
# Simulate an interrupted subset by putting one of the manifest entries back.
mv "$partial/files/partial.meta" "$HOME_DIR/state/partial.meta"
archive --apply --restore "$partial" > /dev/null
[ -f "$HOME_DIR/state/partial.status" ] && [ -f "$HOME_DIR/state/partial.meta" ] || fail 'partial restore failed'
pass 'manifest restores the archived subset of an interrupted batch'
# Exercise the existing backlog read interface, never a fixture source matcher.
cat > "$HOME_DIR/data/backlog.md" <<'BACKLOG'
# Fixture backlog
BACKLOG
cat > "$TMP_ROOT/fakebin/tasks-axi" <<'FAKE'
#!/usr/bin/env bash
[ "$1" = show ] || exit 1
case "$2" in
  finished|poll-open-backlog-done) printf '  state: done\n  held: no\n  blocked: no\n' ;;
  queued) printf '  state: queued\n  held: no\n  blocked: no\n' ;;
  *) printf 'code: NOT_FOUND\n'; exit 1 ;;
esac
FAKE
chmod +x "$TMP_ROOT/fakebin/tasks-axi"
for id in finished queued missing remote-no-pr; do
  printf 'kind=ship\n' > "$HOME_DIR/state/$id.meta"
  touch -t 202001010000 "$HOME_DIR/state/$id.meta"
done
printf 'remote_host=bosgame\n' >> "$HOME_DIR/state/remote-no-pr.meta"
touch -t 202001010000 "$HOME_DIR/state/remote-no-pr.meta"
record poll-open-backlog-done 2
archive --apply finished queued missing remote-no-pr poll-open-backlog-done > "$TMP_ROOT/backlog" 2>&1
[ ! -e "$HOME_DIR/state/finished.meta" ] || fail 'closed backlog task not archived'
for id in queued missing remote-no-pr poll-open-backlog-done; do
  [ -f "$HOME_DIR/state/$id.meta" ] || fail "backlog unknown/open record $id moved"
done
pass 'positive backlog closure works; missing/open rows and open PR-polls stay'
# Production publishers honor these lifecycle locks. A live holder keeps the
# record, and releasing it allows the same command to converge.
record locked 1
# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"
STATE="$HOME_DIR/state"
fm_lock_try_acquire "$STATE/.meta-locked.lock" || fail 'fixture lock refused'
# The child has a different current pid, so it cannot reclaim this holder.
archive --apply locked > "$TMP_ROOT/locked"
[ -f "$STATE/locked.meta" ] || fail 'archive raced a metadata publisher'
fm_lock_release "$STATE/.meta-locked.lock"
archive --apply locked > /dev/null
[ ! -e "$STATE/locked.meta" ] || fail 'released lock did not permit archive'
pass 'live lifecycle lock keeps record; retry after release converges'
# Isolate the transport boundary while exercising the archive entry point and
# all production record/evidence/file helpers unchanged.
mkdir "$TMP_ROOT/transport-bin"
for name in fm-meta-archive.sh fm-meta-archive-files.py fm-wake-lib.sh fm-path-lib.sh fm-backend.sh fm-pr-lib.sh fm-tasks-axi-lib.sh fm-backlog-transition-lib.sh fm-lock-lib.sh fm-timeout-lib.sh; do
  cp "$ROOT/bin/$name" "$TMP_ROOT/transport-bin/$name"
done
cat > "$TMP_ROOT/transport-bin/fm-on.sh" <<'FAKE'
#!/usr/bin/env bash
[ "$1" = bosgame ] && [ "$2" = fm-meta-archive.sh ] && [ "$3" = --probe-gone ] || exit 2
[ "${ARCHIVE_OWNER_MODE:-gone}" != unreachable ] || exit 255
if [ "${ARCHIVE_OWNER_MODE:-gone}" = mismatch ]; then printf 'lane-gone:other-task\n'; else printf 'lane-gone:%s\n' "$4"; fi
FAKE
chmod +x "$TMP_ROOT/transport-bin/fm-on.sh"
record remote-confirmed 11
printf 'window=fm:gone\n' >> "$HOME_DIR/state/remote-confirmed.meta"
touch -t 202001010000 "$HOME_DIR/state/remote-confirmed.meta"
ARCHIVE_OWNER_MODE=unreachable bash "$TMP_ROOT/transport-bin/fm-meta-archive.sh" --apply remote-confirmed > /dev/null
[ -f "$HOME_DIR/state/remote-confirmed.meta" ] || fail 'unreachable owner allowed archival'
ARCHIVE_OWNER_MODE=mismatch bash "$TMP_ROOT/transport-bin/fm-meta-archive.sh" --apply remote-confirmed > /dev/null
[ -f "$HOME_DIR/state/remote-confirmed.meta" ] || fail 'wrong owner response allowed archival'
bash "$TMP_ROOT/transport-bin/fm-meta-archive.sh" --apply remote-confirmed > /dev/null
[ ! -e "$HOME_DIR/state/remote-confirmed.meta" ] || fail 'confirmed gone remote lane did not archive'
remote_manifest=$(find "$HOME_DIR/state/meta-archive" -path '*remote-confirmed-*/manifest.json' | head -1)
jq -e '.evidence.owner == "bosgame" and .evidence.owner_response == "lane-gone:remote-confirmed"' "$remote_manifest" > /dev/null || fail 'owner evidence not retained'
pass 'remote endpoints require an exact owning-host absence response; unknown keeps'
